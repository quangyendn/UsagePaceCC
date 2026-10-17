---
phase: 2
title: "Providers + login flows"
status: pending
effort: 24h
---

# Phase 02 — Providers + login flows

Each provider exposes `async fn fetch(account, secret) -> Result<AccountSnapshot, ProviderError>`.
`ProviderError` variants: `Unauthorized`, `Cloudflare`, `SubscriptionRequired`, `RateLimited`, `Expired`, `Network(String)`, `Parse(String)`.
Use the HTTP path chosen in Phase 00 (reqwest or WebView fetch bridge). Save one redacted real response per endpoint into `src-tauri/tests/fixtures/` and unit-test every parser against it.

## Claude (`providers/claude.rs`) ← `ClaudeAPIService.swift`, `ClaudeAPIHeaderBuilder.swift`

- `http_headers.rs`: browser header set (accept, accept-language, content-type, `anthropic-client-platform: web_claude_ai`, `anthropic-client-version: 1.0.0`, Chrome **Windows** UA, origin, referer `claude.ai/settings/usage`, sec-fetch-*). Cookie header `sessionKey=<key>`; no cookie jar.
- `GET /api/organizations` → org list (used at login + validation).
- `GET /api/organizations/{uuid}/usage` → `five_hour`, `seven_day`, `seven_day_opus`, `seven_day_sonnet`; round `resets_at` to the second; drop opus/sonnet when util 0 and `resets_at` null. Window seconds: 18000 / 604800.
- `GET /api/organizations/{uuid}/overage_spend_limit` optional, non-fatal; cents ÷ 100; legacy field names (`monthly_credit_limit`, `spend_limit_amount_cents`).
- 401 → Unauthorized; 403 with HTML → Cloudflare.

## Codex

- Router (`providers/codex.rs`) ← `CodexAPIService.swift`: pick preferred source; fall back only if the other is **unconfigured**, never on failure.
- Browser source ← `CodexBrowserUsageSource.swift`: `GET https://chatgpt.com/api/auth/session` (cookie `__Secure-next-auth.session-token`) → `accessToken`, `user.email`; then `GET https://chatgpt.com/backend-api/wham/usage` with Bearer.
- CLI source ← `CodexCLIUsageSource.swift`: read `%CODEX_HOME%\auth.json` else `%USERPROFILE%\.codex\auth.json`. Decode JWT payloads (no verify) for `exp`, email, `https://api.openai.com/auth.chatgpt_account_id`, plan. **Never refresh**; expired → `Expired` with no network call. Headers: Bearer, `User-Agent: codex-cli`, `ChatGPT-Account-Id`. Port consent hash + dismissed-keys logic.
- Parser ← `Models/CodexUsageData.swift`: `rate_limit.primary_window/secondary_window` (`used_percent`, `limit_window_seconds`, `reset_at` unix), `credits` (balance may be string or number), `spend_control.reached`. Window length is data-driven.

## Antigravity (`providers/antigravity.rs`) ← `Services/Antigravity*.swift`

- `POST https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary`, body `{}`, Bearer, `User-Agent: antigravity-cli/1.1.27` (must contain "Antigravity"). Never call singular `retrieveUserQuota`.
- Flatten `groups[].buckets[]`; `% = (1 - remainingFraction) * 100`; window map weekly=604800, daily=86400, 5h/five_hour=18000; bucket0→fiveHour slot, bucket1→sevenDay slot.
- 300 s per-account throttle (bypass on forced manual refresh). 401/403/429 mapping as in Swift.
- Token provider: in-memory access-token cache, 60 s expiry margin, refresh via `POST https://oauth2.googleapis.com/token` (`grant_type=refresh_token`); `invalid_grant` → Unauthorized (revoked).

## Login flows (`auth/`)

- `web_login.rs` (Claude + Codex): open `WebviewWindow` (isolated data dir, Phase 00 S2 method), poll cookies every 1 s, on hit: close window, delete data dir, validate (Claude: `/api/organizations` → one account per org the user picks, or the first; Codex: `/api/auth/session` → email as name), save metadata + secret, emit `accounts://changed`. Timeout/close → cancelled.
- Manual entry command for Claude (sessionKey + optional orgId) and Codex (session token), same validation.
- `google_oauth.rs` + `loopback_server.rs` ← `AntigravityOAuth*.swift`, `AntigravityLoopbackServer.swift`: PKCE S256, `state`, `access_type=offline`, `prompt=consent`, scopes copied from Swift; `tiny_http` on `127.0.0.1:0`, path `/callback`, 180 s timeout, single request; open URL with `tauri-plugin-opener`. Exchange code → tokens → `tokeninfo` (email, sub). Store refresh token as secret; `organization_id = sub`, name = email. Sign-out calls `/revoke`.
- OAuth client config: `src-tauri/antigravity-oauth.json` (gitignored; commit `antigravity-oauth.example.json`). Load via `build.rs` → if missing, compile with Antigravity OAuth disabled and hide it in UI.
- Optional spike: Antigravity "agy" credential on Windows (go-keyring → Credential Manager target likely `gemini:antigravity`, payload `go-keyring-base64:` + base64 JSON). Ship only if found and parsable; otherwise skip (plan Q4).

## Tests

Fixture parsers for all 6 endpoints, JWT decode, Codex source routing table, Antigravity bucket flattening + window map, PKCE challenge (RFC 7636 test vector).

## Acceptance

- [ ] Log in to real Claude, Codex (browser), Codex (CLI auth.json), Antigravity (OAuth) on the Windows machine; each returns a snapshot (log via `tracing`).
- [ ] Expired Codex CLI token → `Expired`, no HTTP request made (check logs).
- [ ] Commit per provider: `feat(windows): add <provider> provider and login`.
