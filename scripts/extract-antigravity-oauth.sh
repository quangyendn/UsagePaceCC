#!/usr/bin/env bash
#
# extract-antigravity-oauth.sh
#
# ============================================================================
# READ THIS BEFORE RUNNING
#
# This script recovers an OAuth client (client_id/client_secret) that belongs
# to Antigravity, not to UsagePaceCC, from a locally installed `agy` binary.
# Reusing another product's OAuth client is a grey area under Google's terms
# of service. Google may revoke or rotate that client at any time; if it does,
# the Antigravity feature in this app breaks with no in-app remedy — there is
# no fallback client to switch to.
#
# This script only ever reads credentials that are already present on the
# machine it runs on. It does not transmit or publish anything: no client_id,
# client_secret, access_token, or refresh_token literal is ever echoed,
# logged, or written anywhere except the generated plist, which is gitignored
# and never leaves your machine unless you copy it yourself.
#
# UsagePaceCC builds and runs fine without this script — it simply hides the
# Antigravity section of the UI when `AntigravityOAuth.plist` is absent. If
# you are not comfortable with the above, do not run this script.
# ============================================================================
#
# Extracts the agy (Antigravity CLI) installed-app OAuth client_id/client_secret
# candidates out of the `agy` binary, cross-products them, validates each pair
# with a trial `refresh_token` grant against oauth2.googleapis.com, and writes
# the single validated winner to UsagePaceCC/Resources/AntigravityOAuth.plist.
#
# Requirements: agy installed and signed in at least once (so the macOS login
# keychain holds svce=gemini/acct=antigravity), `strings`, `curl`, `python3`,
# `security` (all stock macOS tools).
#
# Usage: scripts/extract-antigravity-oauth.sh
#
set -euo pipefail

# Restrictive umask before any temp file is created — the default umask would make the trial
# response file mode 644 (world-readable) in a shared, sticky-world-writable /tmp.
umask 077

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLIST_PATH="$REPO_ROOT/UsagePaceCC/Resources/AntigravityOAuth.plist"
KEYCHAIN_SERVICE="gemini"
KEYCHAIN_ACCOUNT="antigravity"
PAYLOAD_PREFIX="go-keyring-base64:"
TOKEN_ENDPOINT="https://oauth2.googleapis.com/token"

fail() {
    echo "extract-antigravity-oauth: $1" >&2
    exit 1
}

command -v strings >/dev/null 2>&1 || fail "strings not found"
command -v curl >/dev/null 2>&1 || fail "curl not found"
command -v python3 >/dev/null 2>&1 || fail "python3 not found"
command -v security >/dev/null 2>&1 || fail "security not found"

AGY_PATH="$(command -v agy || true)"
[ -n "$AGY_PATH" ] || fail "agy CLI not found on PATH — install/sign in to Antigravity first"

echo "Locating agy binary... found."

# --- Step 1: extract candidate client_id / client_secret literals -----------

# Note: uses a plain `while read` loop (not `mapfile`) — macOS ships bash 3.2
# by default, which does not have the `mapfile` builtin.
CLIENT_IDS=()
while IFS= read -r line; do
    [ -n "$line" ] && CLIENT_IDS+=("$line")
done < <(strings -a "$AGY_PATH" | grep -oE '[0-9]{10,14}-[a-z0-9]{20,40}\.apps\.googleusercontent\.com' | sort -u)

CLIENT_SECRETS=()
while IFS= read -r line; do
    [ -n "$line" ] && CLIENT_SECRETS+=("$line")
done < <(strings -a "$AGY_PATH" | grep -oE 'GOCSPX-[A-Za-z0-9_-]{28}' | sort -u)

[ "${#CLIENT_IDS[@]}" -gt 0 ] || fail "no client_id candidates found in binary"
[ "${#CLIENT_SECRETS[@]}" -gt 0 ] || fail "no client_secret candidates found in binary"

echo "Found ${#CLIENT_IDS[@]} client_id candidate(s), ${#CLIENT_SECRETS[@]} client_secret candidate(s)."

# --- Step 2: read a refresh_token from the agy keychain item to validate with --

RAW_PAYLOAD="$(security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" -w 2>/dev/null || true)"
[ -n "$RAW_PAYLOAD" ] || fail "could not read agy keychain item (svce=$KEYCHAIN_SERVICE, acct=$KEYCHAIN_ACCOUNT) — is agy signed in?"

case "$RAW_PAYLOAD" in
    "$PAYLOAD_PREFIX"*) : ;;
    *) fail "keychain payload missing expected prefix" ;;
esac

BASE64_PAYLOAD="${RAW_PAYLOAD#"$PAYLOAD_PREFIX"}"

REFRESH_TOKEN="$(printf '%s' "$BASE64_PAYLOAD" | base64 -d 2>/dev/null | python3 -c '
import json, sys
try:
    payload = json.load(sys.stdin)
    token = payload.get("token", {}).get("refresh_token", "")
    sys.stdout.write(token)
except Exception:
    sys.exit(1)
' || true)"

[ -n "$REFRESH_TOKEN" ] || fail "could not parse refresh_token from keychain payload"

echo "Read a refresh token from the agy keychain item for validation (not printed)."

# --- Step 3: cross-product candidates, trial-refresh each pair ---------------

WINNING_ID=""
WINNING_SECRET=""

# mktemp instead of a fixed, predictable /tmp path (symlink-plant target); trap guarantees cleanup
# even on an early/abnormal exit. `umask 077` above plus `mktemp` gives mode 600.
TRIAL_RESPONSE="$(mktemp -t agy-oauth)"
trap 'rm -f "$TRIAL_RESPONSE"' EXIT

for CLIENT_ID in "${CLIENT_IDS[@]}"; do
    for CLIENT_SECRET in "${CLIENT_SECRETS[@]}"; do
        # Secrets go over stdin (`--data @-` reading a piped body), never argv — argv is visible to
        # every local user via `ps`.
        HTTP_STATUS="$(printf 'client_id=%s&client_secret=%s&refresh_token=%s&grant_type=refresh_token' \
                "$CLIENT_ID" "$CLIENT_SECRET" "$REFRESH_TOKEN" \
            | curl -s -o "$TRIAL_RESPONSE" -w '%{http_code}' \
                -X POST "$TOKEN_ENDPOINT" \
                -H 'Content-Type: application/x-www-form-urlencoded' \
                --data @- || true)"

        if [ "$HTTP_STATUS" = "200" ] && grep -q '"access_token"' "$TRIAL_RESPONSE" 2>/dev/null; then
            WINNING_ID="$CLIENT_ID"
            WINNING_SECRET="$CLIENT_SECRET"
            break 2
        fi
    done
done

[ -n "$WINNING_ID" ] && [ -n "$WINNING_SECRET" ] || fail "no candidate pair validated against $TOKEN_ENDPOINT"

echo "Validated a working client_id/client_secret pair (values not printed)."

# --- Step 4: write the plist, gitignored, chmod 600 --------------------------

mkdir -p "$(dirname "$PLIST_PATH")"

# Written from a heredoc (shell builtin `cat`, no argv) rather than `PlistBuddy -c "Add ... $SECRET"`
# — the latter puts the client_secret on argv, visible to every local user via `ps`.
# `umask 077` (set above) means the file is created 0600 directly; the explicit chmod below is a
# defence-in-depth no-op on the common path.
cat > "$PLIST_PATH" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>clientId</key>
	<string>$WINNING_ID</string>
	<key>clientSecret</key>
	<string>$WINNING_SECRET</string>
</dict>
</plist>
EOF

chmod 600 "$PLIST_PATH"

echo "Wrote $PLIST_PATH (chmod 600). Done."
