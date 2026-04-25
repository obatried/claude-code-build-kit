#!/bin/bash
# ~/.claude/scripts/vibecop-adjudicate.sh
#
# Light adjudicator for vibecop findings. Reads vibecop output from stdin,
# takes the target file path as $1, classifies each finding as REAL or NOISE
# via a single Codex call, and appends a tag line to the output.
#
# If the finding/file touches security/data/auth/payment/architecture
# keywords, the light path short-circuits to REAL (default-deny on high
# stakes) AND launches the heavy adjudicator in the background for a
# richer multi-round analysis that Claude can read later.
#
# Never blocks; all errors fail-open with the original output intact.
#
# Usage:
#   printf '%s' "$VIBECOP_OUTPUT" | vibecop-adjudicate.sh <file-path>

set -uo pipefail

FILE_PATH="${1:-}"
LOG_DIR="$HOME/.claude/analytics"
LOG_FILE="$LOG_DIR/vibecop-adjudications.jsonl"
HEAVY_SCRIPT="${HEAVY_SCRIPT:-$HOME/.claude/scripts/vibecop-adjudicate-heavy.sh}"
CODEX_BIN="${CODEX_BIN:-codex}"
mkdir -p "$LOG_DIR" 2>/dev/null || true

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

# Fail-open on any error — print whatever input was there and exit 0.
INPUT=$(cat)
trap 'printf "%s\n" "$INPUT"; log_event "error" "adjudicator errored: ${BASH_COMMAND:-unknown}"; exit 0' ERR

if [ -z "$INPUT" ]; then
  # Nothing to adjudicate
  exit 0
fi

# If Codex or jq unavailable, pass through untagged.
if ! command -v "$CODEX_BIN" >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  printf '%s\n' "$INPUT"
  log_event "skipped" "codex or jq missing"
  exit 0
fi

# Heavy-mode keyword detection. Run on (input text + file path).
HAYSTACK="$INPUT $FILE_PATH"
HEAVY=0
if printf '%s' "$HAYSTACK" | grep -qiE '\b(security|secret|token|auth|password|payment|billing|stripe|webhook|admin|migration|schema|injection|csrf|xss|race|deadlock|unchecked-db|data-integrity|architecture|tenant)\b'; then
  HEAVY=1
fi

# ─── Heavy path: default REAL + launch background adjudicator ────────────────
if [ "$HEAVY" = "1" ]; then
  log_event "heavy-triggered" "high-stakes keyword — defaulting REAL and launching heavy adjudicator"
  # Launch heavy in background, passing input via a temp file (since we can't
  # pipe stdin into a detached nohup reliably).
  if [ -x "$HEAVY_SCRIPT" ]; then
    HEAVY_TMP=$(mktemp -t vibecop-heavy.XXXXXX) || HEAVY_TMP=""
    if [ -n "$HEAVY_TMP" ]; then
      printf '%s' "$INPUT" > "$HEAVY_TMP"
      BG_LOG="$LOG_DIR/vibecop-heavy-bg.log"
      nohup bash -c "'$HEAVY_SCRIPT' '$FILE_PATH' < '$HEAVY_TMP' >> '$BG_LOG' 2>&1; rm -f '$HEAVY_TMP'" </dev/null >/dev/null 2>&1 &
      disown 2>/dev/null || true
    fi
  fi
  printf '%s\n' "$INPUT"
  printf '[CODEX: REAL — high-stakes keyword; heavy adjudication running in background, result will appear in ~/.claude/analytics/vibecop-heavy-adjudications.jsonl]\n'
  exit 0
fi

# ─── Light path: single synchronous Codex call ───────────────────────────────

TIMEOUT_BIN=""
if command -v timeout  >/dev/null 2>&1; then TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT_BIN="gtimeout"
fi

PROMPT_FILE=$(mktemp -t vibecop-light.XXXXXX) || { printf '%s\n' "$INPUT"; exit 0; }
LAST_MSG=$(mktemp -t vibecop-light-msg.XXXXXX) || { rm -f "$PROMPT_FILE"; printf '%s\n' "$INPUT"; exit 0; }
trap 'rm -f "$PROMPT_FILE" "$LAST_MSG"' EXIT HUP INT TERM

cat > "$PROMPT_FILE" <<EOF
You are classifying a vibecop lint finding. vibecop is a project-local linter
for JS/TS/Python; its findings are often noisy (false positives from stylistic
rules) but sometimes catch real bugs.

File: $FILE_PATH

Finding:
$INPUT

Your job: classify this finding as REAL (a bug worth fixing before moving on)
or NOISE (safe to ignore).

Output contract — your FIRST LINE must be exactly one of:
  REAL: <one-sentence reason, what could break>
  NOISE: <one-sentence reason, why this is a style/false-positive>

Be terse. No preamble, no markdown headings. Only the one line.
EOF

START=$(date +%s)
EXIT=0
if [ -n "$TIMEOUT_BIN" ]; then
  "$TIMEOUT_BIN" 45 "$CODEX_BIN" exec \
    -s read-only \
    --skip-git-repo-check \
    --output-last-message "$LAST_MSG" \
    -c 'model_reasoning_effort="medium"' \
    - < "$PROMPT_FILE" >/dev/null 2>&1 || EXIT=$?
else
  "$CODEX_BIN" exec \
    -s read-only \
    --skip-git-repo-check \
    --output-last-message "$LAST_MSG" \
    -c 'model_reasoning_effort="medium"' \
    - < "$PROMPT_FILE" >/dev/null 2>&1 || EXIT=$?
fi
ELAPSED=$(( $(date +%s) - START ))

if [ "$EXIT" -ne 0 ]; then
  printf '%s\n' "$INPUT"
  printf '[CODEX: adjudication failed — exit=%s, elapsed=%ss; use judgment]\n' "$EXIT" "$ELAPSED"
  log_event "failed" "light codex exit=$EXIT" \
    "$(jq -nc --arg exit "$EXIT" --argjson elapsed "$ELAPSED" '{exit_code:$exit, elapsed_s:$elapsed}')"
  exit 0
fi

VERDICT_TEXT=$(cat "$LAST_MSG" 2>/dev/null) || VERDICT_TEXT=""
# Trim leading whitespace
while [ -n "$VERDICT_TEXT" ]; do
  c="${VERDICT_TEXT:0:1}"
  case "$c" in ' '|$'\t'|$'\n'|$'\r') VERDICT_TEXT="${VERDICT_TEXT:1}" ;; *) break ;; esac
done
FIRST_LINE="${VERDICT_TEXT%%$'\n'*}"

case "$FIRST_LINE" in
  REAL:*)  TAG="[CODEX: REAL — recommend fix | ${FIRST_LINE#REAL:}]" ; VERDICT="REAL" ;;
  NOISE:*) TAG="[CODEX: NOISE — ignore | ${FIRST_LINE#NOISE:}]"      ; VERDICT="NOISE" ;;
  *)       TAG="[CODEX: UNKNOWN verdict — use judgment | $FIRST_LINE]" ; VERDICT="UNKNOWN" ;;
esac

printf '%s\n' "$INPUT"
printf '%s\n' "$TAG"

log_event "completed" "light verdict=$VERDICT elapsed=${ELAPSED}s" \
  "$(jq -nc --arg verdict "$VERDICT" --argjson elapsed "$ELAPSED" --arg first "$FIRST_LINE" \
    '{verdict:$verdict, elapsed_s:$elapsed, first_line:$first}')"

exit 0
