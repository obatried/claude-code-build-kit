# Architecture

How `claude-code-build-kit` works as a system, what each piece does, and where the seams are.

## The five pieces

```
┌─────────────────────────────────────────────────────────────────┐
│                     CLAUDE.md (philosophy)                      │
│   §1 Think before coding, §2 Simplicity, §3 Surgical, §4 Goals,│
│   §5 Skills, §6 Source, §7 Build, §8 Vibecop, §9 Persistence,  │
│   §10 Unbiased consults                                         │
└─────────────────────────────────────────────────────────────────┘
                              │ loads into every conversation
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    /build skill (orchestrator)                  │
│   plan → audit → chunk → execute → review → QA → ship           │
└─────────────────────────────────────────────────────────────────┘
                  │             │             │
                  ▼             ▼             ▼
          ┌──────────────┐ ┌──────────┐ ┌──────────────┐
          │   manifest   │ │  Codex   │ │   vibecop    │
          │  state.json  │ │  hooks   │ │   (BYO)      │
          └──────────────┘ └──────────┘ └──────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                  Discipline hooks (always on)                   │
│   stuck-detector, codex-tool-error-reminder, gave-up-early,    │
│   stop-pending-work, stop-slash-text, recommendation-hygiene   │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│              handoff-v3 + .zshrc cooperator                     │
│        cross-session continuation without context loss          │
└─────────────────────────────────────────────────────────────────┘
```

## Piece 1 — Philosophy (`claude/CLAUDE.md`)

A 10-section reference card loaded into every conversation. Most sections follow a fixed shape — bolded thesis, ≤8 bullets, a "The test:" line for self-audit — but a few use a `### Tests` block instead when they cover both mid-task and boundary behavior (§9). Maintenance policy lives in `CLAUDE_MAINTENANCE.md`. Section ↔ enforcement-companion pairings live in `CLAUDE_MAP.md`.

The philosophy biases toward caution over speed. Trivial tasks override.

## Piece 2 — Build orchestrator (`claude/skills/build/SKILL.md`)

A single skill, 311 lines, that runs an end-to-end feature build. Five flows:

| Flow | Trigger | What happens |
|---|---|---|
| **§ 1 New build** | No manifest, user described a feature | Enter plan mode, research codebase, debate tradeoffs with Codex (3-round cap), enumerate user-reachable surfaces, chunk, write `plan/PHASE-N-<slug>.md`, exit plan mode (Codex audit hook fires), present plan + batched questions, init manifest on approval |
| **§ 1a Audit-then-approve** | Manifest exists, `approved=false` | Run Codex audit on the plan, surface verdict + chunk list to user, wait for explicit approve |
| **§ 2 Execute** | Manifest approved, chunks pending | Pick chunk, classify executor (design chunks → fresh `claude -p` subprocess; logic → inline), produce a verification receipt (RED→GREEN test, Playwright smoke, or typecheck + manual verification), commit atomically, post-commit hook auto-runs 3-reviewer Codex review and marks chunk done |
| **§ 3 QA** | All chunks resolved | Invoke `/qa` + `/browse` + `/design-review`, collect findings |
| **§ 5 Ship** | QA pass | Write final summary and stop. If the repo opts into auto-push, run pending DB migrations and push to main first. |

Receipt tier order (the strongest applicable receipt is mandatory):

1. **RED→GREEN test** — for mockable logic. Failing test first (proves it has teeth), then implement, then green.
2. **Playwright smoke** — for API routes and page flows.
3. **Typecheck + lint + documented manual verification** — for migrations, auth glue, visual polish.

No receipt = chunk isn't done.

## Piece 3 — Manifest (`claude/scripts/build-manifest/manifest.sh`)

A 518-line bash script that owns the build's state. Stores a JSON document at `<repo>/plan/.build-state.json` recording which chunks are pending/in-progress/done/failed/skipped, plus the SHA of each completed chunk's commit.

Subcommands:
- `init <plan-file>` — parse plan markdown, extract chunks, create manifest
- `approve` — mark approved, stamp timestamp
- `audit` — run a single Codex pass on the plan, print ALLOW/BLOCK + findings
- `next-chunk` — print JSON of next pending chunk
- `mark-chunk <id> <status> [<sha>]` — update chunk status
- `status` — human-readable summary
- `validate` — schema + consistency check

All writes go through `jq` + a `flock`'d temp-file swap for atomicity. Errors return non-zero so callers can branch.

## Piece 4 — Codex review hooks

Three hooks form the review spine:

| Hook | When | What |
|---|---|---|
| `codex-plan-review.sh` | PostToolUse on `ExitPlanMode` | Runs a Codex audit on the plan markdown. Verdict goes to stdout (Claude reads it) + log file. Informational, never blocks. |
| `codex-commit-review-on-commit.sh` | PostToolUse on `Bash` (matched on `git commit`) | Auto-fires the multi-reviewer commit review. Marks the chunk done in the manifest with the SHA. |
| `codex-tool-error-reminder.sh` | PostToolUse on `*` errors | Injects a system-reminder nudging Claude to consult Codex before retrying. Throttled per session. |

The multi-reviewer orchestrator (`scripts/codex-commit-review.sh`) runs three independent Codex reviews of a commit (different prompts in `codex-commit-review.prompts/`) plus an adjudicator that reconciles them. Output is a final verdict (ALLOW / BLOCK with severity) + structured findings, logged to JSONL.

## Piece 5 — Vibecop adjudication

Vibecop is a per-repo lint-style tool (npm package, BYO). The kit ships:

- `hooks/vibecop-on-edit.sh` — fires on `Edit|Write|MultiEdit`, runs vibecop on the touched file if the repo has it installed, no-ops otherwise.
- `scripts/vibecop-adjudicate.sh` — light adjudicator. Reads vibecop output, asks Codex to tag each finding `[CODEX: REAL]` or `[CODEX: NOISE]`. Short-circuits to REAL when the finding touches security/data/auth/payment keywords (default-deny on high-stakes).
- `scripts/vibecop-adjudicate-heavy.sh` — heavy adjudicator. Spawned in the background by the light one when stakes are high; runs a multi-round analysis Claude can read later.

CLAUDE.md §8 documents the action contract: `REAL → fix`, `NOISE → ignore`, ambiguous → dispatch a Task sub-agent for a third independent POV before deciding.

## Piece 6 — Discipline hooks (always-on guardrails)

Hooks that don't drive the build flow but shape every conversation:

| Hook | Event | Purpose |
|---|---|---|
| `stuck-detector.sh` | PostToolUse on `Edit\|Write\|Bash` | Detects loop patterns (same file 3x, failing Bash 3x in 5min), auto-consults Codex with 10-min throttle |
| `gave-up-early-guard.sh` | Stop | Detects "I can't access X / could you do Y / let me know if you want me to..." escalation phrases at end of turn. Audit-only, logs to JSONL. Enforces CLAUDE.md §9a. |
| `stop-pending-work-guard.sh` | Stop | Detects when a session ends with pending manifest work. Audit-only. Enforces §9b. |
| `stop-slash-text-guard.sh` | Stop | Detects inert `/skill-name` text at end of turn (forgot to call the Skill tool). Audit-only. Enforces §5. |
| `recommendation-hygiene-nudge.sh` | UserPromptSubmit | Detects recommendation-shaped asks (architecture, tool choice, build plan), injects the 4-check pre-ship reminder. Throttled. Enforces §6. |
| `codex-tool-error-reminder.sh` | PostToolUse error | See above. |

All discipline hooks are **audit-only** — they log to `~/.claude/analytics/*.jsonl` but never block. This is intentional: the rules are how the kit nudges, not how it polices.

## Piece 7 — Handoff (`claude/handoff-v3.sh` + zshrc cooperator)

Cross-session continuation without context loss. Mechanism:

1. Current session writes a prompt file to `~/.claude/state/handoff/next-handoff.txt` and a working-dir to `~/.claude/state/handoff/next-handoff-dir.txt`. The state dir is mode 700; files are mode 600.
2. `handoff-v3.sh` opens a fresh Terminal.app tab via AppleScript, explicitly unsetting `CLAUDE_CODE*` env vars (otherwise the new tab inherits them and the auto-launch block in `.zshrc` is skipped).
3. The fresh shell sources `.zshrc`, which detects the handoff files (within a 120s freshness window) and `exec claude --permission-mode auto "$_prompt"`.
4. The new session reads the prompt and continues the build.

This is macOS-only because of AppleScript. Linux/Windows users get the script for reference but start new sessions manually.

## How the pieces talk

```
User says "let's build X"
        │
        ▼
/build skill (Step 0: locate manifest, decide flow)
        │
        ├─→ no manifest → § 1 New build flow
        │     → research → Codex tradeoff debate (3-round cap)
        │     → enumerate surfaces → chunk → write plan/PHASE-N.md
        │     → ExitPlanMode → codex-plan-review hook fires
        │     → present + batched questions → user approves
        │     → manifest.sh init + approve
        │
        ├─→ manifest pending → § 2 Execute (loop)
        │     → manifest.sh next-chunk
        │     → mark-chunk in-progress
        │     → implement (inline OR fresh `claude -p` subprocess for design)
        │     → produce receipt
        │     → git commit (vibecop-on-edit fires per Edit; codex-commit-review-on-commit fires post-commit)
        │     → read review verdict, fix or continue
        │
        ├─→ all chunks done → § 3 QA flow
        │     → /qa, /browse, /design-review
        │
        └─→ § 5 Ship
              → summary (then user pushes manually,
                or → migrations → push if repo opted in)
```

Throughout: discipline hooks fire on every turn. Stuck-detector watches Edit/Write/Bash. Gave-up-early-guard watches Stop. Recommendation-hygiene-nudge watches UserPromptSubmit. They're invisible until they fire.

## Where the seams are

If you customize the kit, these are the seams:

1. **Codex model + reasoning** — set in `~/.codex/config.toml`. Every script reads from there. Defaults to `gpt-5.5` + `medium`.
2. **Analytics directory** — hooks log to `~/.claude/analytics/*.jsonl`. Override by exporting `BUILDKIT_LOG_DIR` (planned; not yet wired everywhere — see TODO).
3. **Auto-push opt-in** — § 5 of `SKILL.md` reads the repo's `CLAUDE.md` / `AGENTS.md` for an explicit auto-push declaration. Default is stop-after-summary; declare auto-push in the repo to opt in.
4. **Receipt tiers** — § 2 step 2b. Customize the priority order if your stack uses different verification tools.
5. **Hook throttles** — most hooks have a 10-minute per-session throttle. Adjust the `THROTTLE_FILE` cooldown in the hook script.

## Known limitations

- **macOS-first**. Handoff is AppleScript. Build skill assumes BSD coreutils in places.
- **Bash 3.2 quirks**. macOS ships bash 3.2; some heredoc-inside-`$()` patterns don't parse. Scripts use `read -d ''` instead.
- **gstack coupling at the edges**. `/build` § 2 (design executor) and § 3 (QA) name gstack skills explicitly. Without gstack those steps degrade — work in progress to make them pluggable.
- **Vibecop is a separate npm package** with its own install story. Not bundled.
- **The handoff window is 120s**. If a Terminal tab takes longer than that to source `.zshrc`, the handoff is dropped.
