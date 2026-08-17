# Upstream Sync — Procedure & Reference

**Fork:** `quangyendn/UsagePaceCC`
**Upstream:** `f-is-h/Usage4Claude`
**Last updated:** 2026-08-17

`quangyendn/UsagePaceCC` is a standalone repository (detached from the GitHub fork
network in Phase 05 of the `full-brand-independence` plan). "Fork" below is used
loosely, in the git-history sense: this repo's history originates from
`f-is-h/Usage4Claude` and still pulls occasional fixes from it via cherry-pick, even
though GitHub no longer tracks a fork relationship between the two.

---

## Branch Topology

```
upstream/main  ──────●──●──●──●──●──────────────►  (f-is-h releases)
                      \           \
upstream-mirror  ──────●──●──●──●──●──────────────►  (ff-only mirror, never commit here)
                                     \
main (UsagePaceCC)  ───────────────────●──●──●──►  (rebrand line; diverges here)
                                          |
                              upstream-sync/YYYY-MM-DD  ──► (ephemeral review branch)
                              (created by CI, deleted after merge/close)
```

### Three permanent branches

| Branch | Purpose | Push policy |
|--------|---------|-------------|
| `upstream-mirror` | Exact fast-forward-only copy of `upstream/main` | Force-push allowed (mirror semantics) |
| `main` | Fork rebrand; receives cherry-picked upstream fixes | Normal push; NEVER auto-merged from upstream |
| `upstream-sync/<date>` | Ephemeral; created by CI for human-review PRs | Delete after merge or close |

**Key invariant:** `upstream-mirror` is NEVER merged into `main` directly. Commits flow via cherry-pick, individually reviewed by a human.

---

## Setup (already completed)

The one-time bootstrap below was performed during the initial fork setup and again
verified after the Phase 05 rename/detach. It does not need to be re-run; this section
is now a **verification checklist**, not an instruction list.

### 1. Remotes

```bash
git remote -v
# Expected:
#   origin   git@github.com:quangyendn/UsagePaceCC.git (fetch)
#   upstream https://github.com/f-is-h/Usage4Claude.git (fetch)

# If upstream is missing:
git remote add upstream https://github.com/f-is-h/Usage4Claude.git
```

### 2. `upstream-mirror` branch

Already exists on `origin`. Verify:

```bash
git ls-remote origin upstream-mirror
# Should print a SHA and refs/heads/upstream-mirror
```

### 3. GitHub labels

`security` and `upstream-sync` already existed; `dependencies` was created in Phase 06.
All three are confirmed present:

```bash
gh label list --repo quangyendn/UsagePaceCC
# security, upstream-sync, dependencies should all be listed
```

If any label is ever missing (e.g. a fresh clone under a different repo), recreate it:

```bash
gh label create security      --color d73a4a --description "Security or vulnerability fix" --repo quangyendn/UsagePaceCC
gh label create upstream-sync --color 0075ca --description "Automated upstream sync PR"   --repo quangyendn/UsagePaceCC
gh label create dependencies  --color 0075ca --description "Dependency updates"            --repo quangyendn/UsagePaceCC
# Ignore "already exists" errors — safe to re-run
```

### 4. Dependabot and security features

Enabled under **Settings > Code security and analysis** on `quangyendn/UsagePaceCC`:

- [x] Dependency graph
- [x] Dependabot alerts
- [x] Dependabot security updates

Dependabot is configured via `.github/dependabot.yml` (already committed). It monitors
GitHub Actions pinned versions weekly and labels PRs `dependencies`.

---

## Recurring Manual Cherry-Pick Recipe

Use these commands whenever you want to manually sync without dispatching the CI workflow.

### Step 1 — Update the mirror

```bash
git fetch upstream
git checkout upstream-mirror
git merge --ff-only upstream/main   # fast-forward only; error if not possible
git push origin upstream-mirror
```

### Step 2 — Review new commits

```bash
# Commits on upstream not yet in main
git log main..upstream-mirror --oneline

# See full diff of everything new
git diff main...upstream-mirror
```

### Step 3 — Cherry-pick commits you want into main

```bash
git checkout main

# Pick one commit:
git cherry-pick -x <sha>

# Pick a range (oldest-first):
git cherry-pick -x <oldest-sha>^..<newest-sha>

# Pick the last N commits from upstream-mirror:
git cherry-pick -x upstream-mirror~N..upstream-mirror
```

The `-x` flag appends `(cherry picked from commit <sha>)` to the commit message, creating an audit trail.

### Step 4 — Handle already-applied commits (f3446b9 caveat)

The merge commit `f3446b9` (2026-06-21) already brought some upstream history into `main`. When cherry-picking a range that overlaps this merge, git will detect the commits as empty:

```
error: The previous cherry-pick is now empty, possibly due to conflict resolution.
```

Skip empty cherry-picks with:

```bash
git cherry-pick --skip
```

Or use `--allow-empty` if you explicitly want to record the intent:

```bash
git cherry-pick -x --allow-empty <sha>
```

### Step 5 — Tag the last reviewed upstream SHA

```bash
# After cherry-picking, tag the upstream-mirror HEAD you reviewed through:
git tag upstream-reviewed/$(date +%Y-%m-%d) upstream-mirror
git push origin upstream-reviewed/$(date +%Y-%m-%d)
```

This tag does NOT reflect the cherry-picked commit on `main` (SHA changes after cherry-pick), only that you reviewed upstream up to this point.

---

## On-Demand Upstream Check: upstream-watch.yml

**File:** `.github/workflows/upstream-watch.yml`

**Trigger:** `workflow_dispatch` only. **There is no schedule and nothing will remind
you to run this.** Dispatch it manually whenever you feel like checking upstream;
every 1–3 months is a reasonable cadence, but nothing enforces it.

```bash
gh workflow run upstream-watch.yml --repo quangyendn/UsagePaceCC
gh run list --workflow=upstream-watch.yml --repo quangyendn/UsagePaceCC
```

**What it does:**

1. Fetches `upstream/main`, `origin/upstream-mirror`, and `origin/main`.
2. Counts new commits on upstream not yet in the mirror (`origin/upstream-mirror..upstream/main`).
3. **Zero new commits** → exits cleanly (no-op).
4. **New commits found:**
   a. Fast-forwards `upstream-mirror` to `upstream/main` via force-with-lease.
   b. Creates an `upstream-sync/<date>` branch off `origin/main`.
   c. Cherry-picks the **first** commit in `origin/main..upstream/main` into that branch as a diff seed — avoids the `gh pr create` head==base rejection. (The range is computed against `origin/main`, not the mirror, because the mirror fast-forward in step a already advances `origin/upstream-mirror` to equal `upstream/main`, which would make the mirror-based range empty.)
   d. Opens a **DRAFT PR** titled `chore: upstream sync <date> (<N> new commits)`.
   e. Applies label `upstream-sync` always; also applies `security` if any commit message matches `fix|security|vuln|patch|cve|crash|bug|sanitiz|escape|inject`.
5. **Fallback:** If the PR creation fails (e.g., cherry-pick conflict left branch at base), falls back to opening a GitHub Issue listing the new commits.

**No auto-merge ever.** The PR stays draft until a human reviews and merges.

**Permissions used:** `contents: write` (push mirror), `issues: write`, `pull-requests: write`. Only `GITHUB_TOKEN` — no PAT required.

**Why manual-only:** the fork now diverges heavily from upstream (renamed source tree,
Codex provider support, full rebrand). A weekly cron produced draft-PR churn on a
project that rarely applies upstream diffs cleanly anymore. Removing `schedule:` also
removes GitHub's 60-day inactivity auto-disable behavior for scheduled workflows — one
less silent failure mode to worry about.

**Trade-off, stated plainly:** upstream security fixes may go unnoticed for months.
This is an accepted, deliberate trade-off (decision V3/V4 of the
`full-brand-independence` plan). Dependabot still covers GitHub Actions dependency
updates automatically regardless of this workflow's cadence.

### Changing upstream branch name

If `f-is-h/Usage4Claude` renames its default branch, update the env var:

```yaml
env:
  UPSTREAM_BRANCH: main   # change to new branch name
```

---

## Path renames since the fork diverged

Phase 03 of the `full-brand-independence` plan renamed the Xcode project, target,
schemes, and source directory. Any upstream commit touching these paths will conflict
on path, not content, unless you route around the rename:

| Upstream path | Fork path |
|---|---|
| `Usage4Claude/…` | `UsagePaceCC/…` |
| `Usage4Claude.xcodeproj` | `UsagePaceCC.xcodeproj` |
| `Usage4Claude*.xcscheme` | `UsagePaceCC*.xcscheme` |

**Required recipe — always pass `-X find-renames` to cherry-pick:**

```bash
git cherry-pick -x -X find-renames <sha>

# if it still conflicts on path:
git format-patch -1 <sha> --stdout \
  | sed 's|a/Usage4Claude/|a/UsagePaceCC/|g; s|b/Usage4Claude/|b/UsagePaceCC/|g' \
  | git apply --3way
```

**Verified during Phase 03 (step 8 dry-run):** `git cherry-pick -X find-renames`
correctly routed an upstream change from the old `Usage4Claude/` paths onto the
renamed `UsagePaceCC/` tree without manual intervention. The only conflict that
surfaced during that dry-run was a genuine content divergence (a `User-Agent` string
literal that differs between the fork and upstream) — **not** a path-routing failure.
This confirms `-X find-renames` is sufficient for the common case; the `format-patch |
sed | git apply --3way` fallback above is for the rarer case where git's rename
detection itself fails to match (e.g., heavily rewritten files).

## Divergence reality

The fork is no longer a thin rebrand of upstream. It carries:

- **Codex provider support** — a feature not present upstream.
- **Full rebranding** — product name, bundle id, Xcode project/target/scheme names,
  source directory (`UsagePaceCC/` vs. `Usage4Claude/`), UI strings, icon.
- **A renamed source tree** — see the path-rename table above.

Upstream fixes touching branding, the renamed source tree, or provider-selection logic
will rarely apply cleanly via cherry-pick. When a cherry-pick fights you on a small
fix, it is usually faster and safer to **re-implement the fix by hand** in the fork's
current code than to fight the conflict resolution. Reserve the merge-scratch strategy
below for large, unavoidable upstream refactors.

---

## Cherry-Pick vs Merge — Rationale

**Cherry-pick is the default strategy for this fork.**

| Criterion | Cherry-pick | Merge |
|-----------|-------------|-------|
| Selectivity | Import only what you need | Imports everything |
| History cleanliness | Clean; each pick is atomic | Merge commits interleave histories |
| Conflict surface | Small (per-commit) | Large (all-at-once) |
| Rebrand safety | Minimal overlap with renamed files | High risk: upstream touches same files |
| Audit trail | `-x` flag records origin SHA | Merge commit records range |

**When to prefer merge:** If upstream ships a large security refactor across many interrelated files where individual cherry-picks are impractical, merge into a scratch branch (`upstream-merge-scratch`), resolve conflicts there, then squash-merge into `main`.

**Cadence recommendation:** Since Phase 06, `upstream-watch.yml` is `workflow_dispatch`-only
— there is no schedule. Dispatch it whenever you feel like checking; every 1–3 months is
fine. The longer you wait, the larger the conflict surface, but that is an accepted
trade-off (see "On-Demand Upstream Check" above).

---

## Last Synced SHA Log

Record each sync pass here so future cherry-picks know the reviewed baseline.

| Date | Upstream SHA reviewed through | Method | Notes |
|------|------------------------------|--------|-------|
| 2026-06-21 | `f3446b9` (fork commit, not upstream SHA) | `git merge upstream/main` | Pre-existing merge on `feat/linear-graph`; upstream/main HEAD at time of merge. Exact upstream SHA unknown — check `git log --merges --oneline` for details. |

**To find the upstream SHA at the time of f3446b9:**

```bash
git show f3446b9 --format="%P" | tr ' ' '\n' | tail -1
```

This prints the second parent (the upstream HEAD at merge time).

**Template for future log entries:**

```
| YYYY-MM-DD | <upstream-mirror HEAD sha> | cherry-pick | Picked: <sha1>, <sha2>; skipped: <sha3> (already in f3446b9) |
```

---

## Troubleshooting

### "fatal: 'upstream-mirror' is not a commit" on first workflow run

The `upstream-mirror` branch does not exist yet. Re-run the bootstrap in the "Setup (already completed)" section above.

### gh pr create fails: "No commits between main and upstream-sync/..."

The cherry-pick in the workflow auto-seeds the branch to prevent this. If it still occurs (cherry-pick was aborted due to conflict), the workflow falls back to opening an Issue instead. Manually cherry-pick and open a PR from that branch.

### Cherry-pick is empty (already applied via f3446b9)

```bash
git cherry-pick --skip
```

### Force-push to upstream-mirror fails (lease mismatch)

Another process updated `origin/upstream-mirror` concurrently. Re-fetch and re-run:

```bash
git fetch origin upstream-mirror
```

The workflow uses `--force-with-lease` to catch this safely.

### Dependabot PRs appear for github-actions pinned SHAs

This is expected. Review and merge Dependabot PRs for action version bumps (e.g., `actions/checkout@v4` → newer SHA). These are low-risk and recommended.
