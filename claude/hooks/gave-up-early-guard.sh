#!/bin/bash
# ~/.claude/hooks/gave-up-early-guard.sh
# Stop hook. Audit-only detector for "gave up / escalated prematurely" phrases
# in the final assistant message. Matches CLAUDE.md Section 9 — the rule is:
# try 3 distinct approaches + consult Codex before escalating. This hook logs
# suspected violations with turn context (tool-use count, was Codex called)
# so we can review and tune, then upgrade to blocking later if drift is real.
#
# Design notes:
# - Audit only. Always exits 0. Never blocks Stop.
# - Uses `last_assistant_message` + `transcript_path` from stdin.
# - Enriches each log row with tool_use count and codex_called from the
#   recent transcript tail, so "lazy phrase after 0 attempts, no Codex" is
#   distinguishable from "legit ask for user-only info after 5 tools + Codex".
# - Respects `stop_hook_active` to avoid re-trigger loops.
# - Fails open on every error path.

set -uo pipefail

LOG_DIR="$HOME/.claude/analytics"
LOG_FILE="$LOG_DIR/gave-up-early.jsonl"
mkdir -p "$LOG_DIR" 2>/dev/null || exit 0

INPUT=$(cat 2>/dev/null) || exit 0
[ -z "$INPUT" ] && exit 0

command -v jq >/dev/null 2>&1 || exit 0

STOP_ACTIVE=$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null)
[ "$STOP_ACTIVE" = "true" ] && exit 0

LAST_MSG=$(printf '%s' "$INPUT" | jq -r '.last_assistant_message // ""' 2>/dev/null)
[ -z "$LAST_MSG" ] && exit 0

# Narrow pattern set to start. Widen/tighten via log review.
# Case-insensitive alternation passed to grep -E.
PATTERN='i can'\''t|i cannot|i am unable to|i'\''m unable to|i do not have (access|a way|the ability|permission|credentials)|i don'\''t have (access|a way|the ability|permission|credentials)|(need|needs|has) to be done manually|(might|may|would) need (to be done )?manual|you'\''ll need to (do|run|check|fix|send|create|delete|update|modify|adjust|configure|set up|install|download|upload|open|copy|paste)|you need to (do|run|check|fix|send|create|delete|update|modify|adjust|configure|set up|install|download|upload|open|copy|paste) (this|that|it) (yourself|manually)|you'\''d need to|unfortunately,? i|is not possible|isn'\''t possible'

MATCH=$(printf '%s' "$LAST_MSG" | grep -ioE "$PATTERN" | head -1)
[ -z "$MATCH" ] && exit 0

# Suspect phrase found. Gather turn context.
TRANSCRIPT_PATH=$(printf '%s' "$INPUT" | jq -r '.transcript_path // ""' 2>/dev/null)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null)
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null)
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Count tool_use entries and Codex calls in the recent transcript tail.
# 200 lines comfortably covers any single turn; audit doesn't need perfect
# turn boundaries.
TOOL_COUNT=0
CODEX_HITS=0
if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
  RECENT=$(tail -200 "$TRANSCRIPT_PATH" 2>/dev/null)
  if [ -n "$RECENT" ]; then
    TOOL_COUNT=$(printf '%s' "$RECENT" | jq -s '
      [.[] | .message?.content?
       | select(type == "array")
       | .[]?
       | select(.type == "tool_use")]
      | length
    ' 2>/dev/null)
    [[ "$TOOL_COUNT" =~ ^[0-9]+$ ]] || TOOL_COUNT=0

    CODEX_HITS=$(printf '%s' "$RECENT" | jq -s '
      [.[] | .message?.content?
       | select(type == "array")
       | .[]?
       | select(.type == "tool_use" and ((.name // "") | test("codex"; "i")))]
      | length
    ' 2>/dev/null)
    [[ "$CODEX_HITS" =~ ^[0-9]+$ ]] || CODEX_HITS=0
  fi
fi

if [ "$CODEX_HITS" -gt 0 ]; then CODEX_CALLED=true; else CODEX_CALLED=false; fi

# ±100 char excerpt around first match for human review.
EXCERPT=$(printf '%s' "$LAST_MSG" | grep -ioE ".{0,100}($PATTERN).{0,100}" | head -1)

jq -cn \
  --arg ts "$TIMESTAMP" \
  --arg sid "$SESSION_ID" \
  --arg cwd "$CWD" \
  --arg match "$MATCH" \
  --arg excerpt "$EXCERPT" \
  --argjson tool_count "$TOOL_COUNT" \
  --argjson codex_hits "$CODEX_HITS" \
  --argjson codex_called "$CODEX_CALLED" \
  '{timestamp: $ts, session_id: $sid, cwd: $cwd, matched_pattern: $match, excerpt: $excerpt, tool_count: $tool_count, codex_hits: $codex_hits, codex_called: $codex_called}' \
  >> "$LOG_FILE" 2>/dev/null || true

exit 0
