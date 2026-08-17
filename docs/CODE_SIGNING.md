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
