#!/bin/bash
# ~/.claude/hooks/stop-slash-text-guard.sh
# Stop hook. Audit-only detector for inert slash-text at end of assistant
# message (e.g. writing "/end" as a signoff instead of calling the Skill tool).
#
# Design per Plan + Codex review (2026-04-20):
# - Audit, not block. Blocking forces re-gen that may just delete the line
#   without fixing the underlying mimicry, producing worse UX than the bug.
# - Uses `last_assistant_message` from stdin JSON (no transcript parsing).
# - Respects `stop_hook_active` to avoid infinite re-trigger loops.
# - Regex widened to catch punctuation + list-marker variants (/end. /end! - /end).
# - Fails open on any error: log + exit 0 so a broken hook never wedges Stop.

set -uo pipefail

LOG_DIR="$HOME/.claude/analytics"
LOG_FILE="$LOG_DIR/slash-text-violations.jsonl"
mkdir -p "$LOG_DIR" 2>/dev/null || exit 0

# Read stdin. Fail open if unreadable.
INPUT=$(cat 2>/dev/null) || exit 0
[ -z "$INPUT" ] && exit 0

# Require jq; fail open if unavailable.
command -v jq >/dev/null 2>&1 || exit 0

# Loop-break: if we already blocked this stop, don't re-engage.
STOP_ACTIVE=$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null)
[ "$STOP_ACTIVE" = "true" ] && exit 0

LAST_MSG=$(printf '%s' "$INPUT" | jq -r '.last_assistant_message // ""' 2>/dev/null)
[ -z "$LAST_MSG" ] && exit 0

# Extract last non-empty line.
LAST_LINE=$(printf '%s' "$LAST_MSG" | awk 'NF {last=$0} END {print last}')
[ -z "$LAST_LINE" ] && exit 0

# Widened regex: optional leading list marker (- * >), optional whitespace,
# `/` + word (letter + alphanum/_/-), optional trailing punctuation.
# Case-insensitive. Catches: /end, /End, /end., /end!, - /end, **/end** stripped of asterisks.
# Strip leading/trailing ** first to catch bolded variants.
CANDIDATE=$(printf '%s' "$LAST_LINE" | sed -E 's/^\*\*//; s/\*\*$//')
if printf '%s' "$CANDIDATE" | grep -qiE '^[[:space:]]*[-*>]?[[:space:]]*/[A-Za-z][[:alnum:]_-]*[.!]?[[:space:]]*$'; then
  SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null)
  TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  # jq builds the row so quoting is safe even with weird assistant output.
  jq -cn \
    --arg ts "$TIMESTAMP" \
    --arg sid "$SESSION_ID" \
    --arg line "$LAST_LINE" \
    '{timestamp: $ts, session_id: $sid, matched_line: $line}' \
    >> "$LOG_FILE" 2>/dev/null || true
fi

exit 0
