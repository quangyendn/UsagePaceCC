---
phase: 4
title: "Tray glyph + popup UI + pace graph"
status: pending
effort: 16h
---

# Phase 04 — Tray glyph + popup UI + pace graph

## Tray (`tray/`)

- `glyph_renderer.rs` ← `App/MenuBarIconRenderer.swift`: `tiny-skia` render at 32×32 (and 16/24/48 when DPI requires; pick by `scale_factor`):
  - outer ring = 5h % (stroke ≈ 2.5/22 of size, translucent track), inner pie wedge = 7d % (inset ≈ 5.5/22).
  - Color = account color, or monochrome style; near-limit warning mark ≥ 90 %.
  - Two accounts in one icon: draw the top urgent account only; second account stays in tooltip (tray is too small).
- `tray_manager.rs`: **one tray icon per provider that has ≥ 1 account** (ids `tray-claude`, `tray-codex`, `tray-antigravity`); account chosen by `top_urgent_accounts(limit=1)`.
  - Tooltip: `Claude · Work: 5h 42% · 7d 63%` per account, multi-line.
  - Left click → toggle popup anchored to that tray (`tauri-plugin-positioner`, `TrayBottomCenter`; flip above taskbar automatically).
  - Right click menu ← `MenuBarUI.swift`: Refresh, accounts submenu per provider (checkmark = current), Settings…, Check for updates, Quit.
  - Cache rendered icons by data hash (as macOS does) to avoid flicker.
  - Light/dark taskbar: monochrome style uses white on dark taskbar (read `AppsUseLightTheme`/`SystemUsesLightTheme` registry value; re-check on each render).

## Popup window (`src/popup/`) ← `Views/UsageDetailView.swift` + components

- Frameless, `alwaysOnTop`, `skipTaskbar`, resizable false, transparent rounded corners, hide on blur. Height computed like `PopoverLayout.swift` (base 190 + 26 per row + 5 spacing) and set via `window.setSize`.
- Header: app name, refresh button (disabled during 10 s lockout, spinner), menu button (opens same menu as right-click).
- Rows ← `UsageRowComponents.swift`: per account × limit: mini icon, label, %, reset time (12h/24h/system via `TimeFormatHelper.swift` rules, `Intl.DateTimeFormat`).
- Error rows per account (Unauthorized → "Log in again" button opening the login flow).
- Display mode: smart (show every limit that has data) / custom (checked types only).

## Pace graph (`src/popup/PaceGraph.tsx`) ← `Views/Components/LinearUsageGraphView.swift`

- SVG 262×100. X = elapsed fraction `1 - timeUntilReset / windowSeconds` (0…1), Y = % (0…100).
- Grid lines + ideal pace diagonal (0,0)→(1,100), 1.5 px, legible on grid (see commit 9c534c6).
- One dot per account per window: 5h = outline ring, 7d = filled; account color. Skip points with reset time but no window length. Legacy opus/sonnet/extra dots colored by % tier.
- Legend ← existing legend component (7d swatch filled, see commit 927c989).

## Theming

CSS variables for light/dark; `appearance` setting = system / light / dark (`data-theme` on `<html>`). Account colors from Rust (hex light/dark).

## Acceptance

- [ ] Tray icons update live with real data; tooltip correct.
- [ ] Popup opens next to the correct tray icon on bottom and top taskbar, closes on outside click.
- [ ] Visual check at 100 / 125 / 150 % scaling, light and dark; screenshots into `reports/`.
- [ ] Graph dots match macOS app for the same account (compare side by side if possible).
