---
phase: 6
title: "Packaging, CI, docs"
status: pending
effort: 8h
---

# Phase 06 — Packaging, CI, docs

## Packaging

- Icons: `npx tauri icon UsagePaceCC/Resources/Assets.xcassets/AppIcon.appiconset/<largest>.png` → `src-tauri/icons/` (includes `.ico`).
- `tauri.conf.json > bundle`: targets `["nsis", "msi"]`, publisher, copyright, `windows.webviewInstallMode = downloadBootstrapper`, NSIS `installMode = currentUser` (no admin).
- `npm run tauri build` → `src-tauri/target/release/bundle/{nsis,msi}/`.
- Unsigned: document the SmartScreen "More info → Run anyway" step in README (same honesty as macOS ad-hoc signing docs).
- Verify on a clean Windows 11 VM/Sandbox: install, tray appears, toasts show app name (not PowerShell), autostart, uninstall removes app (settings/credentials kept — document how to wipe: delete `%APPDATA%\com.quangyendn.usagepacecc` + Credential Manager entries `usagepacecc`).

## CI (`.github/workflows/windows-build.yml`)

- `windows-latest`, Node LTS, Rust stable, `Swatinem/rust-cache`, `npm ci`, `cargo test`, `cargo clippy -- -D warnings`, `npm run build`, `tauri-apps/tauri-action` building on tags `v*` and uploading NSIS/MSI to the same release as macOS (pending plan Q3).
- Antigravity OAuth config from a repository secret written to `antigravity-oauth.json` before build; absent → build without the feature.
- PR job: test + clippy + build only (no bundle).

## Docs

- `README.md`: Windows section (requirements, install, SmartScreen, feature differences: no text in tray, one icon per provider).
- `docs/WINDOWS_DEVELOPMENT.md`: toolchain, `npm run tauri dev`, project layout, how to sync i18n, how to port a new macOS feature (find Swift file → Rust module map from plan.md).
- `CHANGELOG.md`: entry for first Windows release.
- Update memory/notes: Windows app lives in `tauri-app/`, Swift is the spec.

## Acceptance

- [ ] Installer from CI artifact installs and runs on a clean Windows 11.
- [ ] CI green on PR.
- [ ] PR `feat/windows-tauri-port` → `main` opened with `gh pr create`.
