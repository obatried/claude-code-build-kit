---
name: build
version: 1.0.0
description: |
  Full-stack build orchestrator. Invoke when starting a new feature build or resuming
  one in progress. Reads `<repo>/plan/.build-state.json` to determine current state,
  runs forward autonomously through plan → chunks → commits → reviews → QA, then
  writes a summary and stops. Pushing is opt-in: enable it in the repo's CLAUDE.md
  or AGENTS.md if you want auto-push on QA pass. Use when user says "let's build X",
  "start a new feature", "resume the build", or "/build".
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - MultiEdit
  - Glob
  - Grep
  - Task
  - AskUserQuestion
---

# /build — the feature-build orchestrator

You are running an end-to-end build of a feature. Your job is to move forward
from whatever state exists in `<repo>/plan/.build-state.json`, batching
questions for the user and interrupting only when a decision genuinely needs
human input. When all chunks are done and QA passes, write the summary and
stop. **Pushing is opt-in** — only push to main if the repo's `CLAUDE.md` or
`AGENTS.md` explicitly opts in (see § 5). When in doubt, stop and let the user
push manually.

## Step 0: locate state

Walk up from `$PWD` looking for `plan/.build-state.json`. Run:

```bash
~/.claude/scripts/build-manifest/manifest.sh status 2>&1
```

Decide which flow to enter based on what you see:

| State | Flow |
| --- | --- |
| no manifest + user described a feature | **New build** (§ 1) |
| no manifest + nothing described | Ask (one question) what to build, then § 1 |
| manifest exists + approved=false | **Audit-then-approve** (§ 1a) |
| manifest exists + approved=true + chunks pending/in-progress | **Execute** (§ 2) |
| manifest exists + all chunks resolved | **QA** (§ 3) |

Never skip the manifest. It is the source of truth for state.

## § 1 — New build flow

You are designing a phased plan for a non-trivial feature. Work autonomously.
Only interrupt the user for genuine tradeoff decisions after Codex debate, or
items tagged `Needs user input:`.

1. **Enter plan mode** (Claude Code native). Stay in plan mode until § 1.7.
2. **Research the codebase yourself.** Read the files that touch this feature —
   don't ask the user which files matter. Form a POV on where the change lives
   and which systems it crosses.
3. **Identify tradeoff decisions.** For each, form your own POV, then ask Codex:

   ```bash
   codex exec --skip-git-repo-check <<'PROMPT'
   <your POV + the specific tradeoff question>
   PROMPT
   ```

   - If Codex agrees: record the decision, move on.
   - If Codex disagrees: up to **3 rounds** of debate, each round passing the
     previous transcript. After round 3, if still unresolved OR if fresh
     research is needed, dispatch a web-research sub-agent via the Task tool
     (general-purpose). Instruct it to hit **HN Algolia → Reddit JSON API →
     actual GitHub source code**. Generic Google results and blog summaries
     are unreliable for technical decisions — they reflect a narrow set of
     articles, not the actual universe of practitioner experience.
   - **Oscillation rule:** if round N flags the reverse of round N-1, STOP and
     surface to user with both positions.
4. **Enumerate user-reachable surfaces.** Before chunking, list every UI input,
   UI output, downstream consumer, doc, legal/privacy page, email template, and
   settings toggle the capability needs to be fully integrated end-to-end. If you
   can't name them, you don't have a plan — expand or scope down. Surfaces
   deferred go in `## Out of scope` with a reason. This is the "build the walls"
   rule — every plan that adds capability enumerates every user-reachable
   surface it needs. Scaffolding without walls is debt, not progress.
5. **Break the work into chunks.** Each chunk:
   - is named in 2-8 words
   - lists the files it touches (`files: a.ts, b.tsx, …`)
   - has a clear success check (test to write, endpoint to hit, etc.)
   - is ~1-4 hours of granularity (not too small, not too large)
6. **Write the plan** to `<repo>/plan/PHASE-N-<slug>.md`. Required sections:
   - `## Goal`
   - `## Approach` (the POV + any decisions you made)
   - `## User-reachable surfaces` — table of every user touchpoint from step 4
   - `## Chunks` — **numbered list**, format: `N. **Name** — files: path1, path2`
   - `## Open questions` — batched for the user, plain English
   - `## Out of scope` — what you are NOT doing (with reason for each)
6. **ExitPlanMode**. The existing `codex-plan-review.sh` hook will fire. Read
   its verdict. If BLOCK with a critical/high finding: fix the plan, re-exit.
7. **Present to user.** Single message: plan summary + the batched questions
   from `## Open questions`. Wait for answers.
8. **Initialize the manifest on approval:**
   ```bash
   ~/.claude/scripts/build-manifest/manifest.sh init plan/PHASE-N-<slug>.md
   ~/.claude/scripts/build-manifest/manifest.sh approve
   ```
   (You can skip a redundant `manifest.sh audit` here — the ExitPlanMode hook
   already ran the same Codex pass in step 6.)

## § 1a — Audit-then-approve (manifest exists, approved=false)

User already drafted a plan and initialized the manifest. Before executing any
code, run the plan through Codex and let the user review the verdict:

```bash
~/.claude/scripts/build-manifest/manifest.sh audit
```

This prints `ALLOW: <reason>` or `BLOCK: <reason>` plus findings, and logs to
`~/.claude/analytics/codex-plan-reviews.jsonl`. Takes ~60s.

Surface the full audit output to the user in a single message along with:
- the chunk list from `manifest.sh status`
- any batched questions about scope/unknowns you have from reading the plan

Then wait for the user to **explicitly approve** before touching code. Do NOT
auto-approve on ALLOW — the user decides. Possible user responses:

- **Approve** → run `manifest.sh approve` → go to § 2.
- **Revise** → help them edit the plan file, then: delete the manifest
  (`rm <repo>/plan/.build-state.json`) and re-run `init` + re-audit.
- **Abort** → leave the manifest approved=false, stop.

If the audit command fails (codex down, timeout), still surface the chunk list
and any scope questions to the user and ask whether to proceed without audit.
Never block on audit failure.

## § 2 — Execute flow

Loop until `next-chunk` returns nothing.

```bash
CHUNK=$(~/.claude/scripts/build-manifest/manifest.sh next-chunk) || { echo "all chunks done"; break; }
ID=$(echo "$CHUNK" | jq -r .id)
NAME=$(echo "$CHUNK" | jq -r .name)
FILES=$(echo "$CHUNK" | jq -r '.files | join(" ")')
```

For each chunk:

1. **Mark in-progress:**
   `~/.claude/scripts/build-manifest/manifest.sh mark-chunk $ID in-progress`
2. **Implement + produce a receipt.**

   **2a. Pick the executor.** Classify by chunk name + files:
   - **Design/UI chunk** (CSS, Tailwind, component styling, layout, marketing
     copy polish, visual detail work, spacing/typography tweaks): delegate
     implementation to a fresh `claude -p` subprocess so it has full CLI tools,
     the full design-skill stack (`/emil-design-eng`,
     `/make-interfaces-feel-better`, `/design-review`), and can run a dev
     server if needed. A full subprocess beats a Task-tool subagent for
     visual work because subagents don't auto-load design skills and can't
     realistically iterate with screenshots.

     ```bash
     claude -p "$(cat <<'PROMPT'
     You are implementing chunk $ID: $NAME from plan/$PLAN_FILE.
     Files in scope: $FILES.
     Use /emil-design-eng and /make-interfaces-feel-better where relevant.
     Edit and save only — do NOT commit. The main /build session commits.
     PROMPT
     )" --allowedTools "Bash,Read,Edit,Write,Glob,Grep,WebFetch,WebSearch" \
       --max-turns 60 > /tmp/build-chunk-${ID}.log 2>&1
     ```

     Wait for completion, read the log, verify files were modified as expected.
   - **Logic/backend chunk** (business logic, server actions, API routes,
     migrations, scripts, config, auth glue): implement inline in this
     session. No subprocess.

   Vibecop fires on edits automatically (see § 4). Keep edits scoped to this
   chunk's files — if you need to touch something else, stop and ask.

   **2b. Every chunk ships with exactly one verification receipt.** Priority
   order — use the strongest option that applies to this chunk:

   1. **RED→GREEN test** for mockable logic (pure functions, transforms,
      validators, query builders, server actions with testable contracts, bug
      fixes with a reproducible failure): write the failing test first, run
      it, **confirm it fails** (RED — proves the test has teeth), implement,
      re-run, **confirm it passes** (GREEN).
   2. **Playwright smoke** for API routes and page flows: hit the
      endpoint/load the page, assert expected response or element. Confirm
      pass.
   3. **Typecheck/lint + documented manual verification** for migrations,
      auth/provider glue, visual polish, config: run typecheck + lint, capture
      the output, and document the manual step (screenshot path, click
      sequence, or curl command + expected response).

   No receipt = the chunk isn't done. Receipt reference goes in the commit
   body (step 3) so the Codex reviewer sees it.
3. **Commit atomically** with a descriptive message. The post-commit hook
   (`codex-commit-review-on-commit.sh`) auto-fires the 3-reviewer Codex review
   AND marks the chunk `done` with the commit SHA in the manifest. You do NOT
   need to manually mark the chunk done — the hook does it.
4. **Read the Codex commit review** once it surfaces. Location:
   `~/.claude/analytics/codex-commit-reviews.jsonl` (latest line for this SHA)
   and `~/.claude/state/codex-commit-review/<sha>-*/`.
   - If verdict=BLOCK with critical/high severity: fix, make a new commit (NOT
     amend — amending loses the paper trail). The new commit triggers another
     review.
   - If verdict=ALLOW or only medium/low: continue to next chunk.
   - **3-round cap:** if you've made 3 fix-rounds on the same chunk, stop and
     surface to user. Further rounds are bikeshed territory.
5. Repeat until `next-chunk` returns empty.

If a chunk genuinely cannot be completed: `mark-chunk $ID failed` and surface
to user with the specific blocker.

## § 3 — QA flow

All chunks resolved. Invoke the gstack QA skills inline — don't dispatch
sub-agents; QA produces artifacts you need to read.

1. `/qa` — systematic end-to-end test of the feature
2. `/browse` — spot-check the feature manually if it has UI surface area
3. `/design-review` — only if any UI pixels changed

**If gstack is not installed:** these skills won't be available. Degrade
gracefully — note the absence in the summary and run a minimal manual smoke
test instead (read the modified files, run the project's test suite if one
exists, hit any new endpoints with `curl`). Document what you tested in the
summary so the user knows what coverage is missing.

Collect:
- QA health score
- Any open P1/P2 findings from commit reviews (grep `~/.claude/analytics/codex-commit-reviews.jsonl` for this build's SHAs)
- Preview URL if available
- Any outstanding vibecop findings tagged `[CODEX: REAL]`

## § 4 — Vibecop finding handling (during Execute)

Vibecop fires on Edit/Write/MultiEdit. Its output may contain adjudication tags:

- `[CODEX: REAL — recommend fix]` → fix in the next edit before continuing the
  current chunk. Do not defer.
- `[CODEX: NOISE — ignore]` → skip. Log that you saw it.
- No tag (adjudication failed or not triggered) → use judgment; default to fix.

If a finding is architectural/security/data-integrity and the adjudication
surfaces both a REAL and a counter-POV, dispatch a Task sub-agent
(general-purpose) for a third independent POV before deciding.

## § 5 — Ship condition

When § 3 finishes, write the final summary and stop. **Do not push by default.**
Pushing to main is opt-in: only push if the repo's `CLAUDE.md` or `AGENTS.md`
explicitly declares the auto-push contract (e.g. a line like
`/build auto-pushes to main on QA pass`).

1. **Read the repo's `CLAUDE.md` / `AGENTS.md`** to determine the ship policy.
   Default = stop after summary; user pushes manually.
2. **If auto-push is opted-in:** run pending DB migrations before pushing,
   then `git push origin main`. Migrations must precede code deploy so the new
   code doesn't reference missing columns/tables. Use the migrate script the
   repo declares (`db:migrate`, `migrate`, `db:deploy`, `prisma migrate deploy`,
   etc.); don't invent one.
3. **Write the final summary** to the user with:
   - Commits shipped this build (from manifest `chunks[].sha`)
   - Chunks completed / skipped / failed counts
   - Open P1/P2 findings across all commit reviews (from
     `~/.claude/analytics/codex-commit-reviews.jsonl` filtered to this
     build's SHAs)
   - Migration name(s) applied, if auto-push ran
   - Push confirmation (origin hash range), if auto-push ran
   - Preview/production URL if the repo declares one
   - QA output if § 3 ran it
   - **If auto-push was NOT opted in:** an explicit "Review and push when
     ready: `git push origin main`" line at the end of the summary.

Then STOP. Do not invoke `/ship` — that's a different (PR-based) workflow.

## Guardrails

- **Batch questions.** The user does not want to answer 20 questions one at a
  time. Ask once, at the plan-approval gate and at any unresolved tradeoff.
- **Every Codex call** runs bare — no `-m` or `-c model_reasoning_effort=` flags.
  `~/.codex/config.toml` pins `gpt-5.5` + `medium` as the defaults; let it drive.
  Only override if the user explicitly asks for "full tilt" / "deep review" / "xhigh".
- **Web research sub-agents** go through Task (general-purpose), NOT through
  Codex directly. Codex can't hit the open web from here reliably.
- **3-round cap on any loop** — debate, fix-rounds, adjudication. Oscillation
  is fatal; when round N inverts round N-1, STOP that loop.
- **When a loop hits the cap, adjudicate before surfacing.** Dispatch a Task
  general-purpose sub-agent with both POVs (mine + Codex's transcript + the
  plan + relevant source). Its job: form an independent third POV and either
  adjudicate (pick one, document why) or declare "genuine irreconcilable
  disagreement." Only surface to the user AFTER the adjudicator can't settle
  it. Surfacing is last resort, not second. Exception: destructive ops beyond
  the ship envelope — those surface immediately regardless of adjudication
  state.
- **Never amend commits during execute** — each review needs its own commit for
  the paper trail.
- **Never touch files outside the current chunk's scope** without asking. If
  you discover dead code, unrelated bugs, or refactor opportunities: note them
  in a `## Out of scope` section of the plan and move on.
- **Never invoke `/ship`.** That's a PR-based workflow; `/build` is its own
  end-to-end thing. Double-shipping is wrong.
- **Pushing is opt-in, not default.** § 5 stops after writing the summary
  unless the repo's `CLAUDE.md` or `AGENTS.md` explicitly opts into auto-push.
  Read the repo's root-level agent docs in § 1 / § 1a to know which path
  applies. When in doubt, stop and let the user push.
