#!/usr/bin/env bash
# claude-code-build-kit installer.
#
# Idempotent. Backs up your existing ~/.claude/ before touching anything.
# See INSTALL.md for what this does, how to manual-install, and how to undo.

set -euo pipefail

# ─── Style ──────────────────────────────────────────────────────────────────
say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!! %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mERR:\033[0m %s\n' "$*" >&2; exit 1; }

# ─── Locate kit ─────────────────────────────────────────────────────────────
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -d "$KIT_DIR/claude" ] || die "Kit dir not found: $KIT_DIR/claude"

# ─── Hard deps ──────────────────────────────────────────────────────────────
say "Checking hard dependencies..."
for cmd in codex jq git bash; do
  command -v "$cmd" >/dev/null 2>&1 || die "Missing required command: $cmd"
done

# ─── Soft deps ──────────────────────────────────────────────────────────────
command -v gstack >/dev/null 2>&1 || warn "gstack not found — /build's QA + design steps will degrade. Install: see https://github.com/anthropics/gstack"

# ─── Backup ─────────────────────────────────────────────────────────────────
TS=$(date +%Y%m%d-%H%M%S)
if [ -d "$HOME/.claude" ]; then
  BACKUP="$HOME/.claude.bak.$TS"
  say "Backing up existing ~/.claude → $BACKUP"
  cp -R "$HOME/.claude" "$BACKUP"
fi

# ─── Copy files ─────────────────────────────────────────────────────────────
say "Installing files..."
mkdir -p "$HOME/.claude/skills/build" \
         "$HOME/.claude/scripts/build-manifest" \
         "$HOME/.claude/hooks" \
         "$HOME/.claude/analytics"

# Philosophy
cp "$KIT_DIR/claude/CLAUDE.md"             "$HOME/.claude/CLAUDE.md"
cp "$KIT_DIR/claude/CLAUDE_MAINTENANCE.md" "$HOME/.claude/CLAUDE_MAINTENANCE.md"
cp "$KIT_DIR/claude/CLAUDE_MAP.md"         "$HOME/.claude/CLAUDE_MAP.md"

# Skill
cp "$KIT_DIR/claude/skills/build/SKILL.md" "$HOME/.claude/skills/build/SKILL.md"

# Scripts
cp "$KIT_DIR/claude/scripts/build-manifest/manifest.sh" "$HOME/.claude/scripts/build-manifest/manifest.sh"
cp "$KIT_DIR/claude/scripts/codex-commit-review.sh"     "$HOME/.claude/scripts/codex-commit-review.sh"
# `cp -R src dst` nests src into dst on a second run when dst already exists.
# Wipe the target and copy the contents to make this idempotent.
rm -rf "$HOME/.claude/scripts/codex-commit-review.prompts"
mkdir -p "$HOME/.claude/scripts/codex-commit-review.prompts"
cp -R "$KIT_DIR/claude/scripts/codex-commit-review.prompts/." "$HOME/.claude/scripts/codex-commit-review.prompts/"
cp "$KIT_DIR/claude/scripts/vibecop-adjudicate.sh"      "$HOME/.claude/scripts/vibecop-adjudicate.sh"
cp "$KIT_DIR/claude/scripts/vibecop-adjudicate-heavy.sh" "$HOME/.claude/scripts/vibecop-adjudicate-heavy.sh"
cp "$KIT_DIR/claude/scripts/gave-up-early-review.sh"    "$HOME/.claude/scripts/gave-up-early-review.sh"

# Hooks
for h in codex-plan-review codex-commit-review-on-commit codex-tool-error-reminder \
         vibecop-on-edit stuck-detector gave-up-early-guard \
         stop-slash-text-guard stop-pending-work-guard recommendation-hygiene-nudge; do
  cp "$KIT_DIR/claude/hooks/$h.sh" "$HOME/.claude/hooks/$h.sh"
done

# Handoff
cp "$KIT_DIR/claude/handoff-v3.sh" "$HOME/.claude/handoff-v3.sh"

# Permissions
chmod +x "$HOME/.claude/handoff-v3.sh"
chmod +x "$HOME/.claude/scripts"/*.sh
chmod +x "$HOME/.claude/scripts/build-manifest"/*.sh
chmod +x "$HOME/.claude/hooks"/*.sh

# ─── Settings.json merge ────────────────────────────────────────────────────
SETTINGS="$HOME/.claude/settings.json"
TEMPLATE="$KIT_DIR/claude/settings.template.json"
KIT_HOOK_MARKER="codex-plan-review.sh"

if [ ! -f "$SETTINGS" ]; then
  say "Installing ~/.claude/settings.json from template..."
  cp "$TEMPLATE" "$SETTINGS"
elif grep -q "$KIT_HOOK_MARKER" "$SETTINGS" 2>/dev/null; then
  say "Kit hooks already wired in ~/.claude/settings.json — skipping merge."
else
  say "Merging kit hooks into existing ~/.claude/settings.json..."
  TMP=$(mktemp)
  # Per-event-type concatenation: append the kit's PostToolUse / UserPromptSubmit /
  # Stop arrays to whatever the user already has. We do not dedupe object-equal
  # entries because settings hook blocks are intentionally additive — if the
  # user has their own ExitPlanMode hook, both will fire.
  jq -s '
    .[0] as $existing | .[1] as $kit |
    $existing
    | (.hooks // {}) as $eh
    | (.hooks = (
        $eh
        | .PostToolUse      = (($eh.PostToolUse      // []) + ($kit.hooks.PostToolUse      // []))
        | .UserPromptSubmit = (($eh.UserPromptSubmit // []) + ($kit.hooks.UserPromptSubmit // []))
        | .Stop             = (($eh.Stop             // []) + ($kit.hooks.Stop             // []))
        | .PreToolUse       = (($eh.PreToolUse       // []) + ($kit.hooks.PreToolUse       // []))
      ))
  ' "$SETTINGS" "$TEMPLATE" > "$TMP" && mv "$TMP" "$SETTINGS"
fi

# ─── Codex config ───────────────────────────────────────────────────────────
mkdir -p "$HOME/.codex"
if [ ! -f "$HOME/.codex/config.toml" ]; then
  say "Installing Codex defaults at ~/.codex/config.toml (gpt-5.5 + medium)..."
  cp "$KIT_DIR/codex-config.template.toml" "$HOME/.codex/config.toml"
else
  warn "~/.codex/config.toml already exists — leaving it. Confirm it has model='gpt-5.5' + reasoning='medium' or the kit's scripts will use whatever's there."
fi

# ─── zshrc snippet ──────────────────────────────────────────────────────────
ZSHRC="$HOME/.zshrc"
MARKER=">>> claude-code-build-kit: handoff pickup >>>"
if [ -f "$ZSHRC" ] && grep -qF "$MARKER" "$ZSHRC"; then
  say "Handoff pickup block already present in ~/.zshrc — skipping."
else
  say "Appending handoff pickup block to ~/.zshrc..."
  printf '\n' >> "$ZSHRC"
  cat "$KIT_DIR/zshrc-snippet.sh" >> "$ZSHRC"
fi

# ─── Smoke test ─────────────────────────────────────────────────────────────
say "Smoke testing..."
"$HOME/.claude/scripts/build-manifest/manifest.sh" --help >/dev/null 2>&1 \
  || "$HOME/.claude/scripts/build-manifest/manifest.sh" 2>&1 | head -1 >/dev/null \
  || warn "manifest.sh smoke test inconclusive — check it manually."

say "Done."
echo
echo "Next steps:"
echo "  1. Restart your shell (or 'source ~/.zshrc')"
echo "  2. Verify Codex defaults: codex exec --skip-git-repo-check 'Reply with model name.'"
echo "  3. In a project: try /build to invoke the orchestrator."
echo
[ -n "${BACKUP:-}" ] && echo "Your previous ~/.claude/ is backed up at: $BACKUP"
