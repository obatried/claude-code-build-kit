# >>> claude-code-build-kit: handoff pickup >>>
# Cooperator block for ~/.claude/handoff-v3.sh. When a previous Claude session
# wrote a prompt under ~/.claude/state/handoff/ within the last 120s, AND that
# prompt is owned by the current user, this block reads it and exec's a fresh
# `claude` session with it.
#
# Why ~/.claude/state/handoff/ instead of /tmp:
#   /tmp is world-readable and predictable. We use a private 700 dir under
#   $HOME so other users can't plant prompts that auto-launch a claude
#   session here.
#
# Idempotent: detected by the >>> claude-code-build-kit marker line above.
# Remove that line and this whole block to disable.
if [[ -z "$CLAUDE_CODE" ]]; then
  _CCBK_HANDOFF_DIR="$HOME/.claude/state/handoff"
  _CCBK_PROMPT="$_CCBK_HANDOFF_DIR/next-handoff.txt"
  _CCBK_DIR_F="$_CCBK_HANDOFF_DIR/next-handoff-dir.txt"
  if [[ -f "$_CCBK_PROMPT" ]]; then
    # Owner check — only proceed if the file is owned by us. Belt + suspenders
    # against a 700 dir already protecting us.
    if [[ -O "$_CCBK_PROMPT" ]]; then
      # Cross-platform mtime: GNU stat uses -c %Y, BSD/Darwin uses -f %m.
      if [[ "$(uname -s)" == "Darwin" ]]; then
        _CCBK_MTIME=$(stat -f %m "$_CCBK_PROMPT" 2>/dev/null)
      else
        _CCBK_MTIME=$(stat -c %Y "$_CCBK_PROMPT" 2>/dev/null)
      fi
      if [[ -n "$_CCBK_MTIME" && $(($(date +%s) - _CCBK_MTIME)) -lt 120 ]]; then
        _prompt=$(cat "$_CCBK_PROMPT")
        _dir="$HOME"
        [[ -f "$_CCBK_DIR_F" && -O "$_CCBK_DIR_F" ]] && _dir=$(cat "$_CCBK_DIR_F")
        rm -f "$_CCBK_PROMPT" "$_CCBK_DIR_F"
        unset _CCBK_HANDOFF_DIR _CCBK_PROMPT _CCBK_DIR_F _CCBK_MTIME
        cd "$_dir" && exec claude --permission-mode auto "$_prompt"
      else
        rm -f "$_CCBK_PROMPT" "$_CCBK_DIR_F"
      fi
    fi
  fi
  unset _CCBK_HANDOFF_DIR _CCBK_PROMPT _CCBK_DIR_F _CCBK_MTIME
fi
# <<< claude-code-build-kit: handoff pickup <<<
