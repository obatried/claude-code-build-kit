#!/bin/bash
# Claude Code session handoff v3 — cooperates with .zshrc auto-start.
# Drops the prompt + working-dir into a private state dir under
# ~/.claude/state/handoff/ (mode 700, files 600), then opens a fresh Terminal
# tab. The .zshrc handoff-pickup block reads those files, verifies they're
# owned by the current user, and launches `claude` with the prompt.
#
# Why ~/.claude/state/handoff/ instead of /tmp:
#   - /tmp is world-readable and predictable. Any local process could plant
#     a prompt and trigger an auto-permission claude session.
#   - ~/.claude/state/handoff/ is 700 — only this user can read or write.
#
# Requires a matching block in ~/.zshrc (see zshrc-snippet.sh).
#
# Usage: ~/.claude/handoff-v3.sh /path/to/prompt-file.txt [working-directory]

set -uo pipefail

PROMPT_FILE="${1:?Usage: handoff-v3.sh <prompt-file> [working-dir]}"
WORK_DIR="${2:-$PWD}"

if [ ! -f "$PROMPT_FILE" ]; then
  echo "Error: Prompt file not found: $PROMPT_FILE" >&2
  exit 1
fi

if [ ! -d "$WORK_DIR" ]; then
  echo "Error: Working directory not found: $WORK_DIR" >&2
  exit 1
fi

# Private state dir
HANDOFF_DIR="$HOME/.claude/state/handoff"
mkdir -p "$HANDOFF_DIR"
chmod 700 "$HANDOFF_DIR"

PROMPT_DEST="$HANDOFF_DIR/next-handoff.txt"
DIR_DEST="$HANDOFF_DIR/next-handoff-dir.txt"

# Write atomically with restrictive umask so the new file is mode 600
(
  umask 077
  cp "$PROMPT_FILE" "$PROMPT_DEST"
  printf '%s' "$WORK_DIR" > "$DIR_DEST"
)
chmod 600 "$PROMPT_DEST" "$DIR_DEST" 2>/dev/null || true

# macOS only: open a fresh Terminal tab. Terminal.app new tabs inherit env
# vars from the parent process — if claude is running in the parent,
# CLAUDE_CODE=1 leaks in and the .zshrc auto-launch block (gated on
# `[[ -z "$CLAUDE_CODE" ]]`) gets skipped, leaving the tab at a bare shell.
# Fix: `do script` explicitly unsets the CLAUDE_CODE family, then execs a
# fresh login zsh. That triggers .zshrc with a clean env, which runs the
# pickup block and launches claude with the handoff prompt.
case "$(uname -s)" in
  Darwin)
    osascript <<'APPLESCRIPT'
tell application "Terminal"
  activate
  do script "unset CLAUDE_CODE CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS CLAUDE_CODE_EXECPATH; exec zsh -l"
end tell
APPLESCRIPT
    ;;
  *)
    echo "Note: auto-tab-spawn only works on macOS." >&2
    echo "On Linux, open a new terminal manually within 120s — the .zshrc pickup will fire." >&2
    ;;
esac

echo "Handoff staged (working dir: $WORK_DIR)"
