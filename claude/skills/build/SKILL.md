---
name: build
version: 3.0.0
description: |
  Full-stack feature build orchestrator with adaptive rigor. Runs end-to-end:
  plan → chunks → commits → reviews → QA → summary (migrations + push only if the
  repo opts in). A forced preflight (risk scorecard, decision table, depth
  calibration, and a prep-work loop with the three-gate test when risk is high)
  auto-scales strictness to the work — the scorecard routes to fast / standard /
  full tiers, no opt-in flag. On standard/full tier it adds a bounded adversarial
  layer: a "definition of done" checklist is locked BEFORE code (Claude writes
  it, Codex adds the edge/error cases), then RUN against each chunk, plus one
  whole-system integration pass at QA. Pushing is opt-in: enable it in the
  repo's CLAUDE.md or AGENTS.md if you want auto-push on QA pass. Invoke when
  starting a new feature build or resuming one: "let's build X", "start a new
  feature", "resume the build", or "/build".
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

# /build — feature-build orchestrator with adaptive upstream rigor

You are running an end-to-end build. When all chunks are done and QA passes,
write the summary and stop. **Pushing is opt-in** — only push to main if the
repo's `CLAUDE.md` or `AGENTS.md` explicitly opts in (see § 5). When in doubt,
stop and let the user push manually.

Before any chunking starts, you produce a **reviewed plan artifact** with a
risk scorecard, decision table, depth calibration, and (when warranted) a
prep-work split. The strictness of these upstream gates scales with the risk
score, not with whether the work is a "feature" or a "fix."

The diagnosis this skill is built around: optional upstream skills get skipped.
So upstream rigor is not optional here — it is the default path of /build,
with the dial set by risk.

## Roles & the adversarial layer (who does what)

- **Claude builds and verifies.** Claude plans, writes the acceptance checklist,
  implements chunks inline (design chunks via a `claude -p` subprocess, see § 2),
  and RUNS the checklist against each built chunk.
- **Codex is the independent reviewer.** Codex (a) reviews and *augments* the
  acceptance checklist before any code — adding the edge/error cases Claude
  missed — and (b) reviews every commit via the post-commit
  `codex-commit-review` hook. A different model grades the work; Claude does not
  silently grade only itself.

This adversarial layer — the locked checklist (Overlay A), running it (Overlay
B), and the whole-system integration pass (Overlay C) — engages **only on
standard and full tier**. On **fast tier** (all five risk dimensions Low),
/build skips it entirely. The core idea (separate "define done" from "build it,"
lock the definition before code, then *run* it rather than re-read it) is from
coleam00/adversarial-dev + Anthropic's harness-design article. It pays for its
cost only on risky paths (auth, payments, migrations), which is why it's gated.

**Bounding principle — it cannot loop forever.** An adversary can always find
*something*. Every adversarial loop has a hard stop: per-chunk eval is capped at
**3 fix-rounds** (same as commit review); the integration pass is **1 pass + at
most 1 consolidated fix**, then remaining issues become follow-ups; and if the
same criterion fails the same way twice, stop early and surface — repetition
means the fix isn't converging. If you feel the adversary "keeps finding more,"
you've hit a cap — stop and surface.

**Only run-based evidence fails a build.** The gate is execution, not opinion.
A criterion fails only when you RAN it and it broke (or a hard static proof like
the type checker erroring). An inspection-only concern ("this looks fragile") is
logged as an advisory follow-up, never a gate failure. (Claude and Codex are
peer models, so "I think this looks wrong" adds cost with little gain; a failing
test or a 500 response is ground truth regardless of which model is smarter.)

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

The Risk Scorecard (§ 0.5) runs first on every invocation and auto-routes to
one of three tiers: **fast** / **standard** / **full**. There is no opt-in
flag. If the work is genuinely simple, the scorecard routes you to fast
automatically. If anything is complicated, you cannot accidentally skip the
upstream rigor — or, on standard/full, the adversarial layer.

## § 0.5 — Risk Scorecard (always runs first)

Before drafting the plan, score the work on five dimensions. Low / Medium / High
each. The score auto-routes to a tier — no flag required.

| Dimension | Low | Medium | High |
| --- | --- | --- | --- |
| **Novelty** | extending a visible pattern | new behavior, known primitives | net-new system, unknown unknowns |
| **Blast radius** | one screen / one user | one feature / segment of users | core flow / all users / public API |
| **Irreversibility** | reversible commit | reversible with effort (config, flag) | data migration / deletion / public API change |
| **Verification difficulty** | unit-testable | integration-testable | hard to observe, prod-only signal |
| **Rollback cost** | revert + redeploy | revert + restore data | cannot fully roll back |

Auto-routing rule (no opt-in, no flag):
- **All 5 dimensions = Low** → **fast tier**: compressed plan, skip § 1.5, skip § 1.6, no Decision Table required, no Depth Calibration required. **No adversarial layer** (no acceptance checklist, no run-eval, no integration pass) — fast tier is plain /build.
- **Any dimension ≥ Medium, no High** → **standard tier**: full plan with Decision Table + Depth Calibration required. § 1.5 optional. § 1.6 only if migrations / public API / infra / auth touched. **Adversarial layer ON** (Overlays A/B/C).
- **Any dimension = High** → **full tier**: everything mandatory — Decision Table, Depth Calibration, § 1.5 prep-work loop, § 1.6 freeze point (when applicable). **Adversarial layer ON** (Overlays A/B/C).

Bias the scoring toward caution. If a dimension is borderline Low/Medium, score
Medium. The cost of one extra upstream pass is small; the cost of skipping
upstream on a Medium-risk change is missed decisions.

Write the scorecard at the top of the plan file as `## Risk Scorecard` with
each dimension scored, one-line justification, and the routed tier.

## § 1 — New build flow

You are designing a phased plan for a non-trivial change. Work autonomously.
Only interrupt the user for genuine tradeoff decisions after Codex debate, or
items tagged `Needs user input:`.

1. **Enter plan mode** (Claude Code native). Stay in plan mode until step 11
   (ExitPlanMode).
2. **Research the codebase yourself.** Read the files that touch this change —
   don't ask the user which files matter. Form a POV on where the change lives
   and which systems it crosses. Also read the repo's root `CLAUDE.md` /
   `AGENTS.md` now so you know the ship policy (§ 5) before you plan.
3. **Identify tradeoff decisions and produce the Decision Table.** For each
   tradeoff, form your own POV, then ask Codex:

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
     actual GitHub source code**. Do not rely on Google/bloggy summaries.
   - **Oscillation rule:** if round N flags the reverse of round N-1, STOP and
     surface to user with both positions.

   Record every resolved tradeoff in the plan as a `## Decision Table` row:

   | Decision | Choice | Why |
   | --- | --- | --- |

   This section is required even when there is only one decision. The point is
   to make non-obvious choices visible before chunking.

   **On standard/full tier, this same Codex consult also augments the
   acceptance checklist (Overlay A step 3)** — fold it in here, one round, no
   extra hop: ask Codex to review the per-chunk checklists for missing edge/error
   cases and unfair/underivable criteria.

4. **Enumerate user-reachable surfaces.** Before chunking, list every UI input,
   UI output, downstream consumer, doc, legal/privacy page, email template, and
   settings toggle the capability needs to be fully integrated end-to-end. If
   you can't name them, you don't have a plan — expand or scope down. Surfaces
   deferred go in `## Out of scope` with a reason.
5. **Depth Calibration.** For each surface, state how deep this build goes.
   Required for **standard** and **full** tiers. Skipped in **fast** tier.

   | Surface | Depth | Notes |
   | --- | --- | --- |
   | backend | implementation-ready | … |
   | frontend | interface | … |
   | data/modeling | implementation-ready | … |
   | infra | goals | … |
   | analytics/audit | none | out of scope this build |
   | testing | implementation-ready | … |
   | rollout | goals | … |

   Depth values:
   - `none` — out of scope this build, cross-references only
   - `goals` — desired behavior + affected areas, no file/interface commitments
   - `interface` — files, call paths, component/hook/service/API boundaries, signatures, execution order
   - `implementation-ready` — interface depth + edge cases + test targets + migration detail

   Pick depth per surface. Do not assume backend is always deep or frontend
   always shallow. Depth tells the chunker how much freedom it has on each
   surface.
6. **Break the work into chunks.** Each chunk:
   - is named in 2-8 words
   - lists the files it touches (`files: a.ts, b.tsx, …`)
   - has a clear success check (test to write, endpoint to hit, etc.)
   - is sized to one atomic commit (not too small, not too large)

   **Manifest parser constraints (these cause silent `init` failures if
   ignored).** `manifest.sh init` parses ONLY the section headed exactly
   `## Chunks` (it also accepts `## Stories` / `## Tasks`). Chunks must be a
   **flat numbered list** (lines starting `N.` or `N)`) — NOT bullets or letter
   prefixes like `- **C0.1 …` (those parse to zero chunks → "no numbered chunks
   found"). Per-chunk line format: `N. <name> — files: path1, path2 — check: …`.
   The name is the text before the first em-dash; `files:` is captured until the
   next em/en-dash or hyphen, so **use no hyphens in the file paths** in the
   `files:` hint.
7. **Write the acceptance checklist per chunk (Overlay A) — standard/full tier
   only.** See § Overlay A below. The checklist supersedes the loose success
   check from step 6 and is embedded in the plan before any code.
8. **Write the plan** to `<repo>/plan/PHASE-N-<slug>.md`. Required sections by tier:

   **Fast tier** (all 5 dimensions = Low):
   - `## Risk Scorecard`
   - `## Goal`
   - `## Approach`
   - `## Chunks`
   - `## Out of scope`

   **Standard tier** (any Medium, no High) — fast tier sections plus:
   - `## Decision Table`
   - `## User-reachable surfaces`
   - `## Depth Calibration`
   - `## Acceptance checklist` (per-chunk, from Overlay A)
   - `## Open questions`

   **Full tier** (any High) — standard tier sections plus:
   - `## Prep-work candidates` (from § 1.5)
   - `## Freeze point` (from § 1.6, when applicable)

9. **Run § 1.5 (prep-work loop) if tier = full.** See below.
10. **Run § 1.6 (freeze point) if tier = standard or full AND migrations / public API / infra / auth touched.** See below.
11. **ExitPlanMode.** The `codex-plan-review.sh` hook fires — this is your
    Phase 1 critical review. For **standard** and **full** tiers, treat the
    hook's output as binding: any [high] finding must be triaged (accept →
    revise plan, reject → document why, refine → keep iterating) before
    continuing. No silent fixes. Fast tier still runs the hook but findings
    are advisory.
12. **Present to user.** Single message: plan summary + risk scorecard + the
    batched questions from `## Open questions`. Wait for answers.
13. **Initialize the manifest on approval:**
    ```bash
    ~/.claude/scripts/build-manifest/manifest.sh init plan/PHASE-N-<slug>.md
    ~/.claude/scripts/build-manifest/manifest.sh approve
    ```
    `approve` records the current HEAD as `base_sha` — the start of the commit
    range the review gate checks.

## § 1.5 — Prep-work loop

Runs when **tier = full**. Skipped on fast and standard tiers (though late
prep-work discovery in § 2 step 6 still applies on standard).

1. Survey the modules this build touches for refactor / consolidation
   candidates, each backed by evidence (a duplicated code path, a shallow
   module the feature would have to thread through, a coupling that forces
   edits in several places). If you have an architecture-review skill installed
   (for example `/improve-codebase-architecture`), run it here; otherwise do
   the survey inline.
2. For each candidate, score against the **three gates**:

   | Gate | Test |
   | --- | --- |
   | Independently valuable | The change is still correct if the feature never ships. |
   | Measurably shrinks PR | You can name the feature scope reduction. |
   | Safe to ship alone | No coordinated release, flag, or risky one-way migration required. |

   A candidate must pass all three to become prep work. If any fails, it stays
   inside the feature scope, gets rejected, or moves upstream because it
   exposed a design gap.
3. Record accepted candidates in `## Prep-work candidates` in the plan, each as
   its own row with the three-gate scoring.
4. For each accepted candidate, create a separate prep-work scoping doc at
   `<repo>/plan/PREP-N-<slug>.md`. Prep ships first, on its own commits, before
   the feature chunks begin.

## § 1.6 — Freeze point

Required when any of the following are touched:
- DB migrations (additions, alterations, deletions)
- Public API surface (routes, response shapes)
- Infra (env vars, deployment config, third-party providers)
- Auth / session / permission boundaries

After § 1.5 resolves, write `## Freeze point` to the plan with:
- the date/SHA at which prep enumeration is closed
- a statement that further prep candidates discovered during § 2 become
  follow-up work, not in-scope changes

The plan's `## Freeze point` section IS the freeze flag — `manifest.sh` has no
freeze field, so check the plan for it in § 2 step 6. Past this point, new prep
ideas during chunking get logged to a follow-up file and do not modify the
current build's scope. The owner can re-open prep scoping deliberately, but
drift cannot do it silently.

## Overlay A — Lock the acceptance checklist (standard/full tier, before any code)

**Insertion point:** § 1 step 7, while drafting the plan. Skipped on fast tier.

Claude writes a demanding, specific "definition of done" per chunk *before the
implementation exists*, then it is LOCKED. **Spec-blind by construction:** the
checklist is authored from the spec, not the code, and at eval time (Overlay B)
you RUN it — you do not soften it, drop criteria, or add new code-shaped ones
after seeing the implementation. (Validated by AlphaCodium / AgentCoder: a test
designer who sees the code unconsciously writes tests the code already passes.)

1. **Write a JSON acceptance checklist per chunk.** 3–8 criteria, derived from
   the chunk's success check, the Depth Calibration for the touched surfaces, and
   the obvious failure modes. Cover **normal cases AND edge/error cases** — error
   paths, empty/null/oversized input, concurrency, auth, boundaries, idempotency.
   Schema:

   ```json
   {
     "chunkId": "<id>",
     "criteria": [
       {
         "name": "reorder_persists",
         "description": "PUT /frames/reorder returns 200 AND the new order survives a re-fetch from the DB",
         "threshold": 7,
         "verify": "exact command / endpoint call / UI interaction that proves it"
       }
     ]
   }
   ```

   Each `description` is specific and testable — never "reordering works". Each
   `verify` is the concrete thing you run in Overlay B.

2. **Save** to `<repo>/plan/contracts/chunk-<ID>.json` and embed each chunk's
   checklist in the plan under `## Acceptance checklist`. It supersedes the loose
   success check.

3. **Codex augments the checklist (folded into § 1 step 3 consult, no extra
   round).** Ask Codex to (a) add edge/error cases the checklist is missing —
   Claude has the most build context, Codex is the independent set of eyes for
   what could break — and (b) flag any criterion that is underivable from the
   spec, ambiguous, or unfair. Merge Codex's additions, tighten the unfair ones,
   then LOCK. This is the cross-model trap-setting: a different model contributes
   the failure cases the builder didn't think of.

## § 1a — Audit-then-approve (manifest exists, approved=false)

User already drafted a plan and initialized the manifest. Before executing any
code, run the plan through Codex and let the user review the verdict:

```bash
~/.claude/scripts/build-manifest/manifest.sh audit
```

This prints `ALLOW: <reason>` or `BLOCK: <reason>` plus findings, and logs to
`~/.claude/analytics/codex-plan-reviews.jsonl`. Takes ~60s.

Surface the full audit output to the user along with:
- the chunk list from `manifest.sh status`
- the Risk Scorecard from the plan (if missing, flag it — /build plans must have one)
- any batched questions about scope/unknowns

Wait for the user to **explicitly approve**. Do NOT auto-approve on ALLOW. Possible responses:
- **Approve** → run `manifest.sh approve` → go to § 2.
- **Revise** → help them edit the plan; delete the manifest
  (`rm <repo>/plan/.build-state.json`), re-init, re-audit.
- **Abort** → leave approved=false, stop.

If audit fails (codex down, timeout), surface chunk list + scope questions and
ask whether to proceed without audit. Never block on audit failure.

## § 2 — Execute flow

Loop until `next-chunk` returns nothing.

Run these from the repo root (the manifest's `plan_file` is repo-relative,
e.g. `plan/PHASE-1-health.md`):

```bash
PLAN_FILE=$(jq -r .plan_file plan/.build-state.json)
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
     whatever design skills you have installed (e.g. `/emil-design-eng`,
     `/make-interfaces-feel-better`, gstack's `/design-review`), and can run a
     dev server if needed.

     ```bash
     claude -p "$(cat <<PROMPT
     You are implementing chunk $ID: $NAME from $PLAN_FILE.
     Files in scope: $FILES.
     Use /emil-design-eng and /make-interfaces-feel-better where relevant.
     Edit and save only — do NOT commit. The main /build session commits.
     PROMPT
     )" --allowedTools "Bash,Read,Edit,Write,Glob,Grep,WebFetch,WebSearch" \
       --max-turns 60 > /tmp/build-chunk-${ID}.log 2>&1
     ```

     The heredoc delimiter is deliberately unquoted so `$ID`, `$NAME`,
     `$PLAN_FILE` and `$FILES` expand (their values are inserted literally, not
     re-run as shell). Wait for completion, read the log, verify files were
     modified.
   - **Logic/backend chunk** (business logic, server actions, API routes,
     migrations, scripts, config, auth glue): implement inline in this
     session. No subprocess.

   Vibecop fires on edits automatically (see § 4). Keep edits scoped to this
   chunk's files — if you need to touch something else, stop and ask.

   **2b. Every chunk ships with exactly one verification receipt.** Priority
   order — use the strongest option that applies:

   **Vertical, not horizontal.** When the receipt is a test (option 1), write
   ONE test → run it → confirm RED → write the minimal code to pass → confirm
   GREEN. Do NOT batch tests upfront, do NOT implement-then-test. One test,
   one slice of code, repeat.

   1. **RED→GREEN test** for mockable logic (pure functions, transforms,
      validators, query builders, server actions with testable contracts, bug
      fixes with a reproducible failure).
   2. **Playwright smoke** for API routes and page flows.
   3. **Typecheck/lint + documented manual verification** for migrations,
      auth/provider glue, visual polish, config.

   No receipt = the chunk isn't done. Reference the receipt in the commit body
   so the Codex reviewer sees it.
3. **Commit atomically** with a descriptive message. The post-commit hook
   (`codex-commit-review-on-commit.sh`) auto-fires the 3-reviewer Codex review
   AND marks the chunk `done` with the SHA. **This is Codex's independent
   read-review of the diff — it runs on every tier.**
4. **Run the acceptance checklist (Overlay B) — standard/full tier only.** See
   § Overlay B below. This is the run-it-and-break-it gate: it is authoritative
   for standard/full chunks, and complements (does not replace) the Codex
   commit review from step 3.
5. **Wait for, then read, the Codex commit review.** The hook marks the chunk
   `done` at commit time, *before* the detached review finishes — so `done` in
   the manifest means committed, not reviewed. A review is finished only when
   `~/.claude/analytics/codex-commit-reviews.jsonl` has a line for that
   commit's full SHA (`sha_full`) with status `completed`, `skipped`, `failed`
   or `degraded` (`running` means still in progress). The
   `~/.claude/state/codex-commit-review/<sha>-*/` directory is created when the
   review starts, so its existence proves nothing.

   ```bash
   # Prints the terminal log line for a commit, or nothing if still running.
   review_status() {   # $1 = full SHA
     jq -c --arg s "$1" \
       'select(.sha_full == $s and (.status as $x | ["completed","skipped","failed","degraded"] | index($x)))' \
       ~/.claude/analytics/codex-commit-reviews.jsonl 2>/dev/null | tail -1
   }
   review_status "$(git rev-parse HEAD)"
   ```

   Checking is cheap, so check once before starting the next chunk; if it is
   still running you may start the next chunk and re-check later. If nothing
   appears, poll every ~30s (a 3-reviewer review usually takes a few minutes).
   After ~10 minutes with no terminal line, read
   `~/.claude/analytics/codex-commit-review-bg.log` for the error, then re-run
   the review in the foreground:
   `~/.claude/scripts/codex-commit-review.sh <sha> --repo "$(git rev-parse --show-toplevel)"`.
   The verdict text lives in the state dir — `adjudicator.verdict` (tiers 2–3)
   or `last-msg/adversarial.md` (tier 1) — and the formatted block is in the bg
   log.
   - `completed` with verdict BLOCK (critical/high) → fix, new commit (NOT
     amend), made on top of the blocked commit. Its message MUST end with a git
     trailer naming the blocked commit — a final paragraph containing
     `Review-fix: <sha of the BLOCKed commit>` (a line in the middle of the body
     doesn't count). The manifest never records fix commits, so this trailer is
     how the review gate (§ 3) knows the BLOCK was addressed, even after a
     resume. The fix commit gets its own review; wait for that one too.
   - `completed` with ALLOW, or `skipped` (trivial diff) → move on.
   - `failed` / `degraded` → not a pass. Re-run once in the foreground; if it
     fails again, surface it.
   - **3-round cap** on the same chunk → stop and surface.
6. **Late prep-work discovery.** If during chunking you discover a prep
   candidate that would shrink remaining work, score it against the three
   gates from § 1.5. If it passes AND the plan has no `## Freeze point`
   (§ 1.6), pause chunking, scope and ship the prep, then resume. If freeze is
   in effect, log to follow-up and continue.
7. Repeat until `next-chunk` returns empty.

If a chunk genuinely cannot be completed: `mark-chunk $ID failed` and surface
to user with the specific blocker.

## Overlay B — Run the acceptance checklist (standard/full tier)

**Insertion point:** § 2 step 4, after a chunk is built and committed. Skipped on
fast tier.

1. **Evaluate against the locked checklist.** For EACH criterion in
   `plan/contracts/chunk-<ID>.json`, actually RUN its `verify` with Bash — start
   servers with `&`, hit endpoints, run tests, probe edge and error paths, then
   KILL any server you started. Do not read code and assume. Score 1-10. **Do NOT
   be generous; when in doubt, FAIL.** Mark each `details` `verified-by-run` or
   `verified-by-inspection` — never silently downgrade a run to a read.
   **Only run-based evidence (or a hard static proof, e.g. the type checker
   erroring) can FAIL a chunk.** An inspection-only concern is logged as an
   advisory follow-up, never a gate failure.

2. **Gate.** `passed` = every criterion ≥ its threshold.
   - **Pass** → next chunk.
   - **Fail** → fix it (inline, or a fix commit — NOT amend), with each failing
     criterion noted as `file:line`, expected vs actual, then re-run this eval.
     **3-round cap** → STOP and surface with the eval JSON. If the same criterion
     fails the same way twice, stop at round 2 — the fix isn't converging.

3. **Save** each eval to `<repo>/plan/contracts/chunk-<ID>-eval-round-<m>.json`.

## § 3 — QA flow

All chunks resolved.

**Review gate first.** Before any QA step, run:

```bash
~/.claude/scripts/build-manifest/manifest.sh review-gate
```

It walks every commit in `<base_sha>..HEAD` — `base_sha` is HEAD when the plan
was approved — so it covers fix commits and prep commits that the manifest never
records, and it works the same after a resume. Each commit needs a finished
review, matched on its full SHA: ALLOW passes; BLOCK passes only if a
descendant commit carries a `Review-fix:` trailer resolving to it; `skipped`
(trivial diff) passes but is printed as SKIPPED — list those in the summary —
except for merge commits, which always need a completed review (the reviewer
diffs a merge against its first parent and never skips one); `failed`,
`degraded` or no finished review yet fails. Exit 0 = pass. A manifest approved
before `base_sha` existed fails until you run `manifest.sh set-base <sha>` with
the commit HEAD was at when the plan was approved. On failure: a missing review → wait/poll as in § 2 step 5;
`failed`/`degraded` → re-run that commit's review in the foreground; an
unresolved BLOCK → back to § 2 to fix it. Do not start QA until it passes.

Then invoke the gstack QA skills inline:

1. `/qa` — systematic end-to-end test
2. `/browse` — spot-check UI manually if relevant
3. `/design-review` — only if any UI pixels changed
4. **Overlay C — adversarial integration pass (standard/full tier only).** See
   below.

**If gstack is not installed:** steps 1–3 won't be available. Degrade
gracefully — note the absence in the summary and run a minimal manual smoke
test instead (run the project's test suite if one exists, hit any new endpoints
with `curl`). Document what you tested so the user knows what coverage is
missing. Overlay C still runs.

**Mobile app (Expo/RN/iOS) → run the QA FLEET instead of steps 1–3.** Run it ONCE
over the whole batch or release, not per change — running the full fleet after
every small change is what makes app builds grind. Per change, run only the
cheap gates (typecheck plus any verify scripts), plus Codex for
paywall/gate/data-write code. The fleet's fixes get one re-check, not a new loop.
The user is not a QA step. They get product/taste calls plus a screenshot
summary of changed screens.

| Role | Who | Job | Done when |
|---|---|---|---|
| Code audit A | Codex (read-only) | correctness, races, exactly-once, regressions on the commit | CLEAN, or findings triaged |
| Code audit B + sim | Claude sub-agent | independent code review, THEN drives the real simulator through the changed flow | every changed path has been exercised on the sim |
| Visual auditor | Claude sub-agent | before/after shots of every touched screen on the **smallest (SE) + largest** phone, at edge states (max/min values, long copy, many choices, empty); judges wraps, orphans, clipping, off-screen actions; **fixes what it finds and re-shoots** | no visual defect is left open |
| Flow-walker | Claude sub-agent, persona = fresh-install new user | uninstall → install → walk onboarding → first session → paywall → the rest; flags anything confusing, dead-ended or inconsistent (copy vs behaviour) | a written walk-through with a verdict per step |

- Triage every finding REAL→fix / NOISE→log. A fix gets re-audited by the role
  that found it. Loop to clean, with a 3-round cap per role.
- Run ONE simulator at a time (one booted sim). Fleet subs that touch the sim
  run serially. Code audits run in parallel.
- ONE WRITER PER WORKING TREE. Each code-writing sub gets `isolation: "worktree"`,
  and QA or audit subs pin a commit in their own checkout. Never two writers in
  one tree — concurrent writers in one tree clobber each other's edits.
- Second Codex MUST-FIX on the same feature → stop and run a rewind check before
  writing another forward fix: if the approach or premise was wrong (not just
  buggy), revert to the last good commit and re-plan instead of patching on top.
- Sim driving: use whatever CLI simulator driver your stack supports. AXe is
  one example (taps by testID, no Xcode license or Simulator.app needed); the
  kit does not require it. Keep a per-repo recipe for driving the app
  (e.g. `audit/SIM-DRIVING-HOWTO.md`). A sub must never return "can't tap" as a
  result; it web-searches for a way.
- Every sub brief bans the Agent tool and names an output file.
- Every code-writing sub brief says: run long commands in the foreground with a timeout, and do not end
  the turn before the commit and the report file exist. A sub that backgrounds its final checks goes idle
  with the work uncommitted. Tell: idle or "running", dirty worktree, no process. Its logs are green →
  commit the work yourself; mid-edit → stop it and brief a fresh sub.
- Summary to the user: what changed, a montage of before/after shots, the
  decisions they need to make.

Collect:
- QA health score
- Open P1/P2 findings from commit reviews (grep `~/.claude/analytics/codex-commit-reviews.jsonl` for this build's SHAs)
- Preview URL if available
- Outstanding `[CODEX: REAL]` vibecop findings
- Integration findings from Overlay C (if standard/full)

## Overlay C — Adversarial integration pass ("does the whole thing fit?")

**Insertion point:** § 3 QA, once, after all chunks pass Overlay B. Standard/full
tier only. Per-chunk passing does not mean the feature hangs together.

1. **Scope it to the seams, not the chunks.** Read the spec + every chunk
   checklist, then adversarially probe **only** what per-chunk review can't see:
   - end-to-end user flows across chunk boundaries (do the pieces connect?)
   - contradictions or duplicated/competing logic between chunks
   - integration points, shared state, ordering, data handoffs between modules
   - does the assembled thing deliver the spec's actual value proposition?
   - whole-system error/empty/loading states, not per-endpoint ones

   Do **not** re-score per-chunk criteria — those passed. New level, new findings.

2. **Run it.** Drive the full feature end-to-end (Bash / a `/browse` pass /
   `/qa` style), trying to break the *integration*. Output: a short list of
   integration findings, each `severity` + `details` (`file:line`, repro).

3. **Bound it.** Blocking integration findings → ONE consolidated fix → re-run
   this pass ONCE. After that, remaining findings become **follow-ups logged to
   the plan**, not another loop.

4. **Save** to `<repo>/plan/contracts/bundle-eval-round-<m>.json`.

## § 4 — Vibecop finding handling

Vibecop fires on Edit/Write/MultiEdit (via the `vibecop-on-edit` hook, only in
repos that have vibecop installed). Tags:

- `[CODEX: REAL — recommend fix]` → fix in next edit. Do not defer.
- `[CODEX: NOISE — ignore]` → skip. Log it.
- No tag → judgment call; default to fix.

Architectural / security / data-integrity findings with both REAL and
counter-POV → dispatch a Task sub-agent for a third independent POV.

## § 5 — Ship condition

When § 3 finishes, write the final summary and stop. **Do not push by default.**
Pushing to main is opt-in: only push if the repo's `CLAUDE.md` or `AGENTS.md`
explicitly declares the auto-push contract (e.g. a line like
`/build auto-pushes to main on QA pass`).

1. **Read the repo's `CLAUDE.md` / `AGENTS.md`** to determine the ship policy.
   Default = stop after summary; user pushes manually.
2. **If auto-push is opted in:**
   1. **Verify you are pushing what you built and what was reviewed:**

      ```bash
      ~/.claude/scripts/build-manifest/manifest.sh review-gate --push
      ```

      On top of the § 3 review gate (re-run here, since commits may have landed
      after QA), `--push` fetches `origin main` and fails unless the current
      branch is `main`, every chunk commit is on it, `origin/main` is an
      ancestor of HEAD (the remote isn't ahead), and `origin/main` already has
      everything from before the build (a push sends every commit `origin/main`
      lacks, not just the build's). If the fetch fails or there is no
      `origin/main`, it fails; use `--initial-push` instead of `--push` only
      when `main` has genuinely never been pushed. Non-zero exit → do NOT push (and do not run migrations).
      Stop, and put its FAIL lines in the summary along with the manual push
      instruction.
   2. Run pending DB migrations — if any commit added a migration file, use the
      migrate script the repo declares (`db:migrate`, `migrate`, `db:deploy`,
      `prisma migrate deploy`, etc.; don't invent one) so the new code doesn't
      reference missing columns/tables.
   3. `git push origin main`.
3. **Final summary** with:
   - Commits shipped (from `manifest.sh review-gate`: every commit in the
     build's range, including fix commits)
   - Commits whose review was SKIPPED (trivial diff), from the same output
   - Risk scorecard recap (was the strictness right?)
   - Chunks completed / skipped / failed
   - Open P1/P2 findings across reviews
   - Adversarial eval results (Overlay B pass/fail counts, Overlay C findings) on standard/full
   - Migrations applied, if auto-push ran
   - Push confirmation (origin hash range), if auto-push ran
   - Preview/production URL if the repo declares one
   - QA output
   - Prep-work that shipped (if any)
   - Follow-up items captured during freeze (if any)
   - **If auto-push was NOT opted in:** an explicit "Review and push when
     ready: `git push origin main`" line at the end of the summary.

Then STOP, or hand off if the repo's `CLAUDE.md` declares a close-out flow. Do
NOT invoke `/ship` — that's a different (PR-based) workflow.

## Telemetry (keep logging — confirms the adversarial layer earns its keep)

Per standard/full-tier chunk, after Overlay B resolves, append to
`~/.claude/analytics/build-runs.jsonl`:

```bash
mkdir -p ~/.claude/analytics
cat >> ~/.claude/analytics/build-runs.jsonl <<JSON
{"level":"batch","chunk_id":"<id>","tier":"<standard|full>","contract_criteria":<n>,"trap_criteria_added":<n>,"adversarial_rounds":<n>,"eval_failed_criteria":<n>,"caught_beyond_diff_review":<true|false>}
JSON
```

After Overlay C resolves, append one bundle line:

```bash
cat >> ~/.claude/analytics/build-runs.jsonl <<JSON
{"level":"bundle","phase":"<phase>","integration_findings":<n>,"blocking_findings":<n>,"caught_beyond_per_chunk":<true|false>}
JSON
```

`caught_beyond_diff_review` = did RUNNING the checklist surface a confirmed real
defect the Codex commit review (reading) missed? `caught_beyond_per_chunk` = did
the integration pass catch real breakage all-green chunks hid? If both go
reliably `false` over time, the layer has become ceremony — revisit it.

## Guardrails

- **Strictness comes from the scorecard, not the work type.** A refactor with
  one High dimension runs full tier. A new feature with all Low dimensions
  runs fast tier. The work type does not decide; the risk does.
- **Auto-routing is non-negotiable.** No `--fast` flag, no `--full` flag. The
  scorecard decides the tier. Don't reintroduce optionality through "I'll
  just skip the depth calibration this once" or "this one's clearly trivial,
  skipping the scorecard." The scorecard takes ~30 seconds; running it always
  is what makes the system honest.
- **The adversarial layer is tier-gated, not optional within a tier.** On
  standard/full you write the checklist, Codex augments it, and you RUN it — you
  don't skip Overlay B because "it looks fine." On fast tier you don't add it.
- **Only run-based evidence fails a build.** Inspection-only concerns are
  follow-ups, never gates. If you're failing chunks on "this looks wrong" rather
  than "I ran it and it broke," convert it to a follow-up.
- **The checklist is spec-blind and locked.** Author it from the spec before
  code; never relax, drop, or retrofit criteria to match the implementation.
- **Batch questions.** One message at the plan-approval gate.
- **Codex calls run bare** — no `-m` or `-c` flags. `~/.codex/config.toml`
  pins `gpt-5.5` + `medium`; let it drive. Only override if the user explicitly
  asks for a deeper review.
- **Web research goes through Task (general-purpose), not Codex directly.**
- **3-round cap on any loop** — debate, fix-rounds, adjudication, Overlay B
  eval. Oscillation is fatal; same-failure-twice → stop at round 2.
- **Overlay C is 1 pass + 1 fix** — then follow-ups, never another loop.
- **When a loop hits the cap, adjudicate before surfacing.** Task sub-agent
  with both POVs. Surfacing is last resort.
- **Never amend commits during execute.**
- **Never touch files outside the current chunk's scope** without asking.
- **Never invoke `/ship`.** That's a PR-based workflow; `/build` is its own
  end-to-end thing.
- **Pushing is opt-in, not default.** § 5 stops after the summary unless the
  repo's `CLAUDE.md` or `AGENTS.md` explicitly opts into auto-push. When in
  doubt, stop and let the user push.
- **Freeze means freeze.** Once § 1.6 stamps the freeze point, new prep ideas
  become follow-ups, not scope creep.
