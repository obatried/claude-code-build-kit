#!/usr/bin/env bash
# Fixture tests for `manifest.sh review-gate` and the commit reviewer's log/diff
# behaviour it depends on. Self-contained: temp repos, a bare "origin", a scratch
# HOME, a hand-written review log, and a stub `codex`. Never touches your ~/.claude.
#
# Usage:   tests/review-gate.test.sh
# Exit:    0 if every case passes, 1 otherwise.
# Env:     MANIFEST_SH / CCR_SH override the scripts under test (default: this kit's).

set -uo pipefail

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST_SH="${MANIFEST_SH:-$KIT/claude/scripts/build-manifest/manifest.sh}"
CCR_SH="${CCR_SH:-$KIT/claude/scripts/codex-commit-review.sh}"
PROMPTS="$KIT/claude/scripts/codex-commit-review.prompts"
HEADER="$KIT/claude/scripts/codex-prompt-header.txt"

for cmd in git jq; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "missing required command: $cmd" >&2; exit 1; }
done

TMP=$(mktemp -d "${TMPDIR:-/tmp}/review-gate-test.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME/.claude/analytics"
LOG="$HOME/.claude/analytics/codex-commit-reviews.jsonl"
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null

PASS=0; FAILED=0
ok()  { PASS=$((PASS + 1));     printf 'PASS  %s\n' "$1"; }
bad() { FAILED=$((FAILED + 1)); printf 'FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/      | /'; }

# ─── Fixtures ─────────────────────────────────────────────────────────────────
N=0
# new_repo: fresh repo with a bare origin; "upstream" commit pushed; plan approved.
new_repo() {
  N=$((N + 1)); R="$TMP/repo$N"; O="$TMP/origin$N.git"
  git init -q --bare -b main "$O" 2>/dev/null || { git init -q --bare "$O"; git -C "$O" symbolic-ref HEAD refs/heads/main; }
  git init -q -b main "$R" 2>/dev/null || { git init -q "$R"; git -C "$R" checkout -q -b main; }
  git -C "$R" remote add origin "$O"
  echo upstream > "$R/README"; git -C "$R" add README; git -C "$R" commit -q -m "upstream"
  git -C "$R" push -q origin main
  mkdir -p "$R/plan"
  printf '## Chunks\n1. first — files: a.txt\n2. second — files: b.txt\n' > "$R/plan/P.md"
  (cd "$R" && bash "$MANIFEST_SH" init plan/P.md >/dev/null && bash "$MANIFEST_SH" approve >/dev/null)
  : > "$LOG"
}
# commit <file> <message> → prints full SHA
commit() {
  echo "$RANDOM $2" >> "$R/$1"; git -C "$R" add "$1"
  printf '%s\n' "$2" > "$TMP/msg"; git -C "$R" commit -q -F "$TMP/msg"
  git -C "$R" rev-parse HEAD
}
# review <full-sha> <status> [verdict] [legacy]: append a review log line
review() {
  local full="$1" st="$2" v="${3:-}" legacy="${4:-}"
  jq -nc --arg s "${full:0:7}" --arg f "$full" --arg st "$st" --arg v "$v" --arg legacy "$legacy" \
    '{ts:"t", status:$st, note:(if $st=="skipped" then "tier 0 (trivial change)" else "x" end), sha:$s}
     + (if $legacy == "" then {sha_full:$f} else {} end)
     + (if $v != "" then {verdict:$v} else {} end)' >> "$LOG"
}
# gate_expect <name> <expected-exit> <must-contain> [flags...]
gate_expect() {
  local name="$1" want="$2" needle="$3"; shift 3
  local out rc
  out=$(cd "$R" && bash "$MANIFEST_SH" review-gate "$@" 2>&1); rc=$?
  if [ "$rc" = "$want" ] && printf '%s' "$out" | grep -qF -- "$needle"; then ok "$name"
  else bad "$name (exit $rc, want $want; expected text: $needle)" "$out"; fi
}

# ─── 1. Review-fix must be a real trailer on a DESCENDANT commit ─────────────────
new_repo
B=$(commit a.txt "chunk 1"); review "$B" completed BLOCK
F=$(commit a.txt "fix chunk 1

Review-fix: ${B:0:7} is mentioned in the body, not as a trailer.

Some closing paragraph.")
review "$F" completed ALLOW
gate_expect "1a. body line that is not a trailer does not clear a BLOCK" 1 "BLOCK, no descendant commit"

new_repo
git -C "$R" branch side          # side branches off the base, before the BLOCKed commit
B=$(commit a.txt "chunk 1 (blocked)"); review "$B" completed BLOCK
git -C "$R" checkout -q side
S=$(commit s.txt "sibling claims the fix

Review-fix: $B"); review "$S" completed ALLOW
git -C "$R" checkout -q main
git -C "$R" merge -q --no-ff -m "merge side" side; M=$(git -C "$R" rev-parse HEAD); review "$M" completed ALLOW
gate_expect "1b. trailer on a sibling (non-descendant) commit does not clear a BLOCK" 1 "BLOCK, no descendant commit"

new_repo
B=$(commit a.txt "chunk 1"); review "$B" completed BLOCK
F=$(commit a.txt "fix chunk 1

Review-fix: ${B:0:7}"); review "$F" completed ALLOW
gate_expect "1c. real trailer on a descendant clears the BLOCK" 0 "resolved by ${F:0:7}"

# ─── 2. Matching is on the full SHA; legacy short-only lines never count ─────────
new_repo
C=$(commit a.txt "chunk 1"); review "$C" completed ALLOW legacy
gate_expect "2a. log line without sha_full does not satisfy the gate" 1 "no finished review"

# 2b. the reviewer itself logs sha_full (stub codex, tier forced to 1)
mkdir -p "$TMP/bin"
cat > "$TMP/bin/codex" <<'STUB'
#!/bin/bash
cat >/dev/null
out=""; while [ $# -gt 0 ]; do [ "$1" = "--output-last-message" ] && out="$2"; shift; done
[ -n "$out" ] && printf 'NO_FINDINGS\n' > "$out"
exit 0
STUB
chmod +x "$TMP/bin/codex"
run_reviewer() { # <sha> [extra args]
  local sha="$1"; shift
  PATH="$TMP/bin:$PATH" CODEX_REVIEW_PROMPTS_DIR="$PROMPTS" CODEX_PROMPT_HEADER="$HEADER" \
    bash "$CCR_SH" "$sha" --repo "$R" --prompts-dir "$PROMPTS" "$@" >/dev/null 2>&1
}
new_repo
C=$(commit a.txt "chunk 1")
run_reviewer "$C" --tier 1
if jq -e --arg f "$C" 'select(.status=="completed" and .sha_full==$f)' "$LOG" >/dev/null 2>&1; then
  ok "2b. reviewer logs sha_full on its completed line"
else
  bad "2b. reviewer logs sha_full on its completed line" "$(cat "$LOG")"
fi

# ─── 3. Merges ───────────────────────────────────────────────────────────────
new_repo
git -C "$R" checkout -q -b feat
for i in 1 2 3 4 5 6 7 8; do echo "const v$i = $i;" >> "$R/app.js"; done
git -C "$R" add app.js; git -C "$R" commit -q -m "feature code"; FC=$(git -C "$R" rev-parse HEAD)
git -C "$R" checkout -q main
git -C "$R" merge -q --no-ff -m "merge feat" feat; M=$(git -C "$R" rev-parse HEAD)
review "$FC" completed ALLOW; review "$M" skipped
gate_expect "3a. a skipped merge commit fails the gate" 1 "merge commit was skipped"

# 3b. the reviewer diffs a merge against its first parent (and so does not skip it)
: > "$LOG"
run_reviewer "$M"
diff_file=$(ls -d "$HOME"/.claude/state/codex-commit-review/"${M:0:7}"-*/ 2>/dev/null | tail -1)diff.patch
if grep -q 'const v8 = 8;' "$diff_file" 2>/dev/null \
   && jq -e --arg f "$M" 'select(.sha_full==$f and .status=="completed")' "$LOG" >/dev/null 2>&1; then
  ok "3b. reviewer reviews a merge's first-parent diff instead of skipping it"
else
  bad "3b. reviewer reviews a merge's first-parent diff instead of skipping it" \
      "log: $(cat "$LOG")
diff.patch has the merged code: $(grep -c 'const v' "$diff_file" 2>/dev/null || echo 0) line(s)"
fi

# ─── 4. --push checks the live remote ───────────────────────────────────────────
new_repo
C=$(commit a.txt "chunk 1"); review "$C" completed ALLOW
gate_expect "4a. --push passes when origin/main is the build's base" 0 "0 failing" --push

# remote moves ahead (another clone pushes); the local origin/main ref is stale
git clone -q "$O" "$TMP/other$N"
echo other > "$TMP/other$N/other.txt"; git -C "$TMP/other$N" add other.txt
git -C "$TMP/other$N" commit -q -m "someone else"; git -C "$TMP/other$N" push -q origin main
gate_expect "4b. --push fails when the remote is ahead (fetches first)" 1 "remote is ahead" --push

new_repo
git -C "$R" remote remove origin
C=$(commit a.txt "chunk 1"); review "$C" completed ALLOW
gate_expect "4c. --push fails when origin main cannot be fetched" 1 "could not fetch origin main" --push
gate_expect "4d. --initial-push allows a missing origin/main" 0 "remote checks skipped" --initial-push

# ─── 5. Manifests without base_sha fail closed ─────────────────────────────────
new_repo
BASE=$(git -C "$R" rev-parse HEAD)
C=$(commit a.txt "chunk 1"); review "$C" completed ALLOW
(cd "$R" && bash "$MANIFEST_SH" mark-chunk 1 done "$C" >/dev/null)
jq 'del(.base_sha)' "$R/plan/.build-state.json" > "$TMP/m" && mv "$TMP/m" "$R/plan/.build-state.json"
gate_expect "5a. manifest without base_sha fails with set-base instructions" 1 "manifest.sh set-base"
(cd "$R" && bash "$MANIFEST_SH" set-base "$BASE" >/dev/null 2>&1)
gate_expect "5b. after set-base the gate runs normally" 0 "1 commit(s)"
out=$(cd "$R" && bash "$MANIFEST_SH" set-base "$C" 2>&1) && bad "5c. set-base refuses to overwrite an existing base_sha" "$out" \
  || { printf '%s' "$out" | grep -qF "already recorded" && ok "5c. set-base refuses to overwrite an existing base_sha" || bad "5c. set-base refuses to overwrite an existing base_sha" "$out"; }
gate_expect "5d. base_sha unchanged after the refused overwrite" 0 "1 commit(s)"

# ─── Edge cases ─────────────────────────────────────────────────────────────────
new_repo
C=$(commit a.txt "chunk 1")
rm -f "$LOG"
gate_expect "6. missing review log: every commit fails" 1 "no finished review"

new_repo
gate_expect "7. empty range passes" 0 "0 commit(s)"

# Happy path: BLOCK fixed via trailer, a skipped trivial commit, a reviewed merge, --push.
new_repo
B=$(commit a.txt "chunk 1"); review "$B" completed BLOCK
F=$(commit a.txt "fix chunk 1

Review-fix: $B"); review "$F" completed ALLOW
T=$(commit notes.txt "typo"); review "$T" skipped
git -C "$R" checkout -q -b feat; FC=$(commit b.txt "chunk 2"); review "$FC" completed ALLOW
git -C "$R" checkout -q main; git -C "$R" merge -q --no-ff -m "merge chunk 2" feat
M=$(git -C "$R" rev-parse HEAD); review "$M" completed ALLOW
gate_expect "8. happy path (fixed BLOCK, skipped commit, reviewed merge) passes --push" 0 "5 commit(s)" --push

# ─── Result ────────────────────────────────────────────────────────────────────
printf '\n%s passed, %s failed\n' "$PASS" "$FAILED"
[ "$FAILED" -eq 0 ]
