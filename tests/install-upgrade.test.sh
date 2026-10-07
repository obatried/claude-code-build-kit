#!/usr/bin/env bash
# Fixture tests for install.sh's v0.2.1 upgrade path (retired-hook cleanup,
# symlinked settings.json, malformed settings) and uninstall.sh's manual list.
# Self-contained: scratch HOME, private TMPDIR, stub `codex`. Never touches
# your real ~/.claude.
#
# Usage:   tests/install-upgrade.test.sh
# Exit:    0 if every case passes, 1 otherwise.
# Env:     INSTALL_SH / UNINSTALL_SH override the scripts under test.

set -uo pipefail

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${INSTALL_SH:-$KIT/install.sh}"
UNINSTALL_SH="${UNINSTALL_SH:-$KIT/uninstall.sh}"

for cmd in jq git; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "missing required command: $cmd" >&2; exit 1; }
done

T=$(mktemp -d "${TMPDIR:-/tmp}/install-upgrade-test.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/codex"; chmod +x "$T/bin/codex"

PASS=0; FAILED=0
ok()  { PASS=$((PASS + 1));     printf 'PASS  %s\n' "$1"; }
bad() { FAILED=$((FAILED + 1)); printf 'FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/      | /'; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-}"; fi; }

# The hook block every earlier release's settings.template.json registered
# (identical in v0.1.0 and v0.2.0).
V020_HOOKS='{
  "PostToolUse": [
    {"matcher":"ExitPlanMode","hooks":[{"type":"command","command":"$HOME/.claude/hooks/codex-plan-review.sh","timeout":180}]},
    {"matcher":"Edit|Write|Bash","hooks":[{"type":"command","command":"$HOME/.claude/hooks/stuck-detector.sh","timeout":90}]},
    {"matcher":"Bash","hooks":[{"type":"command","command":"$HOME/.claude/hooks/codex-commit-review-on-commit.sh","timeout":10}]},
    {"matcher":"*","hooks":[{"type":"command","command":"$HOME/.claude/hooks/codex-tool-error-reminder.sh","timeout":10}]},
    {"matcher":"Edit|Write|MultiEdit","hooks":[{"type":"command","command":"$HOME/.claude/hooks/vibecop-on-edit.sh"}]}
  ],
  "UserPromptSubmit": [
    {"hooks":[{"type":"command","command":"$HOME/.claude/hooks/recommendation-hygiene-nudge.sh","timeout":5}]}
  ],
  "Stop": [
    {"hooks":[
      {"type":"command","command":"$HOME/.claude/hooks/stop-slash-text-guard.sh","timeout":5},
      {"type":"command","command":"$HOME/.claude/hooks/gave-up-early-guard.sh","timeout":5},
      {"type":"command","command":"$HOME/.claude/hooks/stop-pending-work-guard.sh","timeout":5}
    ]}
  ]
}'
RETIRED_RE='stuck-detector|stop-slash-text-guard|stop-pending-work-guard|recommendation-hygiene-nudge|gave-up-early-guard|codex-tool-error-reminder'

# new_home <name>: fresh scratch HOME and private TMPDIR
new_home() {
  export HOME="$T/$1"; export TMPDIR="$T/$1-tmp"
  rm -rf "$HOME" "$TMPDIR"; mkdir -p "$HOME/.claude" "$TMPDIR"
}
run_install() { OUT=$(PATH="$T/bin:$PATH" bash "$INSTALL_SH" 2>&1); RC=$?; }
cmds() { jq -r '[.hooks // {} | to_entries[] | .key as $e | .value[]? | (.matcher // "-") as $m | .hooks[]? | "\($e)|\($m)|\(.command)"] | sort | .[]' "$1"; }

# ─── 1. Upgrade: kit-shaped retired registrations go; everything else stays ────
new_home upgrade
jq -n --argjson h "$V020_HOOKS" '{
  model: "keep-me",
  hooks: ($h
    | .Stop += [{"hooks":[{"type":"command","command":"/opt/mine/stop-audit.sh"}]}]
    | .PostToolUse += [{"matcher":"Bash","hooks":[{"type":"command","command":"$HOME/.claude/hooks/stuck-detector.sh"}]}]
    | .PreToolUse = [{"matcher":"*","hooks":[{"type":"command","command":"$HOME/.claude/hooks/gave-up-early-guard.sh"},{"type":"command","command":"/opt/mine/pre.sh"}]}])
}' > "$HOME/.claude/settings.json"
run_install
S="$HOME/.claude/settings.json"
check "1a. install succeeds on a v0.2.0-shaped settings.json" '[ "$RC" = 0 ]' "$OUT"
check "1b. kit-shaped retired registrations are removed" \
  '! cmds "$S" | grep -E "^(PostToolUse\|Edit\|Write\|Bash|PostToolUse\|\*|UserPromptSubmit\|-|Stop\|-)\|\\\$HOME/.claude/hooks/($RETIRED_RE)\.sh$" >/dev/null' "$(cmds "$S")"
check "1c. retired command under a non-kit matcher survives" \
  'cmds "$S" | grep -qxF "PostToolUse|Bash|\$HOME/.claude/hooks/stuck-detector.sh"' "$(cmds "$S")"
check "1d. retired command under a non-kit event survives" \
  'cmds "$S" | grep -qxF "PreToolUse|*|\$HOME/.claude/hooks/gave-up-early-guard.sh"' "$(cmds "$S")"
check "1e. the survivors are listed in a notice" \
  'printf "%s" "$OUT" | grep -q "Left in place" && printf "%s" "$OUT" | grep -q "PreToolUse | \* | \$HOME/.claude/hooks/gave-up-early-guard.sh"' "$OUT"
check "1f. the user's own hooks and settings survive" \
  'cmds "$S" | grep -qxF "Stop|-|/opt/mine/stop-audit.sh" && cmds "$S" | grep -qxF "PreToolUse|*|/opt/mine/pre.sh" && [ "$(jq -r .model "$S")" = keep-me ]' "$(cat "$S")"
check "1g. the kept kit hooks are still registered" \
  '[ "$(cmds "$S" | grep -cE "codex-plan-review|codex-commit-review-on-commit|vibecop-on-edit")" = 3 ]' "$(cmds "$S")"
check "1h. no temp file left behind" '[ -z "$(ls -A "$TMPDIR")" ]' "$(ls -la "$TMPDIR")"

# ─── 2. Idempotent re-run ──────────────────────────────────────────────────────
cp "$S" "$T/after-first"
run_install
check "2a. re-run succeeds" '[ "$RC" = 0 ]' "$OUT"
check "2b. re-run leaves settings.json byte-identical" 'cmp -s "$S" "$T/after-first"' "$(diff "$T/after-first" "$S")"
check "2c. re-run reports nothing to remove" '! printf "%s" "$OUT" | grep -q "Removing the retired"' "$OUT"

# ─── 3. Symlinked settings.json ────────────────────────────────────────────────
new_home symlink
mkdir -p "$T/dotfiles"
jq -n --argjson h "$V020_HOOKS" '{hooks: $h}' > "$T/dotfiles/settings.json"
cp "$T/dotfiles/settings.json" "$T/symlink-original.json"
ln -s "$T/dotfiles/settings.json" "$HOME/.claude/settings.json"
run_install
check "3a. install succeeds through a symlink" '[ "$RC" = 0 ]' "$OUT"
check "3b. settings.json is still a symlink to the same target" \
  '[ -L "$HOME/.claude/settings.json" ] && [ "$(readlink "$HOME/.claude/settings.json")" = "$T/dotfiles/settings.json" ]' "$(ls -la "$HOME/.claude/")"
check "3c. the target has the cleaned content" \
  '! grep -qE "$RETIRED_RE" "$T/dotfiles/settings.json" && grep -q codex-plan-review "$T/dotfiles/settings.json"' "$(cat "$T/dotfiles/settings.json")"
check "3d. the backup keeps the original content, not just the link" \
  'cmp -s "$(ls -d "$HOME"/.claude.bak.*/ | tail -1)settings.json.resolved" "$T/symlink-original.json"' "$(ls -la "$HOME"/.claude.bak.*/)"

# ─── 4. Malformed settings.json fails cleanly ──────────────────────────────────
new_home junk
printf '{"hooks":{"Stop":["junk", 42]}}\n' > "$HOME/.claude/settings.json"
cp "$HOME/.claude/settings.json" "$T/junk-original"
run_install
check "4a. install fails (non-zero exit)" '[ "$RC" != 0 ]' "$OUT"
check "4b. with a clear error" 'printf "%s" "$OUT" | grep -q "not a shape this installer can safely edit"' "$OUT"
check "4c. settings.json is unchanged" 'cmp -s "$HOME/.claude/settings.json" "$T/junk-original"'
check "4d. no temp file left behind" '[ -z "$(ls -A "$TMPDIR")" ]' "$(ls -la "$TMPDIR")"
check "4e. nothing was installed" '[ ! -e "$HOME/.claude/skills/build/SKILL.md" ]'
check "4f. no backup was created" '[ -z "$(ls -d "$HOME"/.claude.bak.* 2>/dev/null)" ]'

# ─── 6. Shape check runs before the backup, the cleanup and any copy ────────────
reject_case() { # <label> <settings.json content>
  new_home "reject-$1"
  printf '%s\n' "$2" > "$HOME/.claude/settings.json"
  cp "$HOME/.claude/settings.json" "$T/reject-orig"
  run_install
  if [ "$RC" != 0 ] \
     && printf '%s' "$OUT" | grep -q "not a shape this installer can safely edit" \
     && cmp -s "$HOME/.claude/settings.json" "$T/reject-orig" \
     && [ ! -e "$HOME/.claude/skills/build/SKILL.md" ] && [ ! -e "$HOME/.claude/hooks" ] \
     && [ -z "$(ls -d "$HOME"/.claude.bak.* 2>/dev/null)" ] && [ -z "$(ls -A "$TMPDIR")" ]; then
    ok "6. rejects $1: clear error, settings unchanged, nothing installed, no backup, no temp"
  else
    bad "6. rejects $1: clear error, settings unchanged, nothing installed, no backup, no temp" \
        "exit $RC; $OUT
$(ls -la "$HOME" "$HOME/.claude")"
  fi
}
reject_case 'hooks-array'      '{"hooks":[]}'
reject_case 'hooks-false'      '{"hooks":false}'
reject_case 'nested-null-hook' '{"hooks":{"Stop":[{"hooks":[null]}]}}'
reject_case 'null-group'       '{"hooks":{"Stop":[null]}}'
new_home prompt-hook
printf '%s\n' '{"hooks":{"Stop":[{"hooks":[{"type":"prompt","prompt":"Check the work is done."}]}]}}' > "$HOME/.claude/settings.json"
run_install
check "6e. a valid non-command hook (type: prompt) is accepted and kept" \
  '[ "$RC" = 0 ] && jq -e ".hooks.Stop[0].hooks[0].type == \"prompt\"" "$HOME/.claude/settings.json" >/dev/null' "$OUT"

# ─── 7. HOME with a space: printed rm commands are shell-safe ────────────────────
new_home "space home"
mkdir -p "$HOME/.claude/hooks" "$HOME/.claude/scripts"
for h in stuck-detector gave-up-early-guard codex-tool-error-reminder; do echo old > "$HOME/.claude/hooks/$h.sh"; done
echo old > "$HOME/.claude/scripts/gave-up-early-review.sh"
jq -n --argjson h "$V020_HOOKS" '{hooks: $h}' > "$HOME/.claude/settings.json"
run_install
check "7a. install succeeds with a space in HOME" '[ "$RC" = 0 ]' "$OUT"
RM_LINES=$(printf '%s\n' "$OUT" | sed -n 's/^    rm /rm /p')
check "7b. one rm line per leftover file (4)" '[ "$(printf "%s\n" "$RM_LINES" | grep -c "^rm ")" = 4 ]' "$OUT"
( cd "$T" && eval "$RM_LINES" ) >/dev/null 2>&1
check "7c. running the printed lines deletes exactly those files" \
  '[ ! -e "$HOME/.claude/hooks/stuck-detector.sh" ] && [ ! -e "$HOME/.claude/scripts/gave-up-early-review.sh" ] && [ -e "$HOME/.claude/hooks/codex-plan-review.sh" ] && [ ! -e "$T/space" ]' \
  "$RM_LINES
$(ls -la "$HOME/.claude/hooks")"

# ─── 5. uninstall.sh's manual list names every file install.sh installs ─────────
new_home fresh
rm -rf "$HOME/.claude"
run_install
LIST=$(sed -n '/KIT_FILES="/,/"$/p' "$UNINSTALL_SH" | sed -e 's/.*KIT_FILES="//' -e 's/"$//')
MISSING=""
while IFS= read -r f; do
  rel="${f#"$HOME"/.claude/}"
  case "$rel" in settings.json|analytics/*) continue ;; esac
  printf '%s\n' "$LIST" | grep -qxF "~/.claude/$rel" && continue
  printf '%s\n' "$LIST" | grep -qxF "~/.claude/$(dirname "$rel")/" && continue
  MISSING="$MISSING ~/.claude/$rel"
done <<EOF
$(find "$HOME/.claude" -type f | sort)
EOF
check "5a. every installed file is on uninstall's manual list" '[ -z "$MISSING" ]' "missing:$MISSING"
UOUT=$(bash "$UNINSTALL_SH" 2>&1)
check "5b. no-backup uninstall prints the list, including legacy files" \
  'printf "%s" "$UOUT" | grep -qF "~/.claude/handoff-v3.sh" && printf "%s" "$UOUT" | grep -qF "~/.claude/hooks/stuck-detector.sh"' "$UOUT"

printf '\n%s passed, %s failed\n' "$PASS" "$FAILED"
[ "$FAILED" -eq 0 ]
