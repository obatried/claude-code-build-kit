# Walkthrough — building a feature with `/build`

A first-run trace of the orchestrator on a small feature. Use this to understand what the kit actually does turn-by-turn before you trust it on something real.

## Setup

You've installed the kit and are in a fresh project repo. You've never run `/build` here before, so there's no `plan/` directory and no manifest.

## Turn 1 — invoke

```
You: /build add a /health endpoint that returns {status, db}
```

Claude (the `/build` skill) runs:

```
~/.claude/scripts/build-manifest/manifest.sh status
```

No manifest exists → enters **§ 1 New build flow**.

## Turn 2 — risk scorecard, research + plan

Before anything else, Claude scores the work on five dimensions (novelty, blast radius, irreversibility, verification difficulty, rollback cost). A new route extends an existing pattern and reverts cleanly, but it's unauthenticated and monitors will page off it, so blast radius is borderline — and borderline scores up. One Medium, no High → **standard tier**: Decision Table, Depth Calibration, and the adversarial checklist are all required. (If every dimension had been Low, it would route to **fast tier** and skip those; there's no flag to choose.)

Claude enters plan mode (Claude Code native). It reads the relevant files (`src/server.ts`, the existing pg pool wiring, any `/routes/` directory) without asking you which files matter.

It identifies one tradeoff: cache the DB check or not. Forms a POV (cache for 1s), then asks Codex:

```
codex exec --skip-git-repo-check <<EOF
Should a /health endpoint that hits the DB cache the result?
My take: 1s TTL — enough to absorb monitor polling, fast enough to surface outages.
Alternative: no cache — always fresh, but a 1Hz monitor will pin the pool.
EOF
```

Codex replies. If it agrees, the decision goes in the plan's `## Decision Table`. If it disagrees, up to 3 rounds of debate with each round passing the previous transcript. After 3 rounds, dispatch a Task sub-agent for an independent third opinion.

Because this is standard tier, the same Codex consult also reviews the per-chunk acceptance checklists Claude drafted from the spec — before any code exists. Codex adds an edge case Claude missed (50 concurrent requests on a cold cache should trigger at most one DB query), the checklist is merged and **locked**, and each chunk's copy is saved to `plan/contracts/chunk-<ID>.json`.

## Turn 3 — write plan + audit

Claude writes `plan/PHASE-1-health.md` with the format from [PHASE-1-sample.md](plan/PHASE-1-sample.md):

```
## Risk Scorecard
## Goal
## Approach
## Decision Table
## User-reachable surfaces
## Depth Calibration
## Chunks
1. Add /health route with cached DB probe — files: src/server.ts, src/routes/health.ts, tests/health.test.ts
2. Document in README + api.md — files: README.md, docs/api.md
## Acceptance checklist
## Freeze point        # a new route is public API surface
## Open questions
## Out of scope
```

The tests live in chunk 1, not a separate "add tests" chunk: receipts are written vertically (one failing test, then the code that passes it), so a test-only chunk after the code would be backwards.

Then `ExitPlanMode`. The `codex-plan-review` PostToolUse hook fires automatically:

```
[codex-plan-review] verdict: ALLOW
findings:
  - low: Consider response shape consistency with /version if that exists.
```

On standard and full tier the hook's output is binding: any high finding must be triaged (accept → revise the plan, reject → document why) before continuing. On fast tier the findings are advisory. ALLOW with low/medium = proceed.

## Turn 4 — present + approve

Claude presents the plan, the risk scorecard, and the open questions to you in a single message. You answer. On approval:

```
manifest.sh init plan/PHASE-1-health.md
manifest.sh approve
```

Manifest is now `approved=true` with 2 pending chunks.

## Turns 5+ — execute (loop per chunk)

Claude enters **§ 2 Execute flow**. For each chunk:

1. `mark-chunk 1 in-progress`
2. **Pick executor**: chunk 1 is "Add /health route with cached DB probe" — logic chunk, implements inline. Chunk 2 is "Document in README + api.md" — docs, also inline. (A design/UI chunk would spawn `claude -p` as a fresh subprocess to get the full design-skill stack.)
3. **Implement** the route. Each `Edit`/`Write` triggers `vibecop-on-edit` if vibecop is installed in the repo.
4. **Produce the receipt**. Chunk 1 has mockable logic → write a failing test first, run it (RED), implement, re-run (GREEN). Receipt referenced in commit body.
5. **Commit atomically**:
   ```
   git add src/server.ts src/routes/health.ts tests/health.test.ts
   git commit -m "Add /health endpoint with cached DB probe

   Receipt: tests/health.test.ts (RED→GREEN), see SHA below."
   ```
6. **`codex-commit-review-on-commit`** auto-fires post-commit. Three reviewers run in parallel + an adjudicator merges them. Verdict + findings logged to `~/.claude/analytics/codex-commit-reviews.jsonl`.
7. **Run the locked checklist (Overlay B).** For each criterion in `plan/contracts/chunk-1.json`, Claude actually runs its `verify` — starts the server, curls `/health`, runs the timeout and concurrency tests, kills the server — and scores it 1–10 without being generous. Only run-based evidence can fail the chunk; "this looks fragile" becomes a follow-up. A failure means a fix commit and a re-run, capped at 3 rounds (2 if the same criterion fails the same way twice). Each round is saved to `plan/contracts/chunk-1-eval-round-<m>.json`.
8. **Read the verdict once the review has finished.** The hook marks the chunk done at commit time, before the background review completes, so Claude waits for a finished line for that SHA in `codex-commit-reviews.jsonl` (checking is cheap; it can start the next chunk meanwhile). ALLOW or low/medium → continue. BLOCK with critical/high → fix in a *new* commit (never amend) whose message ends with `Review-fix: <sha of the blocked commit>`, which triggers another review. 3-round cap.

Repeat for chunk 2.

## Turn N — QA

All chunks `done` → enters **§ 3 QA**. First a review gate, `manifest.sh review-gate`. It walks every commit since the plan was approved, fix commits included, and requires a finished Codex review for each. A BLOCK counts only if a fix commit made on top of it names it in a `Review-fix:` git trailer. Anything unresolved goes back to § 2. Then:

```
/qa
/browse
/design-review   # only if any UI changed
```

Then, because this is standard tier, one **integration pass (Overlay C)**: Claude drives the whole feature end to end looking only at the seams between chunks — e.g. does the response example in the docs match what the route actually returns? Blocking findings get one consolidated fix and one re-run; anything left becomes a follow-up in the plan.

Collects QA health score, open P1/P2 findings, integration findings, preview URL.

## Turn N+1 — summary + stop

**§ 5 Ship** (default, no auto-push opt-in):

```
# Final summary:
- 2 commits shipped: SHA1, SHA2
- Risk scorecard: standard tier (blast radius Medium) — strictness was right
- 2 chunks done, 0 skipped, 0 failed
- 0 open P1/P2 findings
- Acceptance checklist: 9/9 criteria passed by run; integration pass: 0 blocking findings
- QA: 9.2/10
- Review and push when ready: git push origin main
```

`/build` writes the summary and stops. You push manually.

**If your repo opts into auto-push** (by declaring `/build auto-pushes to main on QA pass` in its `CLAUDE.md` or `AGENTS.md`), § 5 instead runs pending DB migrations and `git push origin main` itself, then includes the push confirmation in the summary.

If your project's `CLAUDE.md` declares a follow-on workflow (e.g. "after /build, run /document-release"), `/build` reads that and chains.

## What went wrong (a real-world variation)

If at any point during execute you had hit a problem `/build` couldn't solve in 3 fix-rounds:

1. Chunk gets `mark-chunk N failed` with the specific blocker.
2. Manifest stays in execute state (you can resume after fixing).
3. Claude surfaces to you in a single message: what was tried (3 attempts), what Codex said, what's blocking.

Resume by re-invoking `/build` once you've cleared the blocker — it picks up from `manifest.sh next-chunk` exactly where it stopped.

## What you'd never see in this trace

The discipline hooks fire silently:

- `stuck-detector` watches Edit/Write/Bash. If you'd hit the same file 3× or seen failing Bash 3× in 5 minutes, it auto-consults Codex and surfaces back.
- `gave-up-early-guard` watches end-of-turn for "I can't access X / could you do Y" phrases — audit-only, logged.
- `recommendation-hygiene-nudge` would have fired if your initial prompt had been a recommendation-shaped ask ("what's the best way to..."). For `/build add X`, it stays quiet.

These are invisible until they're not.
