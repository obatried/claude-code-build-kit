#!/usr/bin/env bash
# Audit-only Stop hook: logs when Claude attempts to stop with pending
# work in a build manifest. Does not block. Matches the pattern of
# ~/.claude/hooks/stop-slash-text-guard.sh (audit-only, logs to JSONL).
#
# Installed 2026-04-23 after a unit-boundary
# "summarize and wait" anti-pattern was observed.

set -euo pipefail

LOG_DIR="$HOME/.claude/analytics"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/pending-work-stops.jsonl"

PAYLOAD=$(cat)
CWD=$(echo "$PAYLOAD" | jq -r '.cwd // empty' 2>/dev/null || echo "")
[[ -z "$CWD" ]] && CWD="$PWD"

# Walk up looking for plan/.build-state.json
MANIFEST=""
D="$CWD"
while [[ "$D" != "/" && "$D" != "$HOME" ]]; do
    if [[ -f "$D/plan/.build-state.json" ]]; then
        MANIFEST="$D/plan/.build-state.json"
        break
    fi
    D="$(dirname "$D")"
done

if [[ -z "$MANIFEST" ]]; then
    exit 0
fi

# Count pending/in-progress chunks
PENDING=$(jq '[.chunks[] | select(.status == "pending" or .status == "in-progress")] | length' "$MANIFEST" 2>/dev/null || echo 0)

if [[ "$PENDING" -gt 0 ]]; then
    TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    echo "{\"ts\":\"$TS\",\"manifest\":\"$MANIFEST\",\"pending\":$PENDING,\"cwd\":\"$CWD\"}" >> "$LOG"
fi

exit 0
