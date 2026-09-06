# Code Signing Guide for UsagePaceCC

## Overview

**All builds — local and CI — are ad-hoc-signed.** `scripts/build.sh` unconditionally
forces `CODE_SIGN_IDENTITY="-"`, so there is no Developer ID certificate involved and
no notarization, ever, regardless of what runs the script.

**Gatekeeper will warn users.** Ad-hoc signing satisfies Xcode's build system but is
not accepted by macOS Gatekeeper as a trusted identity. On first launch, downloaders
must **right-click the app → Open** (or **System Settings → Privacy & Security → Open
Anyway**) to bypass the warning. This is stated here without hedging because it is
what every downloader of a `.dmg` from this repo will hit.

| Context | Signing used | Notes |
|---------|--------------|-------|
| Xcode.app GUI build | ad-hoc (`-`) | Set directly in `project.pbxproj`; no cert required |
| `scripts/build.sh` (local) | ad-hoc (`-`) | No cert required; Gatekeeper warns |
| CI (GitHub Actions, calls `build.sh`) | ad-hoc (`-`) | No certificate import happens; `build.sh` is the only signing authority |

---

## Local Xcode GUI Builds

The project's `project.pbxproj` sets:

```
CODE_SIGN_IDENTITY = "-";
"CODE_SIGN_IDENTITY[sdk=macosx*]" = "-";
```

This builds out of the box for anyone who clones the repo — no certificate needs to
exist in any keychain. `project.pbxproj` previously referenced a
`UsagePaceCC-CodeSigning` identity that was never actually created, which meant a
clean-clone `⌘B` failed with *"No certificate matching 'UsagePaceCC-CodeSigning'
found"*. That has been corrected: both build configurations now use ad-hoc signing,
matching `scripts/build.sh` and CI.

> Creating a real self-signed `UsagePaceCC-CodeSigning` certificate for local GUI
> builds — and reintroducing it in `project.pbxproj` — is deferred to a future phase
> (Phase 07 of the `full-brand-independence` plan). Until that lands, all three build
> paths in the table above are ad-hoc and behave identically.

---

## Local Script Builds (`scripts/build.sh`)

`scripts/build.sh` unconditionally overrides code signing at invocation time:

```bash
CODE_SIGN_IDENTITY="-"
CODE_SIGN_STYLE=Manual
DEVELOPMENT_TEAM=""
```

The `-` value is macOS ad-hoc signing — the app is signed with a per-build ephemeral
identity. The resulting `.app` and `.dmg` run on the build machine but will be flagged
by Gatekeeper on other machines. Users must right-click → "Open" on first launch.

---

## CI (GitHub Actions)

CI (`.github/workflows/release.yml`) calls `scripts/build.sh` directly. **There is no
certificate-import step and no `CODESIGN_*` secrets configured on this repo** — a
previous CI step imported a `.p12` certificate before building, but since `build.sh`
always forces `CODE_SIGN_IDENTITY="-"`, that import never affected a single artifact.
It was pure ceremony that also kept two unused secrets alive for no benefit, so it was
removed. CI artifacts are ad-hoc-signed, identically to a local `scripts/build.sh` run.

---

## Future: Proper Distribution Signing

For Gatekeeper-transparent distribution (no right-click workaround), you would need:

1. An **Apple Developer ID Application** certificate (requires paid Apple Developer
   Program membership).
2. **Notarization** via `xcrun notarytool submit` after signing.
3. **Stapling** with `xcrun stapler staple`.

This is out of scope for the current project and is documented here only for
reference. It is tracked as the deferred Phase 07 (`full-brand-independence` plan):
create the certificate, wire it into CI, and publish the first signed (or at least
consistently ad-hoc, clearly-labeled) release.

> **Repo note**: The repo is `quangyendn/UsagePaceCC`. The Xcode project file was
> renamed to `UsagePaceCC.xcodeproj` (Phase 03 of the `full-brand-independence` plan);
> it is no longer `Usage4Claude.xcodeproj`.

---

## Keychain ACLs and Ad-Hoc Signing

Reading the Antigravity app's own keychain credential (the optional "keychain
source" for Antigravity usage monitoring) requires the user to grant this app
access to that item, via the standard macOS "Allow" / "Always Allow" prompt.

That grant is bound to the requesting app's **code signature**. This matters
because of how this project signs:

- Every build here — local Xcode, `scripts/build.sh`, and CI — is ad-hoc signed
  with a **per-build ephemeral identity** (see the table at the top of this
  document). There is no stable signing identity across builds.
- Consequence: the ACL grant on the `gemini`/`antigravity` keychain item is
  invalidated by every rebuild during local development, and by every released
  update for end users.

**Consequence for developers:** expect the keychain "Allow" prompt on every
rebuild while working on the Antigravity source. A stable local self-signed
identity (already tracked above as future work) removes this friction. In
practice, use Google sign-in instead of the keychain source during development.

**Consequence for users:** after installing an update, the Antigravity
*keychain* source (not the Google sign-in source, which is unaffected) shows a
"Reconnect" row once, and the user must grant Keychain access again. **This is
expected behavior, not a bug** — it is a direct, unavoidable consequence of
ad-hoc signing with a per-build identity, and it is the primary reason Google
sign-in is documented as the recommended way to connect Antigravity (see
`docs/ANTIGRAVITY_INTEGRATION.md`). A Developer ID certificate + notarization
(the deferred future-work item above) would also stabilize this, since it
gives the app one durable signing identity across releases.

When granting access, the "Always Allow" choice should be scoped to the single
`gemini` (`acct=antigravity`) keychain item being requested — never grant
blanket keychain access beyond what the specific prompt names.

---

## Entitlements: Why the App Listens on Localhost

`UsagePaceCC.entitlements` includes `com.apple.security.network.server`, which
permits the sandboxed app to accept incoming network connections. This is new
as of the Antigravity feature and is otherwise unused by the app.

**Why it's needed:** Antigravity's Google sign-in uses an installed-app OAuth
client, and Google's OAuth flow for installed/desktop apps only supports
**loopback redirects** (`http://127.0.0.1:<port>/...`) — it cannot redirect
into a custom URL scheme the way some mobile/native flows do. Completing a
sign-in therefore requires the app to briefly bind a TCP listener on
`127.0.0.1` to receive the redirect. Inside the App Sandbox, accepting any
inbound connection — even one on loopback initiated by the OS's own browser —
requires this entitlement; without it, `NWListener` fails to bind and sign-in
cannot complete.

**Scope of the listener, stated so a reviewer does not need to read the
source:**

- Binds `127.0.0.1` only — **never** `0.0.0.0` or any routable interface. It is
  not reachable from the network or from other devices.
- Accepts exactly one request (the OAuth redirect), then stops accepting.
- Exists only while a sign-in is actually in progress — it is created when the
  user starts the Antigravity Google sign-in flow and torn down immediately on
  success, on user cancellation, or after a 180-second timeout, whichever comes
  first.
- It is the app's **only** listening socket. If a future change adds another
  one, this section should be revisited and the entitlement's justification
  re-verified.
