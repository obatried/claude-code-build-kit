# CLAUDE.md Maintenance Policy

Rules for how `~/.claude/CLAUDE.md` (and any project-local CLAUDE.md) is maintained.

**Goal:** Keep CLAUDE.md a scannable reference card, not a graveyard.

Added: 2026-04-23 | Last reviewed: 2026-04-23

---

## 1. Every section earns rent

**Shape: one bolded thesis, ≤8 bullets, one "The test:" line.**

- Thesis is a single bolded sentence at the top of the section.
- ≤8 bullets. If more, split or trim.
- Exactly one "The test:" line that tells me how to self-audit compliance.

The test: every section has a line starting with "The test:". Missing = violation.

## 2. Before adding, try updating

**New guidance extends an existing section unless truly orthogonal. Target ≤10 sections total.**

- If a new rule overlaps an existing section by 50%+, update instead of adding.
- If truly new, name why: what's orthogonal about it?
- More than 10 sections means the file is too big to keep in working memory.

The test: any new section must cite which existing sections I considered extending and why none fit.

## 3. No silent conflicts

**If two sections can fire on the same situation, add a "Precedence:" line.**

- Scan for rules that could apply simultaneously.
- If found, add "Precedence: §A wins when X; §B wins when Y" to the later section.
- Conflicts reconciled in writing, not by vibe.

The test: grep for "Precedence:". Sections that overlap semantically without a Precedence line = silent conflict.

## 4. Dated

**Every section tagged `Added: YYYY-MM-DD | Last reviewed: YYYY-MM-DD`.**

- Every 90 days, walk the file. For each: has Claude applied this recently? Is the triggering incident still relevant?
- Delete or merge if stale. Bump `Last reviewed` if live.
- The weekly audit surfaces stale sections in the Monday digest.

The test: any section where `Last reviewed` is >90 days old without a review note = stale, needs review.

## 5. Examples live elsewhere

**CLAUDE.md stays a reference card. Worked examples go in `~/.claude/EXAMPLES.md`.**

- Rules are terse bullets. Long ❌/✅ pairs, code blocks, narratives go in EXAMPLES.md.
- Sections may link to an EXAMPLES.md anchor; never inline more than ~3 lines of example.

The test: any CLAUDE.md section longer than ~15 lines is leaking examples into the rules file.

## 6. Dog-food the rules

**Edits to CLAUDE.md follow §§2, 3, 4 of CLAUDE.md itself: surgical, simple, goal-driven.**

- Surgical: change the lines that matter, not adjacent formatting.
- Simple: every new line earns its spot.
- Goal-driven: every edit traces to a named incident, memory file, or pattern.

The test: I can point to the trigger (date, memory path, observation) for every added line.

## 7. Rule-companion sync

**Sections with a companion hook/skill/script stay in sync with it.**

- All (section ↔ companion) pairs are listed in `~/.claude/CLAUDE_MAP.md`.
- Editing either side triggers a check of the other.
- If you want automated drift detection, write a short audit script that compares `mtime` between paired files and flags pairs where one side has moved more than N days ahead of the other. (The kit doesn't ship one — it's a per-team policy choice.)

The test: when you edit a CLAUDE.md section that has a companion entry in `CLAUDE_MAP.md`, you also touched the companion (or recorded "no change needed") in the same edit.
