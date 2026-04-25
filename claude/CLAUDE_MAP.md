# CLAUDE.md ↔ Companion Map

Maps CLAUDE.md sections to the hooks, skills, or scripts that enforce them.
The kit doesn't ship an automated drift checker — the map is a manual
sync reference governed by `~/.claude/CLAUDE_MAINTENANCE.md` §7.

Added: 2026-04-23 | Last reviewed: 2026-04-23

## Format

Pair lines look like:

    §N Section Name | /absolute/path/to/companion | role

One section may have multiple companion lines. Only lines starting with `§` are pair entries — everything else is commentary.

---

## Pairs

§5 Skill Invocation | ~/.claude/hooks/stop-slash-text-guard.sh | Stop hook, audit-only, logs inert `/skill` text violations
§7 Build Orchestration | ~/.claude/scripts/build-manifest | manifest tooling for /build
§8 Vibecop Handling | ~/.claude/hooks/vibecop-on-edit.sh | PostToolUse hook, runs vibecop per edit
§9 Persistence (9a mid-task) | ~/.claude/hooks/gave-up-early-guard.sh | Stop hook, audit-only, detects escalation phrases
§9 Persistence (9a mid-task) | ~/.claude/scripts/gave-up-early-review.sh | periodic review of logged violations
§9 Persistence (9b boundary) | ~/.claude/hooks/stop-pending-work-guard.sh | Stop hook, audit-only, logs stops with pending manifest work

## Sections with no companion

For reference only; these don't have an enforcement hook.

- §1 Think Before Coding — none
- §2 Simplicity First — `/simplify` skill exists but is invoked, not enforced
- §3 Surgical Changes — none
- §4 Goal-Driven Execution — none
- §6 Read Source, Not Just Summaries — none
- §10 Unbiased Consult Prompts — none (no enforcement hook yet; relies on self-audit per the test line)

## Out of scope (for now)

Hooks not tied to a CLAUDE.md section but installed by this kit:

- `~/.claude/hooks/codex-tool-error-reminder.sh` — Codex consult reminder on tool error
- `~/.claude/hooks/recommendation-hygiene-nudge.sh` — pre-design self-audit nudge
- `~/.claude/hooks/stuck-detector.sh` — auto-Codex when looping
- `~/.claude/hooks/codex-plan-review.sh` — fires Codex audit on ExitPlanMode
- `~/.claude/hooks/codex-commit-review-on-commit.sh` — fires multi-reviewer audit post-commit

Extend this map if you decide to add enforcement for any of these.
