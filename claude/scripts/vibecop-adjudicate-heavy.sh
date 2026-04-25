#!/bin/bash
# ~/.claude/scripts/vibecop-adjudicate-heavy.sh
#
# Heavy adjudicator for vibecop findings on high-stakes files (security, data,
# auth, payment, architecture). Runs up to 3 rounds of Codex with adversarial
# prompts, logs each round's verdict, and writes a final consolidated entry to
# ~/.claude/analytics/vibecop-heavy-adjudications.jsonl.
#
# Designed to run in the background — printed output goes to a log file, not
# to Claude's context.
#
# Usage:
#   vibecop-adjudicate-heavy.sh <file-path> < <vibecop-output>

set -uo pipefail

FILE_PATH="${1:-}"
LOG_DIR="$HOME/.claude/analytics"
LOG_FILE="$LOG_DIR/vibecop-heavy-adjudications.jsonl"
STATE_DIR_ROOT="$HOME/.claude/state/vibecop-heavy"
CODEX_BIN="${CODEX_BIN:-codex}"
mkdir -p "$LOG_DIR" "$STATE_DIR_ROOT" 2>/dev/null || true

log_event() {
  local status="$1"; local note="$2"; local extras="${3:-}"
  [ -z "$extras" ] && extras="{}"
  if command -v jq >/dev/null 2>&1; then
    jq -nc \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg status "$status" \
      --arg note "$note" \
      --arg file "$FILE_PATH" \
      --argjson extras "$extras" \
      '{ts:$ts, status:$status, note:$note, file:$file} + $extras' \
      >> "$LOG_FILE" 2>/dev/null || true
  fi
}

trap 'log_event "error" "heavy errored: ${BASH_COMMAND:-unknown}"; exit 0' ERR

INPUT=$(cat)
[ -z "$INPUT" ] && { log_event "skipped" "no input"; exit 0; }

command -v "$CODEX_BIN" >/dev/null 2>&1 || { log_event "skipped" "codex missing"; exit 0; }
command -v jq >/dev/null 2>&1 || { log_event "skipped" "jq missing"; exit 0; }

TIMEOUT_BIN=""
if command -v timeout  >/dev/null 2>&1; then TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT_BIN="gtimeout"
fi

TS=$(date +%Y%m%d-%H%M%S)
STATE_DIR="$STATE_DIR_ROOT/${TS}-${$}"
mkdir -p "$STATE_DIR" 2>/dev/null || true

run_round() {
  local round_num="$1"
  local prompt_file="$2"
  local out_file="$STATE_DIR/round-${round_num}.out"
  local exit_code=0
  if [ -n "$TIMEOUT_BIN" ]; then
    "$TIMEOUT_BIN" 180 "$CODEX_BIN" exec \
      -s read-only \
      --skip-git-repo-check \
      --output-last-message "$out_file" \
      -c 'model_reasoning_effort="high"' \
      - < "$prompt_file" >/dev/null 2>&1 || exit_code=$?
  else
    "$CODEX_BIN" exec \
      -s read-only \
      --skip-git-repo-check \
      --output-last-message "$out_file" \
      -c 'model_reasoning_effort="high"' \
      - < "$prompt_file" >/dev/null 2>&1 || exit_code=$?
  fi
  echo "$exit_code" > "$STATE_DIR/round-${round_num}.exit"
  return $exit_code
}

# ─── Round 1: primary adjudication ────────────────────────────────────────────
R1_PROMPT="$STATE_DIR/round-1.prompt"
cat > "$R1_PROMPT" <<EOF
You are adjudicating a vibecop lint finding on a HIGH-STAKES file. The file
touches security / data / auth / payment / architecture concerns, so the cost
of a false negative (missing a real bug) is high.

File: $FILE_PATH

Finding:
$INPUT

Your job: is this finding REAL or NOISE? Give a considered first-round POV.

Output contract — FIRST LINE must be exactly one of:
  REAL: <one-sentence reason, what could break>
  NOISE: <one-sentence reason, why this is safe>
Then below, 2-4 additional lines on severity, blast radius, and recommended fix.
EOF

START=$(date +%s)
R1_EXIT=0
run_round 1 "$R1_PROMPT" || R1_EXIT=$?
R1_TEXT=$(cat "$STATE_DIR/round-1.out" 2>/dev/null) || R1_TEXT=""
R1_FIRST="${R1_TEXT%%$'\n'*}"
case "$R1_FIRST" in
  REAL:*) R1_VERDICT=REAL ;;
  NOISE:*) R1_VERDICT=NOISE ;;
  *) R1_VERDICT=UNKNOWN ;;
esac

if [ "$R1_EXIT" -ne 0 ] || [ "$R1_VERDICT" = "UNKNOWN" ]; then
  log_event "failed-r1" "round 1 failed or unparseable" \
    "$(jq -nc --arg exit "$R1_EXIT" --arg verdict "$R1_VERDICT" '{round:1, exit_code:$exit, verdict:$verdict}')"
  exit 0
fi

# ─── Round 2: adversarial counter-POV ────────────────────────────────────────
R2_PROMPT="$STATE_DIR/round-2.prompt"
cat > "$R2_PROMPT" <<EOF
You are adjudicating the SAME vibecop finding as a colleague already reviewed.
Your colleague's round-1 POV is below. Form an INDEPENDENT second opinion —
argue AGAINST their verdict if there are any reasonable grounds. Don't rubber-stamp.

File: $FILE_PATH

Original finding:
$INPUT

Round-1 colleague POV:
$R1_TEXT

Output contract — FIRST LINE must be exactly one of:
  REAL: <one-sentence reason>
  NOISE: <one-sentence reason>
Then 2-4 lines defending your position against the round-1 view.
EOF

R2_EXIT=0
run_round 2 "$R2_PROMPT" || R2_EXIT=$?
R2_TEXT=$(cat "$STATE_DIR/round-2.out" 2>/dev/null) || R2_TEXT=""
R2_FIRST="${R2_TEXT%%$'\n'*}"
case "$R2_FIRST" in
  REAL:*) R2_VERDICT=REAL ;;
  NOISE:*) R2_VERDICT=NOISE ;;
  *) R2_VERDICT=UNKNOWN ;;
esac

# Converged after 2 rounds?
if [ "$R1_VERDICT" = "$R2_VERDICT" ] && [ "$R2_VERDICT" != "UNKNOWN" ]; then
  ELAPSED=$(( $(date +%s) - START ))
  log_event "converged" "both rounds agree: $R1_VERDICT" \
    "$(jq -nc --arg verdict "$R1_VERDICT" --argjson elapsed "$ELAPSED" --arg state "$STATE_DIR" \
      '{rounds:2, verdict:$verdict, elapsed_s:$elapsed, state_dir:$state}')"
  exit 0
fi

# Disagreement or round 2 unparseable → round 3 (research-oriented)
R3_PROMPT="$STATE_DIR/round-3.prompt"
cat > "$R3_PROMPT" <<EOF
Round 1 and round 2 disagreed on this vibecop finding. Act as a tie-breaker:
think hard, consider the specific language/framework idioms, and consider
whether the class of bug being flagged actually reaches exploitability in
real code paths. Use your reasoning budget liberally.

File: $FILE_PATH

Original finding:
$INPUT

Round 1:
$R1_TEXT

Round 2:
$R2_TEXT

Output contract — FIRST LINE must be exactly one of:
  REAL: <decisive one-sentence reason>
  NOISE: <decisive one-sentence reason>
  UNRESOLVED: <one-sentence why a human should decide>
Then 3-6 lines synthesizing.
EOF

R3_EXIT=0
run_round 3 "$R3_PROMPT" || R3_EXIT=$?
R3_TEXT=$(cat "$STATE_DIR/round-3.out" 2>/dev/null) || R3_TEXT=""
R3_FIRST="${R3_TEXT%%$'\n'*}"
case "$R3_FIRST" in
  REAL:*) R3_VERDICT=REAL ;;
  NOISE:*) R3_VERDICT=NOISE ;;
  UNRESOLVED:*) R3_VERDICT=UNRESOLVED ;;
  *) R3_VERDICT=UNKNOWN ;;
esac

ELAPSED=$(( $(date +%s) - START ))
log_event "resolved" "3-round tiebreak verdict=$R3_VERDICT" \
  "$(jq -nc --arg r1 "$R1_VERDICT" --arg r2 "$R2_VERDICT" --arg r3 "$R3_VERDICT" \
    --argjson elapsed "$ELAPSED" --arg state "$STATE_DIR" \
    '{rounds:3, round_1:$r1, round_2:$r2, round_3:$r3, verdict:$r3, elapsed_s:$elapsed, state_dir:$state}')"

exit 0
