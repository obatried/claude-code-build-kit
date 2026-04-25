#!/bin/bash
# ~/.claude/hooks/vibecop-on-edit.sh
# PostToolUse hook on Edit|Write|MultiEdit. Runs vibecop on the edited file
# (only if that repo has vibecop installed locally). Informational; never blocks.
# Empty output = clean file. Any output surfaces findings back to Claude.

set -uo pipefail

HOOK_INPUT=$(cat)

command -v jq >/dev/null 2>&1 || exit 0
command -v npx >/dev/null 2>&1 || exit 0

TOOL_NAME=$(printf '%s' "$HOOK_INPUT" | jq -r '.tool_name // empty' 2>/dev/null) || exit 0
FILE_PATH=$(printf '%s' "$HOOK_INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null) || exit 0

[ -z "$FILE_PATH" ] && exit 0
[ ! -f "$FILE_PATH" ] && exit 0

case "$FILE_PATH" in
  *.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs|*.py) ;;
  *) exit 0 ;;
esac

# Walk up from the file to find a .vibecop.yml. If none, exit silently.
DIR=$(dirname "$FILE_PATH")
REPO_ROOT=""
while [ "$DIR" != "/" ] && [ -n "$DIR" ]; do
  if [ -f "$DIR/.vibecop.yml" ]; then
    REPO_ROOT="$DIR"
    break
  fi
  DIR=$(dirname "$DIR")
done

[ -z "$REPO_ROOT" ] && exit 0

# Verify vibecop is installed locally in that repo
[ ! -d "$REPO_ROOT/node_modules/vibecop" ] && exit 0

# Scan only the edited file, agent format
REL_PATH=$(python3 -c "import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))" "$FILE_PATH" "$REPO_ROOT" 2>/dev/null) || exit 0

# Use gtimeout if available (coreutils), otherwise run without timeout
if command -v gtimeout >/dev/null 2>&1; then
  OUTPUT=$(cd "$REPO_ROOT" && echo "$REL_PATH" | gtimeout 10 npx vibecop scan --stdin-files --format agent 2>/dev/null) || true
else
  OUTPUT=$(cd "$REPO_ROOT" && echo "$REL_PATH" | npx vibecop scan --stdin-files --format agent 2>/dev/null) || true
fi

# Filter to errors only (warnings/info are too noisy pre-triage)
ERRORS=$(printf '%s\n' "$OUTPUT" | grep -E ' error [a-z-]+:' || true)

if [ -n "$ERRORS" ]; then
  FINDING_BLOCK=$(printf 'vibecop errors on %s:\n%s\n' "$REL_PATH" "$ERRORS")
  ADJUDICATOR="$HOME/.claude/scripts/vibecop-adjudicate.sh"
  if [ -x "$ADJUDICATOR" ]; then
    # Pipe through the adjudicator. It fails-open: on any error it prints
    # the input block untagged, so we never lose the finding.
    printf '%s' "$FINDING_BLOCK" | "$ADJUDICATOR" "$FILE_PATH"
  else
    printf '%s\n' "$FINDING_BLOCK"
  fi
fi

exit 0
