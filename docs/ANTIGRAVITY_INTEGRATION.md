# Antigravity Integration — Maintainer Reference

This document is the durable record of how Google Antigravity usage monitoring
works in UsagePaceCC. It is the only written account of the design decisions
and the reverse-engineering behind them — whatever is not written here is lost.
Read this before touching any Antigravity code.

It intentionally never contains a literal client id, client secret, access
token, or refresh token. Example tokens below are redacted to `ya29...` /
`1//...` shapes. See "Security" at the end before adding anything to this file.

## 1. What it is and what data exists

Antigravity is Google's coding-agent product. UsagePaceCC monitors its
**weekly quota** the same way it monitors Claude and Codex: as a menu bar
glyph, a popover legend row, and a point on the existing pace-scatter graph.

The verified API response contains exactly one number per usage group:
**`remainingFraction`** — a 0.0–1.0 fraction of quota remaining. There is no
token count, no dollar cost, and no history in the response. This is why the
feature required **zero new persistence**: the pace graph already plots the
current sample, not a stored time series, so a fresh fraction each poll is all
it needs. Do not add a local sampling/history store to "fix" this — it was
considered and deliberately dropped, because it would give Antigravity a
capability Claude and Codex do not have. A trend view, if ever wanted, is a
separate all-providers feature.

## 2. Endpoint

```
POST https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary
Authorization: Bearer <access_token>
Content-Type: application/json
User-Agent: antigravity-cli/1.1.27

{}
```

- Body is a literal empty JSON object. No API key, no project id — Bearer
  auth only.
- **The `User-Agent` is load-bearing and is the single easiest thing to get
  wrong.** The server gates this endpoint on the caller identifying itself as
  an Antigravity client. With a User-Agent that does not contain
  "Antigravity", a token that is completely valid — right client, right
  account, full scope set, minutes old — still gets:

  ```
  403 PERMISSION_DENIED
  "You do not have a valid license of this product. Please contact your
   administrator to request a license. … (#3501)"
  ```

  That message is actively misleading: it has nothing to do with licensing,
  subscriptions, or scopes, and it will send you hunting through OAuth
  consent and account entitlements for hours. Measured behaviour:
  `antigravity-cli/1.1.27`, `antigravity-cli` and `Antigravity/1.1.27` all
  return 200; `UsagePaceCC/3.0.0` and `curl/8.0` both return 403. The version
  segment is not checked — only the presence of the product name. Both the
  production and `daily-` hosts behave identically.

  If quota fetches start failing with a licence error, check this header
  before anything else.
- **Never call `:retrieveUserQuota` (singular).** It is a different, real
  endpoint that returns `403 SUBSCRIPTION_REQUIRED` for consumer (non-paid)
  Google accounts. Only the plural `:retrieveUserQuotaSummary` was verified to
  work for the accounts this app targets.
- `v1internal` is not a documented, versioned Google API surface — see
  "Known fragility" (§10).

## 3. Response shape — server-driven, do not hardcode

The response is a list of quota "groups," each with one or more "buckets."
Both the set of groups and their identifiers are **server-driven and can
change without notice**:

- Never hardcode group identifiers like `gemini-weekly` or `3p-weekly` as if
  they were a fixed enum. Iterate the groups the response actually contains.
- Never index a bucket by a stable `bucketId` — treat it as opaque.
- `bucket.description` is present only when quota has been consumed; at 100%
  remaining, the server omits it. Code that reads a bucket's description must
  tolerate absence, not treat it as an error.
- The Antigravity legend labels shown to users are **static, localized
  strings** (e.g. "Antigravity · Gemini", "Antigravity · 3P"), not the raw
  server strings — the server's own group names are long and one variant
  literally contains the word "Claude" (`"Claude and GPT models"`), which
  would read as a bug next to real Claude rows in the same popover. The raw
  server `group.displayName` is preserved and surfaced only in the row's
  tooltip, via `WindowUsage.sourceLabel: String?` (length-capped at 80 chars).

## 4. Two credential sources, and why both exist

### Google sign-in (recommended, durable, multi-account)

- OAuth 2.0 authorization-code flow with PKCE, via `ASWebAuthenticationSession`
  and a loopback (`127.0.0.1`) redirect — see `docs/CODE_SIGNING.md`
  ("Entitlements: Why the App Listens on Localhost") for the entitlement and
  listener-scope details.
- On success, UsagePaceCC's own refresh token is persisted per account in
  `Account.sessionKey`, inside the existing `accounts_antigravity` Keychain
  item — the same storage mechanism Claude and Codex accounts already use. No
  new storage machinery was added.
- Multiple Antigravity accounts can be signed in this way, each becoming its
  own `Account`, participating in the existing multi-account dashboard exactly
  like Claude/Codex accounts.
- **`addAntigravityOAuthAccount` returns `Account?` and is deliberately not
  `@discardableResult`.** It returns `nil` and refuses to create an account
  when the ID token carries neither `email` nor `sub` — callers must handle
  `nil` by telling the user "identity could not be confirmed, sign-in
  cancelled" rather than silently dropping the result.
- Survives app updates with no re-prompt, because it does not depend on the
  app's code-signing identity at all.

### Antigravity app / keychain (optional convenience shortcut, single account)

- Reads the Antigravity desktop app's own login-keychain item
  (`svce=gemini`, `acct=antigravity`) on macOS. The payload is prefixed
  `go-keyring-base64:` followed by base64-encoded JSON, with an RFC3339
  expiry timestamp that **carries a local UTC offset** (parsed with
  `ISO8601DateFormatter` using `.withInternetDateTime`, retried with
  `.withFractionalSeconds` — a bare `Z`-only parser will fail on real data).
- Read-only. Never written back to `agy`'s item (see §7).
- Exactly one account — `agy` itself stores only one credential, so this
  source is materialized in the app as a single pseudo-`Account` with an
  **empty `sessionKey`** (OAuth accounts carry their refresh token in
  `sessionKey`; the keychain pseudo-account deliberately does not, since there
  is nothing of ours to persist for it).
- **This source reads the keychain item only on an explicit user
  gesture — the Connect or Reconnect button tap — never on a background
  timer.** The credential is then held in memory for the process's lifetime
  and reused for subsequent polls; a fresh app launch always shows "Connect"
  again, because nothing is cached to disk for this source.
  - **The cost this imposes on the user is real and is not a bug: one tap per
    app launch, for this source only.** Google sign-in has no such cost.
  - Why the read is gated on a gesture at all: `LAContext.interactionNotAllowed`
    (and `kSecUseNoAuthenticationUI`) was tried, specifically to allow a
    silent background poll. It was empirically disproven — Apple's own SDK
    header documents that `kSecUseNoAuthenticationUI` applies only to
    Data-Protection-keychain items, and `agy`'s item is a **legacy keychain
    item** (it carries `SecACL` trusted-application entries and a
    `partition_id`, both hallmarks of the legacy/file-based keychain, not the
    Data Protection keychain). Without the gesture restriction, a background
    poll in this `LSUIElement` (no Dock icon, no app-switcher presence) app
    could raise the macOS keychain authorization modal with no visible
    triggering action from the user — worse after every update, since ad-hoc
    signing invalidates the item's ACL grant on every rebuild (see
    `docs/CODE_SIGNING.md`).
  - `AntigravityTokenProvider` is an app-wide singleton (`.shared`) precisely
    so that the in-memory credential obtained by this gesture is the same
    instance seen by both `DataRefreshManager` (polling) and
    `AuthSettingsView` (the Connect/Reconnect UI) — there must be exactly one
    in-memory copy, not two that can disagree.

### Cross-source dedupe

If the same Google account is reachable via both sources, it must not appear
twice. Dedupe is keyed off a **persisted `antigravityKeychainResolvedEmail`**
(`UserDefaults`), not off any field of the keychain pseudo-account itself.

**Invariant, load-bearing:** `antigravityKeychainResolvedEmail` and
`antigravityKeychainConsentedIdentityHash` must have **identical
lifetimes** — written together, cleared together (on opt-out, and whenever the
underlying credential disappears). Small variations on this exact invariant
have previously produced three distinct failure modes: a data-loss defect, an
oscillation bug where the redundancy verdict was derived from the very account
being deleted, and a stale-state bug where the persisted email was never
cleared. Treat any change here as high-risk and re-verify all three failure
modes.

## 5. OAuth client provenance — read this before touching auth

**This is the single most important fact in this document.**

Both credential sources above authenticate against Google using an
**installed-app OAuth client that belongs to Antigravity, not to
UsagePaceCC.** The client id and secret are extracted directly from the `agy`
binary by `scripts/extract-antigravity-oauth.sh` and written into
`UsagePaceCC/Resources/AntigravityOAuth.plist`, which is **gitignored** — it
is never committed. `UsagePaceCC/Resources/AntigravityOAuth.example.plist` is
committed with empty placeholder values so a clean clone still builds; when
the real plist is absent, `AntigravityOAuthSecrets.load()` returns `nil`, no
OAuth client is constructed, and the entire Antigravity section of the app
hides itself. There is no broken half-state.

State this plainly, without euphemism, because a future maintainer who
doesn't know it will misdiagnose every symptom below:

- **The Google consent screen users see during Antigravity sign-in is branded
  "Antigravity," not "UsagePaceCC."** This is expected and is explained to the
  user in-app before they reach the screen (see the `signin.antigravity_*`
  localized copy, all six locales). It is not a UsagePaceCC login page and
  never will be, short of registering a separate Google Cloud OAuth client —
  which was considered and rejected: `cloudcode-pa` is expected to allowlist by
  `client_id`, so a fresh, UsagePaceCC-owned client might simply 403 despite
  correct scopes.
- **The literal client id and secret are never committed and never written
  into any document, including this one.** Refer to the extraction script by
  name, never by value.
- **Google can revoke or rotate that client at any time, with no warning and
  no in-app remedy.** If Antigravity sign-in starts failing for every user
  simultaneously with `unauthorized_client` or `invalid_client`, this is the
  cause. There is nothing to fix in UsagePaceCC's code — the fix is to
  re-run `scripts/extract-antigravity-oauth.sh` against a current `agy`
  build and ship the refreshed (still-gitignored) plist.
- **The scopes requested are exactly the set `agy` itself requests** —
  including Antigravity-specific scopes named `aicode` and `cclog` alongside
  the standard identity scopes (`openid`, `email`, `profile`) and the
  `cloud-platform` scope needed for `cloudcode-pa` access. UsagePaceCC does
  not request a broader or narrower scope set than the Antigravity app does.
  See the extraction script and its adjacent code comment for the exact,
  current list — it is intentionally not duplicated here so this document
  cannot drift out of sync with what the script actually requests.

### On running `scripts/extract-antigravity-oauth.sh`

The script is kept in this public repository, but the risk it carries should
be explicit rather than implicit:

- It recovers an OAuth client that belongs to **Antigravity**, not to
  UsagePaceCC, from a locally installed `agy` binary.
- It only ever reads credentials already present on the machine it runs on;
  it neither transmits nor publishes them anywhere, and the resulting
  `AntigravityOAuth.plist` is gitignored.
- Reusing another product's OAuth client this way is a grey area under
  Google's terms of service. Google may revoke or rotate the client at any
  time, which would break Antigravity sign-in with no in-app remedy.
- Anyone uncomfortable with that should not run the script — UsagePaceCC
  builds and runs fine without it; it simply hides the Antigravity section of
  the UI.

## 6. Refresh

Token refresh uses `POST https://oauth2.googleapis.com/token` with
`grant_type=refresh_token`, form-encoded, using the same Antigravity-owned
client credentials as the initial exchange.

- For the **Google sign-in** source, a rotated refresh token (if Google
  issues one) is persisted back into `Account.sessionKey` — this source is
  meant to be durable indefinitely.
- For the **keychain** source, any rotated refresh token from a refresh call
  is used in-memory for the rest of the process's lifetime and is **never**
  written back to `agy`'s own keychain item. See §7 — this is a hard rule,
  not an optimization.

## 7. Read-only rules for the keychain source

- Never call `SecItemAdd`, `SecItemUpdate`, or `SecItemDelete` against the
  `svce=gemini` item. UsagePaceCC only ever reads it.
- Never persist anything read from it to UsagePaceCC's own storage beyond the
  process-lifetime in-memory copy described in §4.
- Exactly two call sites may trigger a read of this item: the Connect button
  and the Reconnect button in Auth Settings. No polling code path may read it
  directly — polling reuses the in-memory credential held by
  `AntigravityTokenProvider.shared`.

## 8. Poll cadence

Antigravity accounts are polled on the same 5–15 minute smart/fixed refresh
schedule as Claude and Codex, with a **per-account 300-second floor** — no
single Antigravity account is fetched more than once per 300 seconds even
under aggressive manual-refresh use. A distinct type,
`AntigravityFetchSkipped.clientThrottled`, represents this local skip and is
**deliberately not** `UsageError.rateLimited` — a real server-side HTTP 429
must still surface as a user-visible error; only the local, client-side
"we already asked recently" skip is silent. `agy` itself throttles its own
quota refresh, and the underlying quota window is weekly, so polling more
aggressively than this buys nothing and should not be "optimized" upward.

## 9. Where the slot mapping happens

Per-account Antigravity numbers are exposed through
`AccountUsageSnapshot.antigravitySnapshots(from:accounts:errors:)`, rebuilt
incrementally as each account's fetch completes (mirroring the existing
`rebuildClaudeSnapshots` pattern) rather than once at the end of a refresh
cycle. `DataRefreshManager.antigravityUsageByAccount` /
`antigravityErrorByAccount` / `antigravityLastServingSourceByAccount` hold the
per-account state that the popover and menu bar glyph read.

**`fiveHour` and `sevenDay` are slot names, not durations.** They exist so
Antigravity's two quota groups (Gemini, third-party) can reuse the exact same
rendering path, color slots, and menu bar glyph budget that Claude's
"5-hour"/"7-day" windows use — but an Antigravity "slot" holds a **weekly**
window's `remainingFraction`, not a literal 5-hour or 7-day duration. Do not
"fix" the naming to something duration-accurate; it is intentionally shared
vocabulary with the rendering layer, not a claim about the underlying window
length. `getActiveDisplayTypes` takes `hasAntigravityPrimary` /
`hasAntigravitySecondary` booleans for this reason — there is deliberately no
single merged "the" Antigravity value; a prior synthetic
`antigravityUsageData` that merged presence across all accounts (and picked
an arbitrary account's numbers via nondeterministic dictionary ordering) was
built and then **deleted** for exactly this reason. Any UI that wants a
displayed number must go through `antigravityUsageByAccount[accountId]` for a
specific account — there is no shortcut.

## 10. Known fragility

`v1internal` is an **undocumented, unversioned Google API surface** — it is
not part of any published, stable API contract, unlike `oauth2.googleapis.com`.
It can change shape or disappear without a deprecation notice. The failure
mode this app is built for is always a **legend error row** (a per-account or
provider-level error, matching the existing Claude/Codex error-row pattern) —
**never a crash, and never a silently stale number.** An account whose fetch
is failing contributes no rows and stays silent rather than showing a
week-old percentage with no indicator. That tension — silent stale data versus
a visible error — is deliberate and was settled in favour of the visible error;
do not "simplify" it back. If `retrieveUserQuotaSummary` changes shape,
parsing should fail closed into an error row, not attempt a best-effort partial
read.

## Brand assets

The Antigravity menu bar glyph and icon are **original artwork**, not
Google's — a neutral geometric mark (an upward chevron over a baseline bar on
a violet→magenta rounded-square badge), living in `AntigravityIcon.imageset`
plus an alpha-driven template silhouette in `AntigravityIconReverse.imageset`.
Both PNGs can be replaced 1:1 with no code change. State this explicitly so
nobody assumes it is licensed Google/Antigravity artwork — it is not.

## Security

- Never write a literal client id, client secret, access token, or refresh
  token into this file or any other document in this repo. Refer to
  `scripts/extract-antigravity-oauth.sh` by name; redact example tokens to
  `ya29...` / `1//...`.
- This document describes the *shape* of the credentials and the endpoint's
  read-only, low-cadence usage as **requirements**, not as an invitation —
  UsagePaceCC only ever reads quota summaries; it never writes, never
  purchases, never mutates Antigravity/Google account state.
- The "Always Allow" Keychain guidance given to users must be scoped to the
  single `gemini` / `antigravity` item — see `docs/CODE_SIGNING.md`.
