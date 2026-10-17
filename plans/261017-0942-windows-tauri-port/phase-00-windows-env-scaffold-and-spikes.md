---
phase: 0
title: "Windows env, scaffold, risk spikes"
status: pending
effort: 8h
---

# Phase 00 — Windows env, scaffold, risk spikes

## 1. Toolchain (Windows 10 22H2+ / 11)

Run in PowerShell:

```powershell
winget install --id Git.Git -e
winget install --id OpenJS.NodeJS.LTS -e
winget install --id Rustlang.Rustup -e
winget install --id Microsoft.VisualStudio.2022.BuildTools -e --override "--quiet --wait --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
rustup default stable-x86_64-pc-windows-msvc
```

- WebView2 runtime: preinstalled on Win11; on Win10 `winget install Microsoft.EdgeWebView2Runtime`.
- Verify: `rustc -V`, `cargo -V`, `node -v` (≥ 20), `npm -v`, `git --version`.
- Optional: `cargo install tauri-cli --version "^2" --locked` (otherwise use `npx tauri`).
- Enable long paths if clone path is deep: `git config --global core.longpaths true`.

## 2. Scaffold

```powershell
git checkout -b feat/windows-tauri-port origin/main
npm create tauri-app@latest tauri-app -- --template react-ts --manager npm --identifier com.quangyendn.usagepacecc
cd tauri-app; npm install; npm run tauri dev
```

- `tauri.conf.json`: productName `UsagePaceCC`, main window **not** created at startup (`"windows": []`), app runs tray-only.
- Add plugins: `npm run tauri add store notification autostart positioner single-instance opener`.
- Rust deps: `reqwest` (json, cookies off, rustls-tls), `serde`, `serde_json`, `tokio`, `chrono`, `keyring` (windows-native feature), `tiny-skia`, `tiny_http`, `sha2`, `base64`, `rand`, `thiserror`, `tracing`.
- Add `tauri-app/` entries to root `.gitignore`: `tauri-app/node_modules/`, `tauri-app/src-tauri/target/`, `tauri-app/dist/`, `tauri-app/src-tauri/antigravity-oauth.json`.
- Skeleton: tray icon with a static icon + "Quit" menu item; left-click toggles an empty popup window positioned with `Position::TrayBottomCenter`, hidden on blur.

## 3. Spikes (hard gate — write results to `plans/261017-0942-windows-tauri-port/reports/spike-results.md`)

### S1 — Claude fetch from Rust
- Dev-only command: given a sessionKey (from a real browser, pasted in a dev env var `UPCC_SPIKE_SESSION_KEY`), `GET claude.ai/api/organizations` with the exact header set from `UsagePaceCC/Services/ClaudeAPIHeaderBuilder.swift` (update the UA to a Windows Chrome UA).
- Try `rustls-tls` first, then `native-tls` (Schannel).
- **Pass** = HTTP 200 + JSON array. **Fallback** if both 403 with Cloudflare HTML: hidden `WebviewWindow` loaded at `claude.ai/`, run `fetch('/api/organizations',{credentials:'include'})` via `eval` and post the result back with `emit`. Prove the fallback works before continuing.
- Repeat quickly for `https://chatgpt.com/api/auth/session` (Codex browser source).

### S2 — Cookie extraction from a login webview
- Open `WebviewWindow` at `claude.ai/login` with an isolated `data_directory` under `%LOCALAPPDATA%\…\login-<uuid>` (delete after use).
- Poll `webview.cookies_for_url("https://claude.ai")` every 1s; look for `sessionKey`.
- **Pass** = cookie value obtained after manual login (including HttpOnly). **Fallback** = `with_webview` → `webview2_com` `ICoreWebView2_2::CookieManager().GetCookies("https://claude.ai")`.
- Same check for `__Secure-next-auth.session-token` on `https://chatgpt.com`.

### S3 — Credential Manager size
- Write/read a 4 KB string with `keyring::Entry::new("usagepacecc", "probe")`. Expect failure > 2560 bytes → confirms one-entry-per-account design; if a single Codex token alone exceeds the limit, split into chunks `<id>#0`, `<id>#1`.

## Acceptance

- [ ] `npm run tauri dev` shows tray icon; popup toggles and hides on blur.
- [ ] S1 and S2 pass (primary or fallback); chosen path recorded in `reports/spike-results.md`.
- [ ] S3 limit recorded.
- [ ] Commit: `chore(windows): scaffold Tauri app and record spike results`.
