#!/bin/bash
# ~/.claude/hooks/codex-commit-review-on-commit.sh
#
# PostToolUse hook on Bash. Fires after every standalone `git commit` that
# returned exit 0. Launches codex-commit-review.sh in a detached background
# process and updates the build manifest if one exists in the repo.
#
# Informational only — never blocks Claude Code. Exits 0 on any error.

set -uo pipefail

LOG_DIR="$HOME/.claude/analytics"
LOG_FILE="$LOG_DIR/codex-commit-review-hook.jsonl"
BG_LOG="$LOG_DIR/codex-commit-review-bg.log"
mkdir -p "$LOG_DIR" 2>/dev/null || true

CCR_SCRIPT="${CCR_SCRIPT:-$HOME/.claude/scripts/codex-commit-review.sh}"
MANIFEST_SCRIPT="${MANIFEST_SCRIPT:-$HOME/.claude/scripts/build-manifest/manifest.sh}"

log_event() {
  local status="$1"; local note="$2"
  local extras="${3:-}"
  [ -z "$extras" ] && extras="{}"
  if command -v jq >/dev/null 2>&1; then
    jq -nc \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg status "$status" \
      --arg note "$note" \
      --argjson extras "$extras" \
      '{ts:$ts, status:$status, note:$note} + $extras' >> "$LOG_FILE" 2>/dev/null || true
  fi
}

trap 'log_event "error" "hook errored: ${BASH_COMMAND:-unknown}"; exit 0' ERR

# Read hook JSON from stdin
HOOK_INPUT=$(cat)

command -v jq >/dev/null 2>&1 || { log_event "skipped" "jq missing"; exit 0; }
command -v git >/dev/null 2>&1 || { log_event "skipped" "git missing"; exit 0; }

CMD=$(printf '%s' "$HOOK_INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null) || CMD=""
EXIT_CODE=$(printf '%s' "$HOOK_INPUT" | jq -r '.tool_response.exit_code // .tool_response.exitCode // empty' 2>/dev/null) || EXIT_CODE=""
CWD=$(printf '%s' "$HOOK_INPUT" | jq -r '.cwd // empty' 2>/dev/null) || CWD=""
[ -z "$CWD" ] && CWD=$(pwd)

[ -z "$CMD" ] && exit 0

# Filter 1: must include a `git commit` invocation.
# We check that "git commit" appears as a word-boundary match.
if ! printf '%s' "$CMD" | grep -qE '(^|[[:space:]]|;|&&|\|\|)git[[:space:]]+commit([[:space:]]|$)'; then
  exit 0
fi

# Filter 2: reject compounds that chain ANYTHING after `git commit`.
# Per Codex audit: `git commit && git push` gives nonzero exit when push fails
# even though commit succeeded — too risky to process.
# Strategy: take everything after the first `git commit`, check for chain operators.
TAIL=$(printf '%s' "$CMD" | sed -nE 's/.*git[[:space:]]+commit([[:space:]].*|$)/\1/p' | head -1)
# TAIL is the flags + everything after. If it contains a chain operator, skip.
# Quoted sections may contain literal & or ; — a best-effort strip of quoted strings first.
TAIL_STRIPPED=$(printf '%s' "$TAIL" | sed -E 's/"[^"]*"//g; s/'"'"'[^'"'"']*'"'"'//g')
if printf '%s' "$TAIL_STRIPPED" | grep -qE '(&&|\|\||;)'; then
  log_event "skipped" "compound command after git commit" \
    "$(jq -nc --arg cmd "$CMD" '{cmd:$cmd}')"
  exit 0
fi

# Filter 3: exit code must be 0 (commit succeeded)
if [ -n "$EXIT_CODE" ] && [ "$EXIT_CODE" != "0" ]; then
  log_event "skipped" "commit exit=$EXIT_CODE" \
    "$(jq -nc --arg cmd "$CMD" --arg exit "$EXIT_CODE" '{cmd:$cmd, exit_code:$exit}')"
  exit 0
fi

# Derive effective cwd. Mirror auto-qa-on-push.sh: parse `cd <path>` or `git -C <path>`
# prefix, else fall back to session cwd.
CMD_CWD=""
if printf '%s' "$CMD" | grep -qE '(^|;|&&)[[:space:]]*cd[[:space:]]+'; then
  CMD_CWD=$(printf '%s' "$CMD" | sed -nE 's/.*(^|[;&])[[:space:]]*cd[[:space:]]+"([^"]+)".*/\2/p; s/.*(^|[;&])[[:space:]]*cd[[:space:]]+'"'"'([^'"'"']+)'"'"'.*/\2/p; s/.*(^|[;&])[[:space:]]*cd[[:space:]]+([^[:space:]&;]+).*/\2/p' | head -1)
  case "$CMD_CWD" in
    '~'|'~/'*) CMD_CWD="${HOME}${CMD_CWD#\~}" ;;
  esac
fi
if [ -z "$CMD_CWD" ] && printf '%s' "$CMD" | grep -qE 'git[[:space:]]+-C[[:space:]]+'; then
  CMD_CWD=$(printf '%s' "$CMD" | sed -nE 's/.*git[[:space:]]+-C[[:space:]]+"([^"]+)".*/\1/p; s/.*git[[:space:]]+-C[[:space:]]+([^[:space:]]+).*/\1/p' | head -1)
  case "$CMD_CWD" in
    '~'|'~/'*) CMD_CWD="${HOME}${CMD_CWD#\~}" ;;
  esac
fi

EFFECTIVE_CWD="$CWD"
[ -n "$CMD_CWD" ] && [ -d "$CMD_CWD" ] && EFFECTIVE_CWD="$CMD_CWD"

# Find git toplevel
REPO_ROOT=""
if [ -d "$EFFECTIVE_CWD" ]; then
  REPO_ROOT=$(git -C "$EFFECTIVE_CWD" rev-parse --show-toplevel 2>/dev/null) || REPO_ROOT=""
fi
if [ -z "$REPO_ROOT" ]; then
  log_event "skipped" "no git repo at cwd=$EFFECTIVE_CWD" \
    "$(jq -nc --arg cwd "$EFFECTIVE_CWD" '{cwd:$cwd}')"
  exit 0
fi

# Get HEAD SHA (the commit that just happened)
SHA=$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null) || SHA=""
if [ -z "$SHA" ]; then
  log_event "skipped" "could not resolve HEAD sha" \
    "$(jq -nc --arg repo "$REPO_ROOT" '{repo:$repo}')"
  exit 0
fi
SHA_SHORT="${SHA:0:7}"

# Update manifest if one exists in this repo. We update BEFORE launching the
# reviewer so the user sees progress even if the reviewer fails to start.
MANIFEST="$REPO_ROOT/plan/.build-state.json"
MANIFEST_UPDATED="none"
if [ -f "$MANIFEST" ] && [ -x "$MANIFEST_SCRIPT" ]; then
  # Find the in-progress chunk id (first one). Mark it done with the commit SHA.
  IN_PROGRESS_ID=$(jq -r '[.chunks[] | select(.status == "in-progress")][0].id // empty' "$MANIFEST" 2>/dev/null) || IN_PROGRESS_ID=""
  if [ -n "$IN_PROGRESS_ID" ]; then
    # Run from the repo root so manifest find_manifest locates it.
    (cd "$REPO_ROOT" && "$MANIFEST_SCRIPT" mark-chunk "$IN_PROGRESS_ID" done "$SHA") >/dev/null 2>&1 || true
    MANIFEST_UPDATED="chunk-$IN_PROGRESS_ID"
  fi
fi

# Launch codex-commit-review.sh as a fully detached background process.
if [ ! -x "$CCR_SCRIPT" ]; then
  log_event "skipped" "codex-commit-review.sh not executable" \
    "$(jq -nc --arg p "$CCR_SCRIPT" '{script:$p}')"
  exit 0
fi

# Values go in as arguments, never spliced into a shell string — a repo path
# containing a quote must not be able to inject commands.
nohup "$CCR_SCRIPT" "$SHA" --repo "$REPO_ROOT" </dev/null >> "$BG_LOG" 2>&1 &
disown 2>/dev/null || true

log_event "launched" "codex-commit-review fired" \
  "$(jq -nc --arg sha "$SHA_SHORT" --arg repo "$REPO_ROOT" --arg m "$MANIFEST_UPDATED" \
    '{sha:$sha, repo:$repo, manifest:$m}')"

cat <<DISPLAY

[codex-commit-review] $SHA_SHORT launched in background (repo: $REPO_ROOT)
DISPLAY

if [ "$MANIFEST_UPDATED" != "none" ]; then
  printf '[build-manifest] marked %s done with sha=%s\n' "$MANIFEST_UPDATED" "$SHA_SHORT"
fi

exit 0
