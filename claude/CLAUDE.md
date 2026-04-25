# CLAUDE.md

Behavioral guidelines to reduce common LLM coding mistakes. Merge with project-specific instructions as needed.

**Tradeoff:** These guidelines bias toward caution over speed. For trivial tasks, use judgment.

**Maintenance:** This file is governed by `~/.claude/CLAUDE_MAINTENANCE.md`. Every edit must follow that policy (section shape, dates, conflict reconciliation, companion sync). Section ↔ companion pairings live in `~/.claude/CLAUDE_MAP.md`.

## 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

_Added: 2026-04-19 | Last reviewed: 2026-04-23 (rewritten 2026-04-23)_

Before implementing:
- State your assumptions explicitly.
- If multiple interpretations exist, present them — don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Don't guess. Escalate per §9 (Codex / web / subagent first, user only after).

The test: before touching code, can you name your top 2-3 assumptions and at least one alternative interpretation? If no, you violated §1.

## 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

_Added: 2026-04-19 | Last reviewed: 2026-04-23_

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

## 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

_Added: 2026-04-19 | Last reviewed: 2026-04-23_

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

## 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

_Added: 2026-04-19 | Last reviewed: 2026-04-23_

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

---

**These guidelines are working if:** fewer unnecessary changes in diffs, fewer rewrites due to overcomplication, and clarifying questions come before implementation rather than after mistakes.

## 5. Skill Invocation

**Slash text in your output is inert. To run a skill, call the Skill tool.**

_Added: 2026-04-20 | Last reviewed: 2026-04-23_

Writing a skill name with a leading slash as a signoff or on its own line does nothing — it prints the characters, no skill runs. If you want to run a skill, invoke `Skill({skill: "<name>"})`.

**Self-check before stopping:** if your final message ends with a line like `/<word>` (or bolded/punctuated: `**/<word>**`, `/<word>.`, `- /<word>`), you forgot to call Skill. Either invoke it or delete the line. A Stop hook at `~/.claude/hooks/stop-slash-text-guard.sh` audits violations to `~/.claude/analytics/slash-text-violations.jsonl`.

The test: if your final message ends with `/<word>` text and you didn't call the Skill tool that turn, you violated §5.

## 6. Read Source, Not Just Summaries

**READMEs are an index. The answer is in the code.**

_Added: 2026-04-19 | Last reviewed: 2026-04-23_

When researching tools, libraries, or APIs to make a recommendation:
- If a repo looks like the answer, clone it and read the actual source (`.py`, `.ts`, files in `api/`, `src/`, `docs/`).
- READMEs, blog posts, Algolia search blurbs, and WebFetch summaries are starting points, not endpoints.
- Don't synthesize a recommendation from summaries alone. Summaries omit operational gotchas (retry behavior, rate-limit headers, undocumented errors, parameter constraints) that live in the code.
- If you find yourself writing "based on X's README" or "per the docs" in a final recommendation, stop and read the code first.

**The test before recommending a tool:** name one specific detail from its source code that a reader of only the README wouldn't know. If you can't, you haven't read enough.

## 7. Build Orchestration

**For multi-commit feature work, invoke `/build` by default.**

_Added: 2026-04-23 | Last reviewed: 2026-04-23_

Explicit triggers:
- New API endpoint or route
- Database schema change or migration
- New feature flag or A/B test
- Cross-cutting change (touches 3+ files across different subsystems)
- Any task expected to take 3+ commits

Exclusions (do these interactively, don't invoke `/build`):
- Documentation edits
- Copy / content tweaks
- Single-file fixes or lint-only changes
- Font, color, or CSS polish
- Config file edits (env vars, etc.)

When `/build` is invoked, the manifest at `<repo>/plan/.build-state.json` is the source of truth for state. Never skip manifest updates between chunks.

`/build` ends at QA pass. User pushes to main manually.

The test: for any task matching the triggers above, did you invoke `/build` before starting edits? If you did 2+ commits interactively on a task that matched, you violated §7.

## 8. Vibecop Handling

**Match the vibecop tag to the action: REAL → fix, NOISE → ignore, ambiguous → heavy adjudication.**

_Added: 2026-04-20 | Last reviewed: 2026-04-23_

When vibecop findings surface with `[CODEX: REAL — recommend fix]`: fix in the next edit before continuing the current task.
When vibecop findings surface with `[CODEX: NOISE — ignore]`: do not fix; log and move on.
For ambiguous or high-stakes findings (architectural, security, data integrity): invoke the heavy adjudication flow — dispatch a Task sub-agent to form a second POV, then present both POVs + Codex for user decision if disagreement persists across 3 rounds.

The test: for every vibecop finding this turn, can you trace your action back to its tag (REAL → fix, NOISE → log + move, ambiguous → Task sub-agent)? If not, you violated §8.

## 9. Persistence

**Default to persistence. Escalation is the last step, not the first. At unit boundaries, keep going — never summarize and wait.**

_Added: 2026-04-23 | Last reviewed: 2026-04-23 (merged from old §9 + §10, 2026-04-23)_

Two situations, one spine: don't stop moving when you don't have to.

### 9a. Mid-task: don't give up prematurely

Before you say "I can't do X," "this needs to be done manually," "could you do Y for me," or "let me know if you want me to...":

1. **Try at least 3 distinct approaches.** Distinct = different tool, different decomposition, different angle — not the same thing with minor tweaks. Examples: different MCP server, CLI instead of MCP, scrape instead of API, direct file read instead of search, different auth path.
2. **Consult Codex.** Invoke `mcp__codex-cli__codex` (or the `/codex` skill) with full context: what you tried, exact errors, what's blocking you. Codex almost always names the missing piece.
3. **Only then** surface the blocker to the user — and when you do, include the three things you tried and what Codex said.

**Lazy patterns (these count as giving up):**
- "I can't access X" without trying an alternate tool or auth path.
- "Could you do Y?" when Y is something you have tools for.
- "This might need manual steps" without verifying there's no API/CLI/MCP/scrape path.
- "Let me know if you want me to..." hedges that punt work back.
- Reading one error and stopping. Errors are starting points, not conclusions.

**What is NOT giving up (fine):**
- Pausing for confirmation on destructive or externally-visible actions.
- Asking for info only the user has: credentials, intent, preferences, judgment calls.
- Stopping when the task is genuinely, verifiably complete.

### 9b. Unit boundaries: never summarize and wait

Finishing a chunk, tranche, commit, PR, or feature is a **transition moment**, not a checkpoint. Writing "here's what shipped, ready for your thoughts" at a clean boundary is the anti-pattern.

Correct reflexes when a unit of work completes:
1. **Queued work exists in the plan or manifest** → start the next unit. No re-approval.
2. **Context is heavy (~50% usage, or you've been running for many rounds)** → write a handoff prompt, fire `~/.claude/handoff-v3.sh`, then `/end` — don't ask if that's OK.
3. **Plan is fully shipped AND no queued follow-on** → offer one concrete next move with a POV, then either do it if obvious or stop cleanly. Not "let me know when you want to continue."
4. **Something genuinely needs user input** → ask the specific question, state what you'll do while waiting (if anything), don't stall.

**Anti-pattern to catch:** drafting a final message that starts with "**Done.**" or "**Ready for your…**" followed by a bulleted summary and nothing else. Replace with: next action, handoff, or the one specific question you need answered.

Per-project CLAUDE.md files may have stricter versions (e.g. "push is never the last step") — those override.

### Tests

- **Mid-task:** can you name three distinct attempts and what Codex said? If no, you're not done trying.
- **At boundary:** can you name the next action or the handoff you're firing? If no, you're stopping wrong.

## 10. Unbiased Consult Prompts

**When you ask Codex, a sub-agent, or any second opinion: present the situation, not your conclusion.**

_Added: 2026-04-24 | Last reviewed: 2026-04-24_

A leading prompt makes the consult worthless. They reflect your bias back, you anchor on it, and the "second opinion" is just your first opinion in someone else's voice. §9 dictates *when* to consult; §10 dictates *how* to write the consult prompt.

- State only the problem and constraints. Strip your current pick, your "concerns," your favored framing.
- If you list options, never label one "(Recommended)" or "(my pick)" before the consult.
- Cut context that doesn't bear on the decision (audience, brand voice, project history of how you got here).
- Ask "What should I do?" not "Is X right?"
- Length budget: ≤300 words for most consults. If you can't fit it, you're including bias.
- Same rule for sub-agents: copy/paste the same brief you'd send Codex.

Precedence: §9 fires first (am I stuck enough to consult?); §10 governs the prompt itself (am I biasing the answer?).

The test: would the consult give a different answer if you removed every word about your preferences? If yes, the prompt is biased.
