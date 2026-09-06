# Product Design Philosophy

## 1. Project Positioning

UsagePaceCC is a menu bar utility the author built for personal use and for users with similar needs. It has the following non-negotiable attributes:

- **Small and beautiful**: Not chasing broad feature coverage, large user base, or market size
- **Restraint**: Not every reasonable request will be accepted; the author's aesthetic is the baseline
- **Open source, not commercial**: Open to more users, but not at the cost of the product's soul
- **Craftsmanship first**: Every new feature must first pass the "does this fit the product's soul" test

## 2. Core Design Principles

### 2.1 State-driven Progressive Disclosure

UI shape is determined by the user's actual account state, not by feature flags.

- The typical feature-flag approach: the user ticks "Enable Codex support" in settings → Codex elements appear. This pollutes the settings panel and makes Claude-only users aware of Codex.
- This project uses a state-driven approach: the user logs in to a Codex account in account management → the UI automatically adapts to the form that has Codex. With only Claude logged in, the word "Codex" never appears.

**Codex is not a feature — it is a state of existence.**

### 2.2 Provider Equality

Once the user enters multi-provider state, Claude, Codex and Antigravity are **equal providers** with no hierarchy. No provider is deliberately downplayed or elevated relative to the others.

- Equal visual weight
- Equal naming, color, and icon recognizability
- Equal account management entry points in the settings panel
- Equal data refresh priority

### 2.3 A Small, Closed Set of Providers — Not an Extension Point

The product supports Claude, Codex and Antigravity. That set is closed and expressed as a Swift enum, not as configuration.

- The constraint was never the number two. It is: **a small, closed set of providers the author uses daily, each rendered as a first-class peer.** A provider earns a slot by being in the author's daily workflow, not by being requested.
- What remains banned, unchanged: generic `[String: ProviderConfig]` registries, plugin layers, "add your own provider" configuration. Every provider is an explicit enum case with explicit branches, so the compiler enumerates the work when the set changes.
- The cost of each addition is real and visible — every exhaustive `switch` in the app, six locales, a menu bar glyph budget, and in Antigravity's case a second credential source and an OAuth flow. That cost is the gate.
- When someone requests a fourth provider, the honest answer is still "probably no", for the same reason as before.

> **Amended 2026-09:** this section originally read "the product hard-limits itself to Claude + Codex" and asserted a two-provider cap. Antigravity was added because it became part of the author's daily workflow and fit the existing account-driven rendering path (`UsageProvider` protocol, per-account snapshots, dual-source arbitration already proven by Codex) without a new abstraction. The prohibition on a generic provider registry did not change — only the number did. This note exists so the amendment reads as a recorded decision, not a silently redrawn boundary.

## 3. Boundaries of Design Decisions

### 3.1 When to say "yes"
- The new feature fits the product soul (small and beautiful, restrained)
- The implementation path does not pollute existing user experience
- The code forms a symmetric, clean abstraction

### 3.2 When to say "no"
- The new feature requires a settings toggle for existing users not to be disturbed → usually the wrong direction
- The new feature requires compromising the existing visual language for a specific user group
- The new feature "looks cool but is rarely used"
- The new feature expands TAM rather than solving a real need

## 4. Honest External Positioning

The first sentence of the README cannot pretend this is a "universal multi-AI tool", but also cannot pretend there is no Codex or Antigravity support.

Reference phrasing:
> Track your Claude (and optional Codex) subscription quota — beautifully, in your menu bar.

Codex's and Antigravity's placement should be in the subtitle/Features section rather than the hero image, consistent with the true product state of "author's personal need + nice to have". The hero line stays Claude-first even as the provider set grows — a peer provider earning equal treatment inside the app is not the same as earning the first sentence of the pitch.

## 5. Technical Decisions Derived from Philosophy

The following technical choices are not engineering preferences — they are extensions of the philosophy:

| Philosophy principle | Derived technical decision |
|---|---|
| Claude-only users have zero awareness | Don't change Bundle ID, repo name, product name, or user data |
| State-driven UI | Popover width, menu bar icon grouping derived from `accounts.contains(where: provider == .codex)` |
| Provider equality | Abstract `UsageProvider` protocol; `Account` model with `provider` field; Claude doesn't "hold primary position" in code |
| A small, closed provider set | Don't introduce generic `[String: ProviderConfig]`; use an enum to explicitly express the closed set |

## 6. Revision History

- **2026-09**: Added Antigravity as a third provider. §2.2 (Provider Equality) extended from two to three providers. §2.3 rewritten — the boundary was never literally "two"; it was always "a small, closed set of providers the author uses daily, each a first-class peer," and that is what is now written down. The registry/plugin-layer prohibition is unchanged. §4 and the §5 table row updated to match. See `docs/ANTIGRAVITY_INTEGRATION.md` for the technical detail behind this addition.
