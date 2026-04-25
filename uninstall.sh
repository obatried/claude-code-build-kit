#!/usr/bin/env bash
# claude-code-build-kit uninstaller.
#
# Restores the most recent ~/.claude.bak.<ts> backup, removes the zshrc
# snippet, and (if the Codex config matches the kit's template byte-for-byte)
# removes ~/.codex/config.toml. Anything else is left alone.

set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!! %s\033[0m\n' "$*" >&2; }

# Restore most recent backup if present
LATEST_BACKUP=$(ls -1d "$HOME"/.claude.bak.* 2>/dev/null | sort | tail -1 || true)
if [ -n "$LATEST_BACKUP" ] && [ -d "$LATEST_BACKUP" ]; then
  say "Restoring ~/.claude from $LATEST_BACKUP"
  rm -rf "$HOME/.claude"
  cp -R "$LATEST_BACKUP" "$HOME/.claude"
else
  warn "No backup found at ~/.claude.bak.* — your installed kit will not be removed automatically. Manually remove ~/.claude/skills/build, ~/.claude/scripts/{build-manifest,codex-commit-review*,vibecop-adjudicate*}, and the kit's hooks."
fi

# Codex config: only remove if it matches the kit's template byte-for-byte
if [ -f "$HOME/.codex/config.toml" ] && cmp -s "$HOME/.codex/config.toml" "$KIT_DIR/codex-config.template.toml"; then
  say "Removing ~/.codex/config.toml (matches kit template)"
  rm "$HOME/.codex/config.toml"
fi

# zshrc snippet — remove the marked block
ZSHRC="$HOME/.zshrc"
START_MARK="# >>> claude-code-build-kit: handoff pickup >>>"
END_MARK="# <<< claude-code-build-kit: handoff pickup <<<"
if [ -f "$ZSHRC" ] && grep -qF "$START_MARK" "$ZSHRC"; then
  say "Removing handoff pickup block from ~/.zshrc"
  TMP=$(mktemp)
  awk -v s="$START_MARK" -v e="$END_MARK" '
    $0 == s { skip=1; next }
    $0 == e { skip=0; next }
    !skip { print }
  ' "$ZSHRC" > "$TMP" && mv "$TMP" "$ZSHRC"
fi

say "Done. Restart your shell."
