---
phase: 5
title: "Settings, welcome, i18n, autostart, update check"
status: pending
effort: 14h
---

# Phase 05 — Settings, welcome, i18n, autostart, update check

## i18n

- `scripts/strings-to-json.mjs`: parse `UsagePaceCC/Resources/<lang>.lproj/Localizable.strings` (`"key" = "value";`, skip `//` comments, unescape `\"` `\n`) → `tauri-app/src/i18n/<lang>.json` for en, ja, zh-Hans, zh-Hant, ko, fr. Generated files are committed; npm script `i18n:sync`.
- Translate Swift format specifiers (`%@`, `%d`, `%1$@`) to `{0}`, `{1}` placeholders.
- `t(key, ...args)` helper, fallback to `en`, then key. No i18n library (KISS).
- Rust loads the same JSON via `include_str!` for tray menu/tooltip/notification texts.
- New Windows-only strings (e.g. "tray", "taskbar") added to the **.strings sources** in all 6 languages so both apps stay in sync.
- `language` setting: system (from `navigator.language` / Rust `sys-locale`) or explicit.

## Settings window (`src/settings/`) ← `Views/Settings/Tabs/*.swift`

Normal decorated window, 3 tabs:

- **General** ← `GeneralSettingsView.swift`: launch at login (`tauri-plugin-autostart`), tray icon style (color translucent / color with background / monochrome), display mode smart/custom + limit checkboxes, refresh mode + interval, language, appearance, time format, notifications toggle.
- **Accounts** ← `AuthSettingsView.swift`: per-provider sections; list with color swatch picker, alias edit (inline, like PR #7), remove; "Add via login" + "Add manually"; Codex source selector (browser / CLI) + CLI opt-in consent; Antigravity "Sign in with Google" with loopback status (hidden if OAuth config missing); diagnostics button.
- **About** ← `AboutView.swift`: version, links, "Check for updates".
- Diagnostics ← `Views/DiagnosticsView.swift` + `Helpers/SensitiveDataRedactor.swift`: connection test per account + export redacted log to a user-chosen file.

## Welcome (`src/welcome/`) ← `Views/Settings/Welcome/WelcomeView.swift`

Shown when `hasLaunched == false`: add first account (any provider), theme, preview; sets `hasLaunched`.

## Update check ← `Helpers/UpdateChecker.swift`

`GET https://api.github.com/repos/quangyendn/UsagePaceCC/releases/latest`, compare semver against Windows app version, look for a Windows asset (`*.exe`/`*.msi`); show badge in tray menu + About; open release URL. Every 24 h with 12 h guard. No auto-install.

## Acceptance

- [ ] Every setting persists across restart and takes effect without restart.
- [ ] All 6 locales render without missing keys (`npm run i18n:check` script lists keys missing per locale).
- [ ] Launch at login works after reboot.
- [ ] First launch shows welcome; second launch does not.
