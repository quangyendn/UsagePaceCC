---
phase: 3
title: "Refresh engine + notifications"
status: pending
effort: 12h
---

# Phase 03 — Refresh engine + notifications

## Refresh engine (`refresh/`) ← `Helpers/DataRefreshManager.swift`, `Helpers/TimerManager.swift`

- Single tokio task owning state; commands talk to it via `mpsc` (`RefreshAll { force }`, `RefreshProvider(p)`, `PopupOpened`, `SettingsChanged`, `Wake`).
- Each cycle: fetch **all** accounts of all providers (Claude accounts staggered 0.4 s), update `HashMap<AccountId, AccountSnapshot>`, emit `usage://updated` with the full list, re-render tray.
- `smart_mode.rs` (pure state machine, unit-tested):

  | Level | Interval | Go down after |
  |---|---|---|
  | active | 60 s | 3 unchanged polls |
  | idleShort | 180 s | 6 unchanged |
  | idleMedium | 300 s | 12 unchanged |
  | idleLong | 600 s | — |

  Any provider max-utilization change > 0.01 → back to active. Popup open / manual refresh → active.
- Fixed mode: `refreshInterval` (60/180/300/600 s).
- Debounce: manual refresh 10 s lockout (UI spinner min 1 s); popup open skips fetch if last fetch < 30 s; per-provider refresh when user clicks a provider row.
- `reset_verifier.rs`: for every known `resets_at`, schedule one-shot refreshes at +1 s, +10 s, +30 s per account (dedupe by account+window+timestamp).
- Wake from sleep: no NSWorkspace equivalent — detect wall-clock jump (> 2× interval between ticks) and trigger refresh after 3 s. Good enough, no Win32 hooks (KISS).

## Notifications (`notify/notification_rules.rs`) ← `Services/NotificationManager.swift`

Pure fn `evaluate(prev, curr, warned_set) -> (Vec<Notification>, warned_set)`, then send via `tauri-plugin-notification` if `notificationsEnabled`.

- Warning when crossing `< 90 → ≥ 90`, once per key `provider:accountId:limitType`.
- Extra 75 % warning for 7-day windows (`sevenDay`, `codexSecondary`).
- Reset: (prev ≥ 90 and drop > 30 pts) **or** (`resets_at` changed and % fell) → reset notification, clear warned keys for that window.
- Limit types: 5h, 7d, opus, sonnet, extra, codex primary/secondary/extra, antigravity buckets.
- Notification text from i18n keys already in `Localizable.strings` (Rust side loads the same generated JSON — see Phase 05; until then use English).
- Windows needs an AppUserModelID for toasts: in dev it shows as PowerShell; verify on the installed build in Phase 06.

## Tests

Smart-mode transitions (table-driven), debounce windows, reset-verifier scheduling, every notification rule including no duplicate warnings and reset clearing.

## Acceptance

- [ ] Tests green.
- [ ] With 1 real account, log shows interval stepping 60 → 180 → 300 → 600 s when idle and snapping back to 60 s on popup open.
- [ ] Forcing a fake snapshot ≥ 90 % (debug command) shows one Windows toast, not repeated.
