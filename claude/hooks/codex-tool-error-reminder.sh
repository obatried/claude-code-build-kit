#!/bin/bash
# ~/.claude/hooks/codex-tool-error-reminder.sh
#
# PostToolUse hook (matcher: "*"). Fires when ANY tool call errors and injects a
# system-reminder into Claude's next turn nudging a Codex consult BEFORE retrying
# or switching tools. Umbrella "any tool errored" hook — coexists with
# stuck-detector.sh (which handles 3x loops and auto-consults Codex).
#
# Design:
#   - Does NOT call Codex. Just nudges Claude to consider consulting Codex.
#   - Injects reminder via JSON: hookSpecificOutput.additionalContext
#   - Throttle: 10-min window per session.
#   - Ignores benign "errors": grep/rg/diff no-match, Read on missing file,
#     empty tool_response, Bash exit 0.
#
# Disable: `touch ~/.claude/state/codex-tool-error-reminder/DISABLED`, or
# remove the hook entry from ~/.claude/settings.json, or `chmod -x` this file.

set -uo pipefail

LOG_DIR="$HOME/.claude/analytics"
LOG_FILE="$LOG_DIR/codex-tool-error-reminder.jsonl"
STATE_ROOT="$HOME/.claude/state/codex-tool-error-reminder"
THROTTLE_SEC=600

mkdir -p "$LOG_DIR" "$STATE_ROOT" 2>/dev/null || true

log_event() {
  local status="$1" note="$2" extras_json="${3-}"
  [ -z "$extras_json" ] && extras_json="{}"
  if command -v jq >/dev/null 2>&1; then
    jq -nc \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg status "$status" \
      --arg note "$note" \
      --argjson extras "$extras_json" \
      '{ts:$ts, status:$status, note:$note} + $extras' \
      >> "$LOG_FILE" 2>/dev/null || true
  fi
}

trap 'log_event "error" "hook errored: ${BASH_COMMAND:-unknown}"; exit 0' ERR

[ -f "$STATE_ROOT/DISABLED" ] && exit 0

HOOK_INPUT=$(cat)
command -v jq >/dev/null 2>&1 || { log_event "skipped" "jq not on PATH"; exit 0; }

SESSION_ID=$(printf '%s' "$HOOK_INPUT" | jq -r '.session_id // empty' 2>/dev/null) || SESSION_ID=""
TOOL_NAME=$(printf '%s'  "$HOOK_INPUT" | jq -r '.tool_name  // empty' 2>/dev/null) || TOOL_NAME=""

if [ -z "$SESSION_ID" ] || [ -z "$TOOL_NAME" ]; then
  log_event "skipped" "missing session_id or tool_name"
  exit 0
fi

# Never fire on the Codex tool itself — would suggest consulting Codex about Codex errors (loop risk)
case "$TOOL_NAME" in
  mcp__codex-cli__*) exit 0 ;;
esac

SESSION_HASH=$(printf '%s' "$SESSION_ID" | shasum -a 256 2>/dev/null | head -c 16)
[ -z "$SESSION_HASH" ] && SESSION_HASH="unknown"
SESSION_DIR="$STATE_ROOT/$SESSION_HASH"
mkdir -p "$SESSION_DIR" 2>/dev/null || true
THROTTLE_FILE="$SESSION_DIR/last-fired.txt"

classify_error() {
  local exit_code interrupted err_field is_error
  exit_code=$(printf '%s' "$HOOK_INPUT" | jq -r '.tool_response.exit_code // empty' 2>/dev/null) || exit_code=""
  interrupted=$(printf '%s' "$HOOK_INPUT" | jq -r '.tool_response.interrupted // empty' 2>/dev/null) || interrupted=""
  err_field=$(printf '%s' "$HOOK_INPUT" | jq -r '.tool_response.error // empty' 2>/dev/null) || err_field=""
  is_error=$(printf '%s' "$HOOK_INPUT" | jq -r '.tool_response.is_error // empty' 2>/dev/null) || is_error=""

  if [ "$interrupted" = "true" ] || [ "$is_error" = "true" ]; then
    printf 'true'; return
  fi
  if [ -n "$err_field" ] && [ "$err_field" != "null" ]; then
    printf 'true'; return
  fi

  if [ "$TOOL_NAME" = "Bash" ] && [ -n "$exit_code" ]; then
    if [ "$exit_code" = "0" ]; then
      printf 'false'; return
    fi
    local cmd stderr_len
    cmd=$(printf '%s' "$HOOK_INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null) || cmd=""
    stderr_len=$(printf '%s' "$HOOK_INPUT" | jq -r '(.tool_response.stderr // "") | length' 2>/dev/null) || stderr_len=0
    if [ "$exit_code" = "1" ] && [ "$stderr_len" = "0" ]; then
      # Benign no-match exits
      if printf '%s' "$cmd" | grep -qE '(^|[|& ;])(grep|rg|egrep|fgrep|ripgrep|diff|test|\[)( |$)' 2>/dev/null; then
        printf 'false'; return
      fi
    fi
    printf 'true'; return
  fi

  case "$TOOL_NAME" in
    Read|Glob)
      printf 'false'; return
      ;;
  esac

  local response_str
  response_str=$(printf '%s' "$HOOK_INPUT" | jq -c '.tool_response // ""' 2>/dev/null) || response_str=""
  if [ -z "$response_str" ] || [ "$response_str" = '""' ] || [ "$response_str" = 'null' ]; then
    printf 'false'; return
  fi

  if printf '%s' "$response_str" | grep -qE '"(isError|is_error)":[[:space:]]*true' 2>/dev/null; then
    printf 'true'; return
  fi
  if printf '%s' "$response_str" | grep -qE '(MCP error|Unable to|Failed to|[Tt]imeout|timed out|ECONNREFUSED|ETIMEDOUT|navigation timeout|InputValidationError)' 2>/dev/null; then
    printf 'true'; return
  fi

  case "$TOOL_NAME" in
    Edit|Write|NotebookEdit)
      if printf '%s' "$response_str" | grep -qE '"error"[[:space:]]*:' 2>/dev/null; then
        printf 'true'; return
      fi
      ;;
  esac

  printf 'false'
}

IS_ERROR=$(classify_error)
[ "$IS_ERROR" != "true" ] && exit 0

NOW_TS=$(date +%s)
LAST_FIRED=0
if [ -f "$THROTTLE_FILE" ]; then
  LAST_FIRED=$(cat "$THROTTLE_FILE" 2>/dev/null || echo 0)
  LAST_FIRED=${LAST_FIRED:-0}
fi
ELAPSED=$((NOW_TS - LAST_FIRED))
if [ "$ELAPSED" -lt "$THROTTLE_SEC" ]; then
  log_event "throttled" "tool error within throttle window" \
    "$(jq -nc --arg tool "$TOOL_NAME" --argjson remaining $((THROTTLE_SEC - ELAPSED)) '{tool:$tool, throttle_remaining_s:$remaining}')"
  exit 0
fi

ERR_HINT=$(printf '%s' "$HOOK_INPUT" | jq -r '
  [.tool_response.stderr // empty, .tool_response.error // empty, (.tool_response.content // empty | tostring)]
  | map(select(. != null and . != ""))
  | .[0] // ""
' 2>/dev/null | head -c 200 | tr '\n' ' ') || ERR_HINT=""

REMINDER="The last tool call (${TOOL_NAME}) returned an error. Before retrying the same tool or switching to another tool, pause and consider: would a Codex consult answer this faster? Dispatch via the mcp__codex-cli__codex MCP tool with the error context (no model/effort flags — the Codex CLI default of gpt-5.5 + medium reasoning is correct). Codex is especially useful for: opaque MCP errors, command failures you've seen before, 'Unable to...' messages, and any time the next step isn't obvious. If the error is clearly trivial (typo, wrong path you already know), ignore this and proceed. This reminder is throttled to once per 10 minutes per session."

echo "$NOW_TS" > "$THROTTLE_FILE" 2>/dev/null || true

log_event "fired" "tool error reminder injected" \
  "$(jq -nc --arg tool "$TOOL_NAME" --arg hint "$ERR_HINT" '{tool:$tool, err_hint:$hint}')"

jq -nc \
  --arg ctx "$REMINDER" \
  '{
     continue: true,
     suppressOutput: true,
     hookSpecificOutput: {
       hookEventName: "PostToolUse",
       additionalContext: $ctx
     }
   }'

exit 0
