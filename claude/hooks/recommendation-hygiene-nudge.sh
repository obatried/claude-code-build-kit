#!/bin/bash
# ~/.claude/hooks/recommendation-hygiene-nudge.sh
# UserPromptSubmit hook: detects recommendation-shaped asks (architecture, tool
# choice, workflow design, build-plan questions) and injects a reminder to run
# the 4-check pre-ship discipline (read source / inventory / substrate / Codex-audit).
# Throttled once per 10 min per session. Informational only — never blocks.
#
# Trigger examples that SHOULD match:
#   "how should we plan X"
#   "what's the best way to build Y"
#   "do we make our own gstack"
#   "what's the play here"
#   "let's design a workflow"
#   "recommend a flow for..."
#
# Trigger examples that should NOT match (normal chat):
#   "build the file"      → plain imperative, no design-ask
#   "design looks off"    → design as noun, no ask
#   "I should push this"  → not a recommendation request

set -uo pipefail

STATE_DIR="$HOME/.claude/state"
LOG_FILE="$HOME/.claude/analytics/recommendation-hygiene-nudge.jsonl"
mkdir -p "$STATE_DIR" "$(dirname "$LOG_FILE")" 2>/dev/null || true

trap 'exit 0' ERR

INPUT=$(cat)

PROMPT=$(echo "$INPUT" | jq -r '.prompt // ""' 2>/dev/null)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null)

[ -z "$PROMPT" ] && exit 0

# Trigger: recommendation-shaped phrases. Case-insensitive. Anchored to
# conjunctions that signal design/ask intent, not bare verbs that appear in
# everyday chat.
TRIGGERS='(how|what) should we|best way to|most effective way|optimal way|what.?s the play|what do you think we should|let.?s (build|make|design|set up|architect)|we should (build|make|design|architect)|do we (build|make|design|fork|adopt)|should we (build|make|design|fork|adopt)|recommend (a|an|the|this|how|what)|architect (a|an|the|this|our|my)|(set up|build|design) (this|a|the|our) (flow|system|pipeline|framework|workflow|tool|infrastructure|stack)|full.?stack thing|end.?to.?end (flow|system|pipeline)|what.?s (the|our|my) play|build (a|this|the|our own) (version|flow|system|framework|pipeline|tool|stack)'

LOWER=$(echo "$PROMPT" | tr '[:upper:]' '[:lower:]')
echo "$LOWER" | grep -qE "$TRIGGERS" || exit 0

# Throttle: once per 10 min per session
THROTTLE_FILE="$STATE_DIR/rec-hygiene-nudge-$SESSION_ID"
NOW=$(date +%s)
if [ -f "$THROTTLE_FILE" ]; then
    LAST=$(cat "$THROTTLE_FILE" 2>/dev/null || echo 0)
    AGE=$((NOW - LAST))
    [ "$AGE" -lt 600 ] && exit 0
fi
echo "$NOW" > "$THROTTLE_FILE"

if command -v jq >/dev/null 2>&1; then
    jq -nc \
       --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       --arg session "$SESSION_ID" \
       --arg matched_prompt "$(echo "$PROMPT" | head -c 240)" \
       '{ts:$ts, session:$session, matched_prompt:$matched_prompt}' \
       >> "$LOG_FILE" 2>/dev/null || true
fi

cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "[RECOMMENDATION HYGIENE REMINDER] This looks like a recommendation-shaped ask (architecture, tool choice, workflow design, build plan). Before shipping a multi-step response run these 4 checks: (1) Read the source of every tool/skill/file you cite — not sub-agent summaries. CLAUDE.md §6 test: name one specific detail from source that a README-only reader wouldn't know. (2) Inventory existing tooling before proposing new pieces: ls ~/.claude/skills/ && ls ~/.claude/commands/ && ls ~/.claude/scripts/ && ls ~/.claude/hooks/. Duplicates are disqualifying. (3) Solve SUBSTRATE before CEREMONY: where does it run (laptop/server/cloud)? hard cost ceiling? sandbox/isolation? failure/resume story? validation bar beyond tsc? Ceremony on unsolved substrate is process theater. (4) For multi-step design specs (≥3 components or workflow proposal): Codex-audit before shipping the recommendation to the user, not after — the user's pushback should not be the first audit. When the checks pass, put a visible 'Verified:' line at the top of the response. Throttled to once per 10 min per session."
  }
}
EOF
