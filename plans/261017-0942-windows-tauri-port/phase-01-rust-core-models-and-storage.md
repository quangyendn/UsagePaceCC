---
phase: 1
title: "Rust core: models, storage, accounts"
status: pending
effort: 12h
---

# Phase 01 — Rust core: models, storage, accounts

## Models (`src-tauri/src/models/`)

Port 1:1, `#[derive(Serialize, Deserialize, Clone, Debug)]`, `camelCase` for the JS side.

- `account.rs` ← `Models/Account.swift`
  - `Account { id: Uuid, provider: Provider, organization_id, organization_name, alias: Option<String>, color: AccountColor, created_at }`
  - **Secret (`session_key`) is NOT in this struct** — stored separately (see storage). Metadata goes to the store, secret goes to Credential Manager.
  - `display_name()` = alias else organization_name.
  - `AccountColor` 8-value enum (blue, orange, aqua, yellow, magenta, green, violet, red) with light/dark hex copied from Swift; default color derived deterministically from id (port the Swift hash).
  - Deterministic pseudo-account ids: Codex CLI (copy from `CodexCLIUsageSource.swift`), Antigravity keychain `A9F9CA7E-0000-4000-8000-00000000AA61`.
- `usage.rs` ← `UsageData`, `CodexUsageData`, `AntigravityUsageData`, `AccountUsageSnapshot`
  - Common `WindowUsage { percentage: f64, resets_at: Option<DateTime<Utc>>, window_seconds: Option<u64>, source_label: Option<String> }`
  - `AccountSnapshot { account_id, provider, five_hour: Option<WindowUsage>, seven_day: Option<WindowUsage>, opus, sonnet, extra: Option<ExtraUsage>, error: Option<ProviderError>, fetched_at }`
- `settings.rs` ← `Models/UserSettings.swift`: port only keys that matter on Windows: current account ids ×3, `codexSource`, `antigravitySource`, `codexCLIEnabled`, consent hashes + dismissed keys, `iconStyleMode`, `refreshMode`, `refreshInterval`, `displayMode`, `customDisplayTypes`, `language`, `appearance`, `timeFormatPreference`, `notificationsEnabled`, `launchAtLogin`, `hasLaunched`. Drop macOS-only ones (icon display "percentageOnly" etc. — tray can't show text).

## Storage (`src-tauri/src/storage/`)

- `settings_store.rs`: wrapper over `tauri-plugin-store` (`settings.json`) holding `Settings` + `accounts: Vec<Account>` per provider. Versioned: `"schemaVersion": 1`.
- `secret_store.rs`: `keyring::Entry::new("usagepacecc", "<provider>:<accountId>")`. API: `set(account_id, secret)`, `get`, `delete`. Chunking only if S3 showed it's needed. In `debug_assertions` builds optionally use a plain JSON file (mirror macOS DEBUG UserDefaults behaviour) behind env `UPCC_PLAIN_SECRETS=1`.
- Account removal deletes both metadata and secret, atomically from the caller's view (delete secret first, then metadata; log on partial failure).

## Commands (`commands.rs`)

`list_accounts(provider)`, `rename_account(id, alias)`, `set_account_color(id, color)`, `remove_account(id)`, `set_current_account(provider, id)`, `get_settings`, `update_settings(patch)`. All return `Result<T, String>` with user-safe messages.

## Pure helpers

- `tray/urgency_ranking.rs` ← `Helpers/AccountUrgencyRanking.swift`: `top_urgent_accounts(snapshots, limit=2)` sort by 5h % else 7d %, tie-break by id.
- Color tiers ← `Helpers/ColorScheme.swift` (thresholds per limit type) as a pure fn returning hex — shared by tray renderer and sent to UI.

## Tests

`cargo test`: account JSON round-trip + backward-compat (missing color/provider), color derivation stable, urgency ranking ties, settings default values match Swift defaults (`refreshInterval` 180, etc.).

## Acceptance

- [ ] `cargo test` + `cargo clippy -- -D warnings` green.
- [ ] Add/rename/remove a dummy account via devtools `invoke` → visible in `settings.json`, secret visible in Windows Credential Manager (Generic credentials, `usagepacecc`), removed cleanly.
