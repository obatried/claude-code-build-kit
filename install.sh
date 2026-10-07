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

# ─── settings.json writes ───────────────────────────────────────────────────
# Every rewrite goes through a temp file that is validated, then copied INTO
# the existing file (`cat >`), so a symlinked settings.json stays a symlink and
# the change lands in its target. The trap removes the temp file on every exit.
SETTINGS="$HOME/.claude/settings.json"
SETTINGS_TMP=""
cleanup_tmp() { if [ -n "$SETTINGS_TMP" ]; then rm -f "$SETTINGS_TMP"; fi; }
trap cleanup_tmp EXIT
write_settings() {
  jq -e 'type == "object"' "$SETTINGS_TMP" >/dev/null 2>&1 \
    || die "refusing to write ~/.claude/settings.json: the new content is not a JSON object"
  cat "$SETTINGS_TMP" > "$SETTINGS"
  rm -f "$SETTINGS_TMP"; SETTINGS_TMP=""
}

# ─── Locate kit ─────────────────────────────────────────────────────────────
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -d "$KIT_DIR/claude" ] || die "Kit dir not found: $KIT_DIR/claude"

# ─── Hard deps ──────────────────────────────────────────────────────────────
say "Checking hard dependencies..."
for cmd in codex jq git bash; do
  command -v "$cmd" >/dev/null 2>&1 || die "Missing required command: $cmd"
done

# ─── Soft deps ──────────────────────────────────────────────────────────────
[ -d "$HOME/.claude/skills/gstack" ] || [ -d "$HOME/.agents/skills/gstack" ] || warn "gstack not found — /build's QA steps will degrade to a manual smoke test. Install: see https://github.com/garrytan/gstack"

# ─── settings.json shape check ──────────────────────────────────────────────
# Runs before the backup, the cleanup and any copy: if the existing settings.json
# is not a shape this installer can safely edit, stop here with nothing touched.
# Required: a JSON object; .hooks absent or an object; every event value an
# array of matcher groups (objects, .matcher absent or a string, .hooks an
# array); every hook entry an object with a string .command — unless it
# declares a non-command .type (e.g. "prompt"), which has no command.
if [ -f "$SETTINGS" ]; then
  jq -e '
    def hook_ok:  type == "object"
                  and ((.command | type) == "string"
                       or ((.type | type) == "string" and .type != "command"));
    def group_ok: type == "object"
                  and ((has("matcher") | not) or (.matcher | type) == "string")
                  and (.hooks | type) == "array"
                  and all(.hooks[]; hook_ok);
    type == "object"
    and ((has("hooks") | not)
         or ((.hooks | type) == "object"
             and all(.hooks[]; type == "array" and all(.[]; group_ok))))
  ' "$SETTINGS" >/dev/null 2>&1 \
    || die "~/.claude/settings.json is not valid JSON or not a shape this installer can safely edit (it needs an object whose \"hooks\" maps each event to an array of {matcher?, hooks: [{type, command}]} groups). Nothing was changed or installed. Fix the file, then re-run."
fi

# ─── Backup ─────────────────────────────────────────────────────────────────
TS=$(date +%Y%m%d-%H%M%S)
if [ -d "$HOME/.claude" ]; then
  BACKUP="$HOME/.claude.bak.$TS"
  say "Backing up existing ~/.claude → $BACKUP"
  cp -R "$HOME/.claude" "$BACKUP"
fi

# `cp -R` copies a symlink as a link, so keep the real content of a symlinked
# settings.json too — the writes below go through the link to its target.
if [ -n "${BACKUP:-}" ] && [ -L "$SETTINGS" ] && [ -f "$SETTINGS" ]; then
  cp -L "$SETTINGS" "$BACKUP/settings.json.resolved"
fi

# ─── Retired hooks (v0.2.1 upgrade) ─────────────────────────────────────────
# v0.1.0–v0.2.0 registered six hooks that v0.2.1 no longer ships. Remove ONLY
# the exact (event, matcher, command) tuples the old kit template wrote — the
# same in every earlier release. Anything else that mentions those hooks (a
# different matcher or event, an edited command) is left alone and listed.
# Runs before any file is installed, so unreadable settings abort cleanly.
RETIRED_HOOKS="stuck-detector stop-slash-text-guard stop-pending-work-guard recommendation-hygiene-nudge gave-up-early-guard codex-tool-error-reminder"
KIT_RETIRED_TUPLES='[
  {"e":"PostToolUse",      "m":"Edit|Write|Bash", "c":"$HOME/.claude/hooks/stuck-detector.sh"},
  {"e":"PostToolUse",      "m":"*",               "c":"$HOME/.claude/hooks/codex-tool-error-reminder.sh"},
  {"e":"UserPromptSubmit", "m":null,              "c":"$HOME/.claude/hooks/recommendation-hygiene-nudge.sh"},
  {"e":"Stop",             "m":null,              "c":"$HOME/.claude/hooks/stop-slash-text-guard.sh"},
  {"e":"Stop",             "m":null,              "c":"$HOME/.claude/hooks/gave-up-early-guard.sh"},
  {"e":"Stop",             "m":null,              "c":"$HOME/.claude/hooks/stop-pending-work-guard.sh"}
]'
if [ -f "$SETTINGS" ]; then
  SETTINGS_TMP=$(mktemp "${TMPDIR:-/tmp}/build-kit-settings.XXXXXX")
  # Drop matching hook commands; drop a matcher group only if this removal emptied it.
  # Strict on shape: a hook entry that is not an object makes jq fail, and we stop.
  if ! jq --argjson kit "$KIT_RETIRED_TUPLES" '
    if (.hooks | type) == "object" then
      .hooks |= with_entries(
        .key as $e
        | if (.value | type) == "array" then
            .value |= map(
              (.matcher // null) as $m
              | if (.hooks | type) == "array" then
                  (.hooks | length) as $before
                  | .hooks |= map(select(
                      (.command // null) as $c
                      | any($kit[]; .e == $e and .m == $m and .c == $c) | not))
                  | select((.hooks | length) > 0 or $before == 0)
                else . end)
          else . end)
    else . end
  ' "$SETTINGS" > "$SETTINGS_TMP" 2>/dev/null; then
    die "~/.claude/settings.json is not valid JSON or has an unexpected shape (e.g. a hook entry that is not an object). It was left unchanged and nothing was installed. Fix the file, or remove the retired kit hooks by hand (CHANGELOG v0.2.1), then re-run."
  fi
  if ! jq -e --slurpfile a "$SETTINGS" --slurpfile b "$SETTINGS_TMP" -n '$a == $b' >/dev/null; then
    say "Removing the retired kit hook registrations from ~/.claude/settings.json (v0.2.1 upgrade)..."
    write_settings
  else
    rm -f "$SETTINGS_TMP"; SETTINGS_TMP=""
  fi
  OTHER_RETIRED=$(jq -r --arg names "$RETIRED_HOOKS" '
    ($names | split(" ")) as $n
    | (.hooks // {}) | if type == "object" then to_entries[] else empty end | .key as $e
    | .value[]? | objects | (.matcher // "(no matcher)") as $m
    | .hooks[]? | objects | (.command // "") | strings
    | select(. as $c | any($n[]; . as $h | $c | contains("/hooks/" + $h + ".sh")))
    | "    \($e) | \($m) | \(.)"' "$SETTINGS" 2>/dev/null) || OTHER_RETIRED=""
  [ -n "$OTHER_RETIRED" ] && warn "Left in place (not the kit's own registration shape) — remove by hand if they were kit hooks:
$OTHER_RETIRED"
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
cp "$KIT_DIR/claude/scripts/codex-prompt-header.txt"   "$HOME/.claude/scripts/codex-prompt-header.txt"
# `cp -R src dst` nests src into dst on a second run when dst already exists.
# Wipe the target and copy the contents to make this idempotent.
rm -rf "$HOME/.claude/scripts/codex-commit-review.prompts"
mkdir -p "$HOME/.claude/scripts/codex-commit-review.prompts"
cp -R "$KIT_DIR/claude/scripts/codex-commit-review.prompts/." "$HOME/.claude/scripts/codex-commit-review.prompts/"
cp "$KIT_DIR/claude/scripts/vibecop-adjudicate.sh"      "$HOME/.claude/scripts/vibecop-adjudicate.sh"
cp "$KIT_DIR/claude/scripts/vibecop-adjudicate-heavy.sh" "$HOME/.claude/scripts/vibecop-adjudicate-heavy.sh"

# Hooks
for h in codex-plan-review codex-commit-review-on-commit vibecop-on-edit; do
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

# One shell-quoted `rm` per line, so paths with spaces copy-paste safely.
LEFTOVER=""
add_leftover() {
  if [ -f "$1" ]; then LEFTOVER="$LEFTOVER$(printf '    rm %q' "$1")
"; fi
}
for h in $RETIRED_HOOKS; do add_leftover "$HOME/.claude/hooks/$h.sh"; done
add_leftover "$HOME/.claude/scripts/gave-up-early-review.sh"
if [ -n "$LEFTOVER" ]; then
  warn "Retired kit files are no longer registered or updated. Delete them with:"
  printf '%s' "$LEFTOVER" >&2
fi
TEMPLATE="$KIT_DIR/claude/settings.template.json"
KIT_HOOK_MARKER="codex-plan-review.sh"

if [ ! -f "$SETTINGS" ]; then
  say "Installing ~/.claude/settings.json from template..."
  cp "$TEMPLATE" "$SETTINGS"
elif grep -q "$KIT_HOOK_MARKER" "$SETTINGS" 2>/dev/null; then
  say "Kit hooks already wired in ~/.claude/settings.json — skipping merge."
else
  say "Merging kit hooks into existing ~/.claude/settings.json..."
  SETTINGS_TMP=$(mktemp "${TMPDIR:-/tmp}/build-kit-settings.XXXXXX")
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
  ' "$SETTINGS" "$TEMPLATE" > "$SETTINGS_TMP" || die "could not merge kit hooks into ~/.claude/settings.json (left unchanged)"
  write_settings
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
