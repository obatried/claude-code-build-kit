#!/bin/bash
# ~/.claude/hooks/codex-plan-review.sh
# Auto-fires Codex review on every Claude Code plan via PostToolUse hook on ExitPlanMode.
# Adapted from cathrynlavery/codex-skill with security patches and gstack integration.
# Informational only — never blocks ExitPlanMode (user sovereignty).

set -uo pipefail

LOG_DIR="$HOME/.claude/analytics"
LOG_FILE="$LOG_DIR/codex-plan-reviews.jsonl"
mkdir -p "$LOG_DIR" 2>/dev/null || true

log_event() {
  local status="$1"
  local note="$2"
  # Use jq to safely encode JSON — note may contain quotes/backslashes/newlines
  # (especially BASH_COMMAND from the ERR trap). Falls back to no-op if jq unavailable.
  if command -v jq >/dev/null 2>&1; then
    jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
           --arg status "$status" \
           --arg note "$note" \
           '{ts:$ts, status:$status, note:$note}' >> "$LOG_FILE" 2>/dev/null || true
  fi
}

# Fail-open ERR trap — never block Claude Code due to hook bugs.
# Use BASH_COMMAND instead of LINENO (LINENO is unreliable in command substitutions on bash 3.2).
trap 'log_event "error" "hook errored: ${BASH_COMMAND:-unknown}"; exit 0' ERR

# Cleanup temp files on any exit (including TERM/HUP/INT — fixes Codex finding #5).
PROMPT_FILE=""
LAST_MSG_FILE=""
cleanup() {
  [ -n "$PROMPT_FILE" ]   && rm -f "$PROMPT_FILE"
  [ -n "$LAST_MSG_FILE" ] && rm -f "$LAST_MSG_FILE"
  return 0  # never let cleanup's exit code trigger ERR trap on bash 3.2
}
trap cleanup EXIT HUP INT TERM

# Read JSON from stdin (Claude Code hook input). Must consume fully to avoid SIGPIPE.
HOOK_INPUT=$(cat)

# Verify required tools
command -v codex >/dev/null 2>&1 || { log_event "skipped" "codex not on PATH"; exit 0; }
command -v jq    >/dev/null 2>&1 || { log_event "skipped" "jq not on PATH";    exit 0; }

# Detect a timeout binary. macOS doesn't ship `timeout`; Homebrew coreutils ships `gtimeout`.
# If neither exists, rely on the outer 180s Claude Code hook timeout.
TIMEOUT_BIN=""
if command -v timeout  >/dev/null 2>&1; then TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT_BIN="gtimeout"
fi

# Extract plan content with fallbacks. NO PLAN.md scanning — too sketchy.
# `|| PLAN_CONTENT=""` swallows jq failures (malformed JSON) so they don't trip ERR trap.
PLAN_CONTENT=$(printf '%s' "$HOOK_INPUT" | jq -r '
  if (.tool_response.plan // empty) != null and (.tool_response.plan // "") != ""
    then .tool_response.plan
  elif (.tool_input.plan // empty) != null and (.tool_input.plan // "") != ""
    then .tool_input.plan
  elif (.tool_response | type) == "string"
    then .tool_response
  else ""
  end
' 2>/dev/null) || PLAN_CONTENT=""

if [[ -z "$PLAN_CONTENT" || "$PLAN_CONTENT" == "null" ]]; then
  log_event "skipped" "no plan content in hook input"
  exit 0
fi

# Build prompt in a temp file (mktemp creates mode 0600 by default — confirmed safe).
PROMPT_FILE=$(mktemp -t codex-plan-review.XXXXXX) || { log_event "error" "mktemp failed"; exit 0; }

cat > "$PROMPT_FILE" <<'PROMPT_HEADER'
IMPORTANT: Do NOT read or execute any files under ~/.claude/, ~/.agents/, .claude/skills/, or agents/. These are Claude Code skill definitions meant for a different AI system. Stay focused on repository code only.

You are reviewing a plan that Claude Code created. Be skeptical. Find the strongest reasons this plan should NOT ship as-is.

Focus on these attack surfaces:
- auth, permissions, tenant isolation, trust boundaries
- data loss, corruption, irreversible state changes
- rollback safety, retries, partial failure, idempotency gaps
- race conditions, ordering assumptions, stale state
- empty-state, null, timeout, degraded dependency behavior
- version skew, schema drift, migration hazards
- observability gaps that would hide failure

Be terse. Report only material findings. No style feedback, no naming nits, no speculative concerns.

Output contract:
- Your FIRST LINE must be exactly one of:
  - ALLOW: <one-line reason>
  - BLOCK: <one-line reason>
- Below the first line, list specific findings with severity (critical/high/medium/low), what could go wrong, and a concrete fix.
- If you cannot find any material concern, return ALLOW with a brief reason.

THE PLAN:
PROMPT_HEADER

# Append plan content via printf %s (literal — no escape interpretation, no shell expansion).
printf '%s' "$PLAN_CONTENT" >> "$PROMPT_FILE"

# Run Codex in read-only sandbox with high reasoning.
# - Read prompt from stdin via `-` (avoids ARG_MAX on long plans).
# - --skip-git-repo-check: hook may run from any cwd; we're reviewing pasted text, not the repo.
# - --output-last-message: writes ONLY the final agent message to a file (no CLI banner, no tool-call noise).
LAST_MSG_FILE=$(mktemp -t codex-plan-review-msg.XXXXXX) || { log_event "error" "mktemp last-msg failed"; exit 0; }

log_event "running" "codex exec started"
START_TIME=$(date +%s)

CODEX_EXIT=0
if [ -n "$TIMEOUT_BIN" ]; then
  "$TIMEOUT_BIN" 170 codex exec \
    -s read-only \
    --skip-git-repo-check \
    --output-last-message "$LAST_MSG_FILE" \
    -c 'model_reasoning_effort="high"' \
    - < "$PROMPT_FILE" >/dev/null 2>&1 || CODEX_EXIT=$?
else
  codex exec \
    -s read-only \
    --skip-git-repo-check \
    --output-last-message "$LAST_MSG_FILE" \
    -c 'model_reasoning_effort="high"' \
    - < "$PROMPT_FILE" >/dev/null 2>&1 || CODEX_EXIT=$?
fi
ELAPSED=$(( $(date +%s) - START_TIME ))

if [[ $CODEX_EXIT -ne 0 ]]; then
  log_event "failed" "codex exit=$CODEX_EXIT elapsed=${ELAPSED}s"
  printf '\n[codex-plan-review] Codex review failed (exit=%s, elapsed=%ss). See %s\n' \
    "$CODEX_EXIT" "$ELAPSED" "$LOG_FILE"
  exit 0
fi

# Read just the agent's final message (clean — no codex CLI banner or tool-call noise).
CODEX_MSG=$(cat "$LAST_MSG_FILE" 2>/dev/null) || CODEX_MSG=""

# Parse first line for ALLOW/BLOCK verdict using parameter expansion (no pipeline/SIGPIPE risk).
FIRST_LINE="${CODEX_MSG%%$'\n'*}"
VERDICT="UNKNOWN"
case "$FIRST_LINE" in
  ALLOW:*) VERDICT="ALLOW" ;;
  BLOCK:*) VERDICT="BLOCK" ;;
esac

log_event "completed" "verdict=$VERDICT elapsed=${ELAPSED}s"

# Display to user — informational only, never blocks ExitPlanMode.
cat <<DISPLAY

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
CODEX SAYS (auto-plan-review · ${ELAPSED}s · verdict: $VERDICT):
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
$CODEX_MSG
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

DISPLAY

exit 0
