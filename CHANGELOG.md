# Changelog

## v0.2.1 — 2026-10-07

Trims the kit to what `/build` actually uses.

### Removed
- **Six always-on "discipline" hooks**, which the maintainer retired from their own setup: `stuck-detector.sh`, `stop-slash-text-guard.sh`, `stop-pending-work-guard.sh`, `recommendation-hygiene-nudge.sh`, `gave-up-early-guard.sh` and `codex-tool-error-reminder.sh`.
- **`scripts/gave-up-early-review.sh`**, a one-shot report over `gave-up-early-guard.sh`'s log, built around a dated launchd schedule.
- The `UserPromptSubmit` and `Stop` hook registrations in `settings.template.json`. Only `PostToolUse` remains.

### Kept
- `codex-plan-review.sh`, `codex-commit-review-on-commit.sh` and `vibecop-on-edit.sh`. `/build` depends on all three.
- The CLAUDE.md rules those hooks audited (§5 slash-text, §9 persistence). They are now self-checks; CLAUDE.md and CLAUDE_MAP.md no longer claim a hook enforces them.

### Tests
- `tests/install-upgrade.test.sh` covers:
  - the upgrade cleanup (kit-shaped entries removed, other entries kept and listed)
  - a symlinked `settings.json` and idempotent re-runs
  - malformed settings (`[]`, `false`, `null` entries, scalars) rejected before anything is touched, while a valid `prompt`-type hook is accepted
  - the user's own hooks surviving
  - a `HOME` containing a space, where the printed `rm` lines are actually run
  - the uninstall list matching what `install.sh` installs

### Docs
- README, ARCHITECTURE, INSTALL and the walkthrough now describe 3 hooks.
- The stuck-detector "forces high reasoning" exception is gone; every script in the kit now uses `~/.codex/config.toml` as-is.

### Upgrading from v0.2.0 or earlier
- **Re-run `./install.sh`.** In order, it: checks the shape of `settings.json`, backs up `~/.claude/`, removes the retired registrations, copies the new files, lists leftover retired files, then merges hooks.
  - **Shape check, first, before the backup:** the installer checks the shape of `settings.json`. It requires an object; `hooks` absent or an object; each event an array of `{matcher?, hooks: [...]}` groups; and each hook an object with a string `command`, or a non-`command` `type` such as `prompt`. On anything else (`"hooks": []`, `"hooks": false`, `null` entries, invalid JSON) it stops with a clear error. Nothing is changed, backed up or installed, and no temp file is left behind.
- **Registration cleanup.** It removes the six retired hooks' registrations from `~/.claude/settings.json`, but only the exact (event, matcher, command) entries every earlier kit template wrote:
  - `PostToolUse` / `Edit|Write|Bash` / `$HOME/.claude/hooks/stuck-detector.sh`
  - `PostToolUse` / `*` / `…/codex-tool-error-reminder.sh`
  - `UserPromptSubmit` (no matcher) / `…/recommendation-hygiene-nudge.sh`
  - `Stop` (no matcher) / `…/stop-slash-text-guard.sh`, `…/gave-up-early-guard.sh`, `…/stop-pending-work-guard.sh`

  It drops a matcher group only if that removal emptied it. Any other entry that mentions a retired hook stays and is listed in a notice.
  - A symlinked `settings.json` stays a symlink; the change is written to its target, and the backup gets a dereferenced copy, `settings.json.resolved`.
  - Leftover files are reported as one shell-quoted `rm` line each, so paths containing spaces are safe to paste.

  It does **not** delete the old files. They are inert once unregistered. For each one still on disk it prints a line like:

  ```bash
  rm /Users/you/.claude/hooks/stuck-detector.sh
  ```
- **Entries the installer leaves alone** are the ones under a different event or matcher, or with an edited command (different path, wrapper script). It lists them on every run. Find them yourself with:

  ```bash
  jq -r '.. | .command? // empty' ~/.claude/settings.json \
    | grep -E 'stuck-detector|stop-slash-text-guard|stop-pending-work-guard|recommendation-hygiene-nudge|gave-up-early-guard|codex-tool-error-reminder'
  ```

  Then delete those entries by hand.
- **`uninstall.sh` restores the most recent `~/.claude.bak.*`.** After an upgrade, that backup is your v0.2.0 install, retired hooks included. To get back to your pre-kit setup, restore the oldest backup from before your first install instead. With no backup, the uninstaller prints a manual-removal list of every file `install.sh` installs, plus the retired files as legacy entries. `tests/install-upgrade.test.sh` checks that list against a real install.

## v0.2.0 — 2026-10-07

Brings `/build` and its scripts up to date with the maintainer's current version.

### `/build` skill

- **Risk scorecard, always on.** Every build is scored on five dimensions (novelty, blast radius, irreversibility, verification difficulty, rollback cost) before planning. The score routes to a **fast / standard / full** tier. There is no flag to skip it, and borderline scores round up.
- **Tiered plan sections.** Standard and full tiers require a `## Decision Table` and `## Depth Calibration` (how deep the build goes on each surface: none / goals / interface / implementation-ready). On those tiers, high findings from the plan-review hook must be triaged before continuing.
- **Prep-work loop (full tier).** Refactor candidates that pass three gates (independently valuable, measurably shrinks the PR, safe to ship alone) ship first as separate `PREP-N` work.
- **Freeze point.** When migrations, public API, infra, or auth are touched, the plan stamps a `## Freeze point`. After that, new prep ideas become follow-ups, not scope.
- **Adversarial layer (standard/full tier).**
  - Overlay A: a JSON "definition of done" checklist per chunk, written before code, augmented by Codex, then locked (`plan/contracts/chunk-<ID>.json`).
  - Overlay B: the checklist is actually run against each committed chunk. Only run-based evidence fails a chunk. Capped at 3 fix rounds.
  - Overlay C: one whole-system integration pass at QA (1 pass + 1 fix).
- **Vertical RED→GREEN.** One test, then the code that passes it, then repeat. No batching tests up front.
- **Mobile QA fleet.** For Expo/React Native/iOS apps, QA runs once per release as a fleet: a Codex code audit, a sub-agent that drives the simulator, a visual auditor, and a new-user flow-walker. Per change, only the cheap gates run.
- **Manifest parser constraints documented.** The skill now names the exact chunk-line format `manifest.sh init` accepts, so `init` stops failing silently.
- **Telemetry.** Per-chunk and per-bundle adversarial results are logged to `~/.claude/analytics/build-runs.jsonl`.
- **Waits for the commit review.** The post-commit hook still marks a chunk done at commit time. The skill now waits for that commit's review to log a finished line in `codex-commit-reviews.jsonl` before acting on it.
- **Review gate over the whole build (`manifest.sh review-gate`).** `approve` records `base_sha`. Before QA, the gate walks `base_sha..HEAD`, so it covers fix commits the manifest never records, even after a resume. It fails closed throughout:
  - Every commit needs a finished review, matched on its full SHA.
  - A BLOCK passes only when a *descendant* commit carries a real `Review-fix: <sha>` git trailer resolving to it.
  - `skipped` passes but is listed, except for merge commits.
  - `failed`, `degraded` or missing fails.
  - Manifests approved without `base_sha` fail until `manifest.sh set-base <sha>` is run.
- **Safer opt-in push.** Before pushing, `review-gate --push` re-runs the review gate and also checks that the current branch is `main`, that every chunk commit is on it, that `base ⊆ origin/main ⊆ HEAD` after fetching `origin main` (no pre-build commits left unpushed, and the remote isn't ahead). A failed fetch or a missing `origin/main` fails the check unless `--initial-push` is passed. If any check fails, the skill stops and reports instead of pushing.
- **Design-chunk subprocess fixed.** The prompt heredoc was quoted, so `$ID`/`$NAME`/`$FILES` never expanded, and `$PLAN_FILE` was never set. It now reads the plan path from the manifest.
- **Unchanged:** pushing is still opt-in. `/build` stops after the QA summary unless the repo's `CLAUDE.md`/`AGENTS.md` declares auto-push.

### Scripts and hooks

- **Shared Codex prompt header.** New `claude/scripts/codex-prompt-header.txt` is now the one place for the filesystem-boundary text. It is prepended by `manifest.sh audit`, `codex-plan-review.sh`, and every commit reviewer plus the adjudicator, so the text is no longer duplicated. Override it with `CODEX_PROMPT_HEADER`. `install.sh` installs it.
- **Codex calls run bare.** Scripts no longer pass `-c model_reasoning_effort=...`, so every call uses `~/.codex/config.toml`. Plan review, the manifest audit, commit reviews, and heavy vibecop adjudication previously forced `high`. They now use your config default (`medium` in the shipped template).
- **Commit-review severity rubric.** All three reviewer prompts use the same action-tier scale: critical = halt deploys, high = fix this sprint, medium = normal flow, low = cognitive trigger. Each prompt has its own domain examples. When reviewers disagree, the adjudicator defaults to the highest severity and must give a reason to downgrade.
- **Prompt-injection boundary.** Plan text (plan-review hook, `manifest.sh audit`) and vibecop paths, findings and earlier-round answers (light and heavy adjudicators) are now wrapped in random-suffix `<UNTRUSTED_…>` delimiters, the way the commit reviewer already wrapped diffs. Forged markers are scrubbed first. With no secure random source, the script skips the review rather than use a guessable delimiter.
- **Shell-injection fix.** The detached launches in `codex-commit-review-on-commit.sh` and `vibecop-adjudicate.sh` pass paths as arguments instead of splicing them into a `bash -c` string. A repo or file path containing a quote can no longer run commands.
- **Commit reviewer logs full SHAs and reviews merges properly.** Every log line now carries `sha_full`; `sha` remains the 7-character display prefix. Merge commits are diffed against their first parent, because a bare `git show` is empty for most merges, and are never skipped as trivial.
- **Fixture tests:** `tests/review-gate.test.sh` covers trailer placement, full-SHA matching, merges, remote checks, legacy manifests, a missing log, an empty range and a happy path.
- **`codex-commit-review.sh`** gains `--prompts-dir` and `CODEX_REVIEW_PROMPTS_DIR` for swapping the reviewer prompt set.

### Docs

- README, ARCHITECTURE, INSTALL, and the walkthrough now describe the tiers and overlays. The sample plan is now a standard-tier plan with a scorecard, a decision table, depth calibration, and locked checklists.
- `install.sh` now detects gstack by its skill directory; gstack installs no `gstack` command.
- README now says the handoff snippet launches handoff sessions with `--permission-mode auto`. INSTALL's manual `chmod` step no longer depends on `**` globbing. The `BUILDKIT_LOG_DIR` mention was removed: it was never implemented.
- Fixed the gstack link (`github.com/garrytan/gstack`). The design skills (`/emil-design-eng`, `/make-interfaces-feel-better`) are no longer described as part of gstack.

## v0.1.0 — 2026-04-25

Initial release.
