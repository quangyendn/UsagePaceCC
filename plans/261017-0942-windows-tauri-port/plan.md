---
title: "Windows port of UsagePaceCC via Tauri v2"
description: "Port the macOS menu bar app to a Windows system-tray app built with Tauri v2 (Rust core + React/TS UI). Same three providers (Claude, Codex, Antigravity), multi-account, smart refresh, notifications, pace graph, 6 locales. Executed on a Windows machine."
status: pending
priority: P2
effort: 80-110h
branch: feat/windows-tauri-port
tags: [port, windows, tauri, rust, frontend]
created: 2026-10-17
---

# Windows Port (Tauri v2) — Implementation Plan

## Overview

The macOS app (`UsagePaceCC/`, ~24k LOC Swift) uses SwiftUI, AppKit, WebKit, Keychain and other
macOS-only frameworks, so it **cannot be compiled on Windows**. This plan builds a **new app** in
`tauri-app/` that reimplements the same behaviour. The Swift code is the **reference spec**: when in
doubt, read the cited Swift file and port its logic one-to-one.

The macOS app stays untouched. No shared code between the two (KISS); the only shared asset is the
localization source (`UsagePaceCC/Resources/*.lproj/Localizable.strings`), converted by a script.

## Architecture (decided)

| Concern | macOS (reference) | Windows (this plan) |
|---|---|---|
| Shell | NSStatusItem + NSPopover | Tauri tray icon + frameless popup window (`tauri-plugin-positioner`, hide on blur) |
| UI | SwiftUI | React 18 + TypeScript + Vite, plain CSS (no UI framework) |
| Network | URLSession | Rust `reqwest` (fallback: fetch inside a hidden WebView2 — see Phase 00 spike) |
| Secrets | Keychain JSON array | `keyring` crate → Windows Credential Manager, **one entry per account** (2.5 KB blob limit) |
| Settings / account metadata | UserDefaults | `tauri-plugin-store` → `%APPDATA%\com.quangyendn.usagepacecc\settings.json` |
| Claude / Codex login | WKWebView cookie poll | Tauri `WebviewWindow` (isolated data dir) + `cookies_for_url()` poll |
| Antigravity login | ASWebAuthenticationSession + NWListener | default browser + `tiny_http` loopback on `127.0.0.1:<rand>` + PKCE |
| Notifications | UNUserNotificationCenter | `tauri-plugin-notification` |
| Launch at login | SMAppService | `tauri-plugin-autostart` |
| Single instance | — | `tauri-plugin-single-instance` |
| Tray glyph | NSImage lockFocus | Rust `tiny-skia` → RGBA → `TrayIcon::set_icon` |
| Packaging | ad-hoc signed .app/.dmg | `tauri build` → NSIS `.exe` + MSI (unsigned first) |

Rule: **all network, credential and scheduling logic lives in Rust**. The frontend only renders state
pushed by Rust events (`usage://updated`) and calls Tauri commands. Credentials never reach JS.

## Target layout

```
tauri-app/
  package.json, vite.config.ts, tsconfig.json, index.html
  src/                       # React UI
    popup/                   # tray popup (usage detail + pace graph)
    settings/                # settings window (General / Accounts / About)
    welcome/                 # first-launch onboarding
    i18n/                    # generated <lang>.json + t() helper
    lib/tauri-api.ts         # typed invoke/listen wrappers
  src-tauri/
    Cargo.toml, tauri.conf.json, capabilities/
    src/
      main.rs, lib.rs
      models/                # account.rs, usage.rs, settings.rs
      providers/             # claude.rs, codex_browser.rs, codex_cli.rs, antigravity.rs, http_headers.rs
      auth/                  # web_login.rs, google_oauth.rs, loopback_server.rs
      storage/               # secret_store.rs, settings_store.rs
      refresh/               # refresh_engine.rs, smart_mode.rs, reset_verifier.rs
      notify/                # notification_rules.rs
      tray/                  # glyph_renderer.rs, tray_manager.rs, urgency_ranking.rs
      commands.rs            # #[tauri::command] surface
    tests/fixtures/          # captured JSON responses (redacted)
scripts/strings-to-json.mjs  # .strings → tauri-app/src/i18n/*.json
```

## Phases

| # | Phase | Effort | Gate |
|---|---|---|---|
| 00 | [Windows env, scaffold, risk spikes](phase-00-windows-env-scaffold-and-spikes.md) | 8h | **Hard gate**: Claude fetch + cookie extraction must work |
| 01 | [Rust core: models, storage, accounts](phase-01-rust-core-models-and-storage.md) | 12h | `cargo test` green |
| 02 | [Providers + login flows](phase-02-providers-and-login-flows.md) | 24h | Real fetch for each provider on Windows |
| 03 | [Refresh engine + notifications](phase-03-refresh-engine-and-notifications.md) | 12h | State-machine unit tests green |
| 04 | [Tray glyph + popup UI + pace graph](phase-04-tray-glyph-and-popup-ui.md) | 16h | Visual check light/dark, 100/125/150% DPI |
| 05 | [Settings, welcome, i18n, autostart, update check](phase-05-settings-welcome-i18n.md) | 14h | All 6 locales render |
| 06 | [Packaging, CI, docs](phase-06-packaging-ci-docs.md) | 8h | Installer runs on clean Windows 11 |

Phases run in order. 04 and 05 can overlap once 03's event contract is fixed.

## How to execute on the Windows machine

1. `git fetch origin && git checkout -b feat/windows-tauri-port origin/main`
2. Do Phase 00 fully, including the spikes. **Stop and report** if a spike fails both its primary and fallback.
3. For each phase: implement → `cargo test` + `cargo clippy -- -D warnings` + `npm run build` → manual check → commit (English message, no co-author).
4. Use the cited Swift files as spec. Do not invent behaviour the macOS app doesn't have (YAGNI).

## Key reference files (Swift spec)

- Claude API + headers: `UsagePaceCC/Services/ClaudeAPIService.swift`, `ClaudeAPIHeaderBuilder.swift`
- Codex: `Services/CodexAPIService.swift`, `CodexCLIUsageSource.swift`, `CodexBrowserUsageSource.swift`, `Models/CodexUsageData.swift`
- Antigravity: `Services/Antigravity*.swift`, `Models/AntigravityUsageData.swift`, `Models/AntigravitySource.swift`
- Accounts: `Models/Account.swift`, `Models/AccountUsageSnapshot.swift`, `Helpers/AccountUrgencyRanking.swift`
- Settings keys + smart mode: `Models/UserSettings.swift`
- Refresh: `Helpers/DataRefreshManager.swift`, `Helpers/TimerManager.swift`
- Notifications: `Services/NotificationManager.swift`
- Tray glyph: `App/MenuBarIconRenderer.swift`, `Helpers/ColorScheme.swift`
- Popup + graph: `Views/UsageDetailView.swift`, `Views/Components/LinearUsageGraphView.swift`, `Views/Components/UsageRowComponents.swift`
- Settings UI: `Views/Settings/Tabs/*.swift`, `Views/Settings/Welcome/WelcomeView.swift`
- Login: `Views/WebLogin/*.swift`

## Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Cloudflare blocks `reqwest` on claude.ai / chatgpt.com (TLS fingerprint) | Claude/Codex unusable | Phase 00 spike; fallback = run `fetch()` inside a hidden WebView2 window on the target origin, return JSON via IPC |
| `cookies_for_url` can't read HttpOnly `sessionKey` / `__Secure-next-auth.session-token` | No in-app login | Spike; fallback = `webview2-com` `ICoreWebView2CookieManager::GetCookies` via `with_webview`; last resort = manual paste (already supported on macOS) |
| Credential Manager 2560-byte blob limit | Save fails silently | One credential per account (`usagepacecc:<accountId>`); test with long Codex token |
| Tray icon only 16–32 px; no text beside it | Less info than macOS | Glyph only in tray; percentages in tooltip + popup. One tray icon per enabled provider |
| Antigravity OAuth client secret | Feature hidden | Read from gitignored `src-tauri/antigravity-oauth.json` at build (`include_str!` behind cfg) — same contract as macOS plist |
| Codex CLI token rotation | Breaks user's CLI | Port the **read-only, never refresh** rule verbatim |

## Out of scope

Usage history/time-series (macOS has none), auto-updater (only "new version" check), code signing,
macOS/Linux builds of the Tauri app, sharing code with the Swift app.

## Unresolved questions

1. Tray: one icon per provider (default in this plan) vs a single combined icon?
2. Installer: NSIS only, or also MSI? (plan builds both; drop MSI if WiX causes trouble)
3. Release: publish Windows builds in the same GitHub release as macOS, or a separate tag (`win-v*`)?
4. Antigravity keyring source (reading `agy`'s credential on Windows) — ship in v1 or OAuth-only? Plan: spike in Phase 02, ship only if it works cleanly.
