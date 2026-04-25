#!/bin/bash
# ~/.claude/scripts/gave-up-early-review.sh
# One-shot review of the "Don't Give Up Prematurely" Stop hook audit log.
# Invoked by launchd on 2026-04-30 09:00 America/Chicago (one week after
# install on 2026-04-23). Writes a markdown report into
# ~/.claude/state/reminders/ so the 8am daily-summary email surfaces it.
#
# Design:
# - Sentinel-guarded for idempotency (prevents annual replay).
# - Absolute paths, explicit PATH, cd to $HOME for predictable `claude -p` ctx.
# - Graceful handling of missing/empty log (writes "all clear" reminder).
# - --dry-run writes to /tmp instead of real reminder dir.
# - Best-effort self-unload of the launchd plist on success.

set -uo pipefail

export HOME="${HOME:?HOME unset}"
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

CLAUDE_BIN="$HOME/.local/bin/claude"
LOG_FILE="$HOME/.claude/analytics/gave-up-early.jsonl"
RULE_FILE="$HOME/.claude/CLAUDE.md"
HOOK_FILE="$HOME/.claude/hooks/gave-up-early-guard.sh"

SENTINEL_DIR="$HOME/.claude/state/sentinels"
SENTINEL="$SENTINEL_DIR/gave-up-early-review.done"
REMINDER_DIR="$HOME/.claude/state/reminders"
RUN_LOG_DIR="$HOME/.claude/logs"
RUN_LOG="$RUN_LOG_DIR/gave-up-early-review.log"
PLIST_LABEL="com.claude-code-build-kit.gave-up-early-review"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"

DRY_RUN=false
FORCE=false
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --force)   FORCE=true ;;
  esac
done

mkdir -p "$SENTINEL_DIR" "$REMINDER_DIR" "$RUN_LOG_DIR" 2>/dev/null || true

log() {
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$RUN_LOG" 2>/dev/null
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

log "run start (dry_run=$DRY_RUN, force=$FORCE)"

# Idempotency: skip if sentinel present and not forced.
if [ -f "$SENTINEL" ] && [ "$FORCE" = "false" ]; then
  log "sentinel present, exiting. sentinel=$SENTINEL"
  exit 0
fi

# Safety: don't run wildly late (e.g. if launchd somehow replays in 2027).
# Max window = 2026-05-14 (two weeks after intended date).
TODAY_EPOCH=$(date +%s)
MAX_EPOCH=$(date -j -f "%Y-%m-%d" "2026-05-14" +%s 2>/dev/null || echo 0)
if [ "$MAX_EPOCH" -gt 0 ] && [ "$TODAY_EPOCH" -gt "$MAX_EPOCH" ] && [ "$FORCE" = "false" ]; then
  log "today is past 2026-05-14, refusing stale run"
  exit 0
fi

cd "$HOME" || { log "cd \$HOME failed"; exit 1; }

# Pick output path. Reminder filename includes the review date so the daily
# summary surfaces it in the next morning's email.
TODAY_ISO=$(date +%Y-%m-%d)
if [ "$DRY_RUN" = "true" ]; then
  OUT="/tmp/gave-up-early-review-${TODAY_ISO}.md"
else
  OUT="$REMINDER_DIR/gave-up-early-review-${TODAY_ISO}.md"
fi
log "report output: $OUT"

# Read inputs, handle missing files gracefully.
RULE_CONTENT=""
HOOK_CONTENT=""
LOG_CONTENT=""
LOG_ROWS=0

if [ -f "$RULE_FILE" ]; then
  # Extract just Section 9 to keep context tight.
  RULE_CONTENT=$(awk '/^## 9\. Don'\''t Give Up Prematurely/,/^## [0-9]+\./' "$RULE_FILE" \
    | sed '$d')
  [ -z "$RULE_CONTENT" ] && RULE_CONTENT=$(cat "$RULE_FILE" 2>/dev/null | tail -80)
else
  log "WARN: rule file missing at $RULE_FILE"
fi

if [ -f "$HOOK_FILE" ]; then
  HOOK_CONTENT=$(cat "$HOOK_FILE")
else
  log "WARN: hook file missing at $HOOK_FILE"
fi

if [ -f "$LOG_FILE" ]; then
  LOG_ROWS=$(wc -l < "$LOG_FILE" | tr -d ' ')
  LOG_CONTENT=$(cat "$LOG_FILE")
else
  log "log file missing — treating as 0 rows"
fi

log "log rows: $LOG_ROWS"

# Short-circuit: empty log = rule is working, no need to invoke claude.
if [ "$LOG_ROWS" = "0" ] || [ -z "$LOG_CONTENT" ]; then
  cat > "$OUT" <<EOF
# Gave-Up-Early hook — week 1 review (EMPTY LOG)

**Date:** ${TODAY_ISO}
**Result:** No entries in \`~/.claude/analytics/gave-up-early.jsonl\` since install on 2026-04-23.

## Interpretation

Either:
- Section 9 is working — Claude has not given up prematurely in any observable turn this week, or
- The hook never fired (Stop events not triggering in this harness — unlikely given end-to-end test on install day passed).

## Recommendation

**Do nothing for now.** If you want stronger signal, widen the regex to catch softer hedging phrases ("let me know if…", "could you…") and review in another week.

Delete this file to dismiss.
EOF
  log "empty log — wrote all-clear reminder"
else
  # Invoke claude -p with the review prompt + context.
  # Prompt is self-contained; remote/cloud context not needed.
  # read -d '' idiom (bash 3.2 can't handle heredocs inside $()).
  IFS='' read -r -d '' PROMPT <<'PROMPT_EOF' || true
Review the audit log for the "Don't Give Up Prematurely" Stop hook installed on 2026-04-23.

The rule (from CLAUDE.md Section 9): before saying "I can't," "could you do X," "this needs to be manual," etc., I should try 3 distinct approaches AND consult Codex first.

The hook (audit-only, never blocks) scans my final assistant message each turn and logs matched lazy phrases to a JSONL file. Each row has: timestamp, session_id, cwd, matched_pattern, excerpt, tool_count (this-turn tool_uses from the transcript tail), codex_hits, codex_called.

Produce a report UNDER 300 WORDS with these sections:

1. **Summary:** total rows + earliest-to-latest span + any date clustering.
2. **Buckets:** cluster by tool_count (0 / 1-2 / 3+) x codex_called (true/false). Call out the "tool_count: 0, codex_called: false" quadrant — that's the strongest drift signal.
3. **Sample classification:** pick 5-10 excerpts across buckets. Classify each as:
   REAL DRIFT — gave up when I could have kept trying
   FALSE POSITIVE — legit ask for user-only info, quoted/meta use of the phrase, or explaining the rule itself
   AMBIGUOUS
4. **Recommendation:** exactly ONE of:
   DO NOTHING (rule is working)
   TIGHTEN REGEX (name which patterns to narrow and why)
   ADD QUOTED-STRING EXCLUSION (if many FPs come from quoted examples)
   UPGRADE TO BLOCKING (only if real drift is frequent AND unambiguous)
5. If total rows < 5: say "sample too small, wait another week" and recommend deferring.

Format as brief markdown. No preamble. No signoff. Data follows.
PROMPT_EOF

  # Compose full stdin: prompt + context files + log
  INPUT=$(
    printf '%s\n\n' "$PROMPT"
    printf '=== CLAUDE.md Section 9 ===\n%s\n\n' "$RULE_CONTENT"
    printf '=== Hook script ===\n```bash\n%s\n```\n\n' "$HOOK_CONTENT"
    printf '=== Audit log (%s rows) ===\n```\n%s\n```\n' "$LOG_ROWS" "$LOG_CONTENT"
  )

  if [ ! -x "$CLAUDE_BIN" ]; then
    log "ERROR: claude CLI not found at $CLAUDE_BIN"
    cat > "$OUT" <<EOF
# Gave-Up-Early review FAILED

**Date:** ${TODAY_ISO}
**Error:** \`claude\` CLI not found at \`$CLAUDE_BIN\`.
**Log has $LOG_ROWS rows** — review manually:

\`\`\`
jq . "$LOG_FILE"
\`\`\`

Delete this file to dismiss.
EOF
    log "wrote failure reminder (claude bin missing)"
    exit 0
  fi

  log "invoking claude -p (log rows: $LOG_ROWS)"
  REPORT=$(printf '%s' "$INPUT" | "$CLAUDE_BIN" -p 2>> "$RUN_LOG")
  CLAUDE_EXIT=$?
  log "claude -p exit: $CLAUDE_EXIT, report bytes: ${#REPORT}"

  if [ "$CLAUDE_EXIT" -ne 0 ] || [ -z "$REPORT" ]; then
    cat > "$OUT" <<EOF
# Gave-Up-Early review FAILED

**Date:** ${TODAY_ISO}
**Error:** \`claude -p\` exited $CLAUDE_EXIT or returned empty.
**Log has $LOG_ROWS rows.** Review manually:

\`\`\`
jq . "$LOG_FILE"
\`\`\`

See \`$RUN_LOG\` for details. Delete this file to dismiss.
EOF
    log "wrote failure reminder (claude -p failed)"
  else
    cat > "$OUT" <<EOF
# Gave-Up-Early hook — week 1 review (${TODAY_ISO})

*${LOG_ROWS} rows in log since install on 2026-04-23. Auto-generated via \`claude -p\` from \`~/.claude/scripts/gave-up-early-review.sh\`. Delete this file to dismiss.*

---

${REPORT}

---

**Raw log:** \`$LOG_FILE\` • **Hook:** \`$HOOK_FILE\` • **Rule:** \`$RULE_FILE\` (Section 9)
EOF
    log "wrote report reminder successfully"
  fi
fi

# Idempotency sentinel.
if [ "$DRY_RUN" = "false" ]; then
  touch "$SENTINEL"
  log "sentinel written: $SENTINEL"
  # Best-effort self-unload so the plist doesn't refire next year.
  if [ -f "$PLIST_PATH" ]; then
    launchctl bootout "gui/$(id -u)/${PLIST_LABEL}" 2>/dev/null && \
      log "launchctl bootout OK" || log "launchctl bootout non-zero (may not be loaded)"
  fi
fi

log "run end"
exit 0
