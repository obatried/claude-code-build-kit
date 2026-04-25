#!/bin/bash
# ~/.claude/scripts/build-manifest/manifest.sh
#
# Build-state manifest helper for the /build orchestrator.
# Manages <repo>/plan/.build-state.json — a JSON document recording which
# chunks of a phased plan have been implemented, skipped, or failed.
#
# Subcommands:
#   init <plan-file>            Parse plan .md file, create manifest
#   approve                     Mark approved: true, stamp approved_at
#   audit                       Run a single high-reasoning Codex pass on the
#                               plan file. Prints verdict (ALLOW/BLOCK) + findings.
#                               Non-blocking; purely informational.
#   next-chunk                  Print JSON of next pending chunk (exit 1 if none)
#   mark-chunk <id> <status>    Update chunk status. status ∈ pending|in-progress|done|failed|skipped
#                               Optional 3rd arg: SHA (recorded when status=done)
#   status                      Human-readable summary
#   validate                    Check schema + consistency
#
# Manifest is located by walking up from $PWD looking for plan/.build-state.json.
# All writes go through jq + a flock'd temp-file swap for atomicity.
# Informational never-blocks design is NOT used here — this tool IS the state.
# Errors return non-zero so callers can branch on them.

set -uo pipefail

SCHEMA_VERSION=1

# ─── Utility ──────────────────────────────────────────────────────────────────

die() { printf 'manifest.sh: %s\n' "$*" >&2; exit 1; }

iso_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Walk up from $PWD to find plan/.build-state.json. Prints path on stdout.
# Returns non-zero if not found.
find_manifest() {
  local dir
  dir=$(pwd)
  while [ -n "$dir" ] && [ "$dir" != "/" ]; do
    if [ -f "$dir/plan/.build-state.json" ]; then
      printf '%s/plan/.build-state.json' "$dir"
      return 0
    fi
    dir=$(dirname "$dir")
  done
  return 1
}

require_jq() {
  command -v jq >/dev/null 2>&1 || die "jq is required but not on PATH"
}

# Atomic jq update: reads $1, pipes through jq $2 (additional args in $3..),
# writes to temp, moves over original. Locked via flock on the manifest.
# Usage: jq_update <manifest-path> <jq-expr> [--arg k v ...]
jq_update() {
  local manifest="$1"; shift
  local expr="$1"; shift
  local tmp
  tmp=$(mktemp -t manifest.XXXXXX) || die "mktemp failed"
  # Lock the manifest file itself. Using flock on the file descriptor.
  (
    if command -v flock >/dev/null 2>&1; then
      flock -x 9 || { rm -f "$tmp"; exit 1; }
    fi
    jq "$@" "$expr" "$manifest" > "$tmp" || { rm -f "$tmp"; exit 2; }
    mv "$tmp" "$manifest" || { rm -f "$tmp"; exit 3; }
  ) 9< "$manifest"
  local rc=$?
  [ $rc -ne 0 ] && die "update failed (rc=$rc)"
  return 0
}

# ─── Subcommand: init ──────────────────────────────────────────────────────────
#
# Parse a plan .md file for a chunks section and create the manifest.
# Chunks section: first occurrence of "## Chunks", or fallback "## Stories", "## Tasks".
# Chunks: numbered list items inside that section (lines starting with N. or N) ).
# For each numbered item, extract:
#   - id: the number
#   - name: the line content after the number (stripped)
#   - files: parsed from "files:" / "Files:" hints in the chunk text (comma-separated paths)

cmd_init() {
  local plan_file="${1:-}"
  [ -z "$plan_file" ] && die "usage: init <plan-file>"
  [ -f "$plan_file" ] || die "plan file not found: $plan_file"

  require_jq

  # Derive repo root: look for a `plan/` dir in $PWD or ancestors.
  # If plan_file is inside a `plan/` dir, walk up from there.
  local repo_root
  local abs_plan
  abs_plan=$(cd "$(dirname "$plan_file")" && pwd)/$(basename "$plan_file")
  repo_root=$(dirname "$(dirname "$abs_plan")")
  # If that dir doesn't end up being plausible (no `plan` segment), use $PWD's plan/
  if [ ! -d "$repo_root/plan" ]; then
    repo_root=$(pwd)
    [ ! -d "$repo_root/plan" ] && mkdir -p "$repo_root/plan"
  fi
  local manifest="$repo_root/plan/.build-state.json"

  [ -f "$manifest" ] && die "manifest already exists at $manifest (delete it first if you want to re-init)"

  # Parse chunks section
  # Extract the lines in the chunks section: from heading until next "## " or EOF
  local section
  section=$(awk '
    BEGIN { capture=0 }
    /^## (Chunks|Stories|Tasks)[[:space:]]*$/ { capture=1; next }
    capture && /^## / { capture=0 }
    capture { print }
  ' "$plan_file")

  if [ -z "$section" ]; then
    die "no '## Chunks', '## Stories', or '## Tasks' heading found in $plan_file"
  fi

  # Build a JSON array of chunks. Parse numbered list lines.
  # Accept "1. foo", "1) foo", "- 1. foo".
  local chunks_json
  chunks_json=$(printf '%s\n' "$section" | awk '
    BEGIN { printf "[" ; first=1 }
    # Match lines starting with optional "- " then a number then . or )
    /^[[:space:]]*(-[[:space:]]+)?[0-9]+[.)][[:space:]]+/ {
      # Extract id and rest
      line = $0
      sub(/^[[:space:]]*(-[[:space:]]+)?/, "", line)
      id = line
      sub(/[.)].*$/, "", id)
      rest = line
      sub(/^[0-9]+[.)][[:space:]]+/, "", rest)

      # Try to extract files: "files: a, b, c" (case-insensitive)
      files = ""
      if (match(rest, /[Ff]iles:[[:space:]]*[^—–-]*/)) {
        f = substr(rest, RSTART, RLENGTH)
        sub(/^[Ff]iles:[[:space:]]*/, "", f)
        # Trim trailing em-dash or end-marker
        files = f
      }

      # Name = rest up to first em-dash / en-dash / "- files:" / newline
      name = rest
      sub(/[[:space:]]*[—–\-][[:space:]]*[Ff]iles:.*$/, "", name)
      # If name still contains trailing " — files:" markers, kill them
      sub(/[[:space:]]*—.*$/, "", name)
      sub(/[[:space:]]*–.*$/, "", name)
      # Strip markdown emphasis **name**
      gsub(/\*\*/, "", name)
      # Strip trailing whitespace
      sub(/[[:space:]]+$/, "", name)

      # Build files as JSON array by splitting on comma
      files_arr = ""
      if (length(files) > 0) {
        n = split(files, parts, /,[[:space:]]*/)
        for (i=1; i<=n; i++) {
          p = parts[i]
          sub(/^[[:space:]]+/, "", p)
          sub(/[[:space:]]+$/, "", p)
          if (length(p) > 0) {
            if (files_arr == "") files_arr = "\"" p "\""
            else                 files_arr = files_arr ",\"" p "\""
          }
        }
      }

      if (!first) printf ","
      first=0
      # Escape double-quotes and backslashes in name
      gsub(/\\/, "\\\\", name)
      gsub(/"/, "\\\"", name)
      printf "{\"id\":\"%s\",\"name\":\"%s\",\"files\":[%s],\"status\":\"pending\",\"sha\":null,\"started_at\":null,\"completed_at\":null}", id, name, files_arr
    }
    END { printf "]" }
  ')

  # Validate the JSON we just built
  if ! printf '%s' "$chunks_json" | jq empty 2>/dev/null; then
    die "failed to parse chunks from plan file (produced invalid JSON)"
  fi

  local chunk_count
  chunk_count=$(printf '%s' "$chunks_json" | jq 'length')
  if [ "$chunk_count" -eq 0 ]; then
    die "no numbered chunks found in plan file's chunks section"
  fi

  # Path relative to repo_root
  local plan_rel
  case "$abs_plan" in
    "$repo_root/"*) plan_rel="${abs_plan#$repo_root/}" ;;
    *) plan_rel="$abs_plan" ;;
  esac

  local now
  now=$(iso_now)
  jq -n \
    --argjson schema_version "$SCHEMA_VERSION" \
    --arg plan_file "$plan_rel" \
    --argjson chunks "$chunks_json" \
    --arg now "$now" \
    '{
      schema_version: $schema_version,
      plan_file: $plan_file,
      approved: false,
      approved_at: null,
      chunks: $chunks,
      landing_mode: "stop-after-qa",
      created_at: $now,
      updated_at: $now
    }' > "$manifest" || die "failed to write manifest"

  printf 'created %s with %s chunks\n' "$manifest" "$chunk_count"
}

# ─── Subcommand: approve ───────────────────────────────────────────────────────
cmd_approve() {
  require_jq
  local manifest
  manifest=$(find_manifest) || die "no manifest found (walked up from $PWD)"

  local already
  already=$(jq -r '.approved' "$manifest")
  [ "$already" = "true" ] && die "already approved at $(jq -r '.approved_at' "$manifest")"

  local now
  now=$(iso_now)
  jq_update "$manifest" \
    '.approved = true | .approved_at = $now | .updated_at = $now' \
    --arg now "$now"
  printf 'approved %s at %s\n' "$manifest" "$now"
}

# ─── Subcommand: next-chunk ────────────────────────────────────────────────────
cmd_next_chunk() {
  require_jq
  local manifest
  manifest=$(find_manifest) || die "no manifest found"

  local chunk
  chunk=$(jq -c '[.chunks[] | select(.status == "pending")] | first // empty' "$manifest")
  if [ -z "$chunk" ]; then
    printf '\n'
    exit 1
  fi
  printf '%s\n' "$chunk"
}

# ─── Subcommand: mark-chunk ────────────────────────────────────────────────────
cmd_mark_chunk() {
  require_jq
  local id="${1:-}"
  local status="${2:-}"
  local sha="${3:-}"
  [ -z "$id" ] && die "usage: mark-chunk <id> <status> [sha]"
  [ -z "$status" ] && die "usage: mark-chunk <id> <status> [sha]"
  case "$status" in
    pending|in-progress|done|failed|skipped) ;;
    *) die "invalid status: $status (must be pending|in-progress|done|failed|skipped)" ;;
  esac

  local manifest
  manifest=$(find_manifest) || die "no manifest found"

  # Verify chunk exists
  local exists
  exists=$(jq --arg id "$id" '[.chunks[] | select(.id == $id)] | length' "$manifest")
  [ "$exists" = "0" ] && die "no chunk with id=$id in $manifest"

  local now
  now=$(iso_now)
  jq_update "$manifest" '
    .chunks |= map(
      if .id == $id then
        .status = $status
        | (if $status == "in-progress" and .started_at == null then .started_at = $now else . end)
        | (if ($status == "done" or $status == "failed" or $status == "skipped") then .completed_at = $now else . end)
        | (if $sha != "" then .sha = $sha else . end)
      else .
      end
    )
    | .updated_at = $now
  ' --arg id "$id" --arg status "$status" --arg sha "$sha" --arg now "$now"
  printf 'chunk %s -> %s%s\n' "$id" "$status" "${sha:+ (sha=$sha)}"
}

# ─── Subcommand: status ────────────────────────────────────────────────────────
cmd_status() {
  require_jq
  local manifest
  manifest=$(find_manifest) || die "no manifest found"

  jq -r '
    . as $m
    | ($m.chunks | length) as $total
    | ($m.chunks | map(select(.status == "done")) | length) as $done
    | ($m.chunks | map(select(.status == "in-progress")) | length) as $wip
    | ($m.chunks | map(select(.status == "pending")) | length) as $pend
    | ($m.chunks | map(select(.status == "failed")) | length) as $fail
    | ($m.chunks | map(select(.status == "skipped")) | length) as $skip
    | ($m.chunks | map(select(.status == "in-progress")) | first) as $current
    | ($m.chunks | map(select(.status == "pending")) | first) as $next
    | "plan:     \($m.plan_file)",
      "approved: \($m.approved)\(if $m.approved_at then "  (\($m.approved_at))" else "" end)",
      "chunks:   \($done)/\($total) done  |  \($wip) in-progress  |  \($pend) pending  |  \($fail) failed  |  \($skip) skipped",
      (if $current then "current:  #\($current.id) \($current.name)" else empty end),
      (if $next then "next:     #\($next.id) \($next.name)" else "next:     (none — all chunks resolved)" end),
      "updated:  \($m.updated_at)"
  ' "$manifest"
}

# ─── Subcommand: audit ─────────────────────────────────────────────────────────
#
# Run a single high-reasoning Codex pass on the plan file referenced in the
# manifest. Prints the verdict to stdout. Logs to
# ~/.claude/analytics/codex-plan-reviews.jsonl (same log the existing
# ExitPlanMode hook uses). Fail-open: any error prints a warning and exits 0.
#
# Env overrides (for testing): CODEX_BIN.
cmd_audit() {
  require_jq
  local manifest
  manifest=$(find_manifest) || die "no manifest found"

  local plan_rel
  plan_rel=$(jq -r '.plan_file' "$manifest")
  [ -z "$plan_rel" ] || [ "$plan_rel" = "null" ] && die "manifest has no plan_file"

  local repo_root
  repo_root=$(dirname "$(dirname "$manifest")")
  local plan_abs="$repo_root/$plan_rel"
  [ -f "$plan_abs" ] || die "plan file not found: $plan_abs"

  local codex_bin="${CODEX_BIN:-codex}"
  command -v "$codex_bin" >/dev/null 2>&1 || {
    printf 'manifest.sh: codex not on PATH — skipping audit\n' >&2
    return 0
  }

  local log_dir="$HOME/.claude/analytics"
  local log_file="$log_dir/codex-plan-reviews.jsonl"
  mkdir -p "$log_dir" 2>/dev/null || true

  local timeout_bin=""
  if command -v timeout  >/dev/null 2>&1; then timeout_bin="timeout"
  elif command -v gtimeout >/dev/null 2>&1; then timeout_bin="gtimeout"
  fi

  local prompt_file last_msg
  prompt_file=$(mktemp -t manifest-audit.XXXXXX) || die "mktemp failed"
  last_msg=$(mktemp -t manifest-audit-msg.XXXXXX) || { rm -f "$prompt_file"; die "mktemp failed"; }

  cat > "$prompt_file" <<'PROMPT_HEADER'
IMPORTANT: Do NOT read or execute any files under ~/.claude/, ~/.agents/, .claude/skills/, or agents/. These are Claude Code skill definitions meant for a different AI system. Stay focused on repository code only.

You are reviewing a plan that Claude Code created. Be skeptical. Find the strongest reasons this plan should NOT ship as-is.

Focus on these attack surfaces:
- auth, permissions, tenant isolation, trust boundaries
- data loss, corruption, irreversible state changes
- rollback safety, retries, partial failure, idempotency gaps
- race conditions, ordering assumptions, stale state
- empty-state, null, timeout, degraded dependency behavior
- version skew, schema drift, migration hazards
- observability gaps that would hide failure

Be terse. Report only material findings. No style feedback, no naming nits, no speculative concerns.

Output contract:
- Your FIRST LINE must be exactly one of:
  - ALLOW: <one-line reason>
  - BLOCK: <one-line reason>
- Below the first line, list specific findings with severity (critical/high/medium/low), what could go wrong, and a concrete fix.
- If you cannot find any material concern, return ALLOW with a brief reason.

THE PLAN:
PROMPT_HEADER
  cat "$plan_abs" >> "$prompt_file"

  local start elapsed exit_code=0
  start=$(date +%s)
  if [ -n "$timeout_bin" ]; then
    "$timeout_bin" 170 "$codex_bin" exec \
      -s read-only \
      --skip-git-repo-check \
      --output-last-message "$last_msg" \
      -c 'model_reasoning_effort="high"' \
      - < "$prompt_file" >/dev/null 2>&1 || exit_code=$?
  else
    "$codex_bin" exec \
      -s read-only \
      --skip-git-repo-check \
      --output-last-message "$last_msg" \
      -c 'model_reasoning_effort="high"' \
      - < "$prompt_file" >/dev/null 2>&1 || exit_code=$?
  fi
  elapsed=$(( $(date +%s) - start ))

  if [ $exit_code -ne 0 ]; then
    printf 'manifest.sh: codex audit failed (exit=%s, elapsed=%ss)\n' "$exit_code" "$elapsed" >&2
    jq -nc --arg ts "$(iso_now)" --arg plan "$plan_rel" --argjson elapsed "$elapsed" --argjson exit "$exit_code" \
      '{ts:$ts, status:"failed", source:"manifest-audit", plan:$plan, elapsed_s:$elapsed, exit_code:$exit}' \
      >> "$log_file" 2>/dev/null || true
    rm -f "$prompt_file" "$last_msg"
    return 0
  fi

  local verdict_text first_line verdict
  verdict_text=$(cat "$last_msg" 2>/dev/null) || verdict_text=""
  first_line="${verdict_text%%$'\n'*}"
  case "$first_line" in
    ALLOW:*) verdict=ALLOW ;;
    BLOCK:*) verdict=BLOCK ;;
    *)       verdict=UNKNOWN ;;
  esac

  jq -nc --arg ts "$(iso_now)" --arg plan "$plan_rel" --arg verdict "$verdict" --argjson elapsed "$elapsed" \
    '{ts:$ts, status:"completed", source:"manifest-audit", plan:$plan, verdict:$verdict, elapsed_s:$elapsed}' \
    >> "$log_file" 2>/dev/null || true

  cat <<EOF

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
MANIFEST AUDIT · $plan_rel · ${elapsed}s · $verdict
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
$verdict_text
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
  rm -f "$prompt_file" "$last_msg"
}

# ─── Subcommand: validate ──────────────────────────────────────────────────────
cmd_validate() {
  require_jq
  local manifest
  manifest=$(find_manifest) || die "no manifest found"

  # Check required top-level keys
  local missing
  missing=$(jq -r '
    . as $m
    | ["schema_version","plan_file","approved","approved_at","chunks","landing_mode","created_at","updated_at"]
    | map(select(. as $k | ($m | has($k) | not))) | .[]
  ' "$manifest" 2>/dev/null) || missing=""
  if [ -n "$missing" ]; then
    printf 'FAIL: missing keys: %s\n' "$(echo "$missing" | tr '\n' ' ')" >&2
    exit 1
  fi

  # schema_version == 1
  local sv
  sv=$(jq -r '.schema_version' "$manifest")
  [ "$sv" = "1" ] || { printf 'FAIL: schema_version must be 1, got: %s\n' "$sv" >&2; exit 1; }

  # approved must be bool
  jq -e '.approved | type == "boolean"' "$manifest" >/dev/null || { printf 'FAIL: approved must be boolean\n' >&2; exit 1; }

  # approved_at consistency
  local approved approved_at
  approved=$(jq -r '.approved' "$manifest")
  approved_at=$(jq -r '.approved_at' "$manifest")
  if [ "$approved" = "true" ] && [ "$approved_at" = "null" ]; then
    printf 'FAIL: approved=true but approved_at is null\n' >&2; exit 1
  fi
  if [ "$approved" = "false" ] && [ "$approved_at" != "null" ]; then
    printf 'FAIL: approved=false but approved_at is set\n' >&2; exit 1
  fi

  # Chunks must be array, each with required fields, valid status
  local chunk_errors
  chunk_errors=$(jq -r '
    if (.chunks | type) != "array" then "chunks must be array" else empty end,
    (.chunks[]?
      | (if (.id | type) != "string" then "chunk missing string id: \(.)" else empty end),
        (if (.name | type) != "string" then "chunk \(.id) missing string name" else empty end),
        (if (.status | type) != "string" then "chunk \(.id) missing string status" else empty end),
        (if (.status as $s | ["pending","in-progress","done","failed","skipped"] | index($s)) then empty else "chunk \(.id) invalid status: \(.status)" end),
        (if (.files | type) != "array" then "chunk \(.id) files must be array" else empty end))
  ' "$manifest")
  if [ -n "$chunk_errors" ]; then
    printf 'FAIL:\n%s\n' "$chunk_errors" >&2
    exit 1
  fi

  # No duplicate ids
  local dup
  dup=$(jq -r '.chunks | group_by(.id) | map(select(length > 1) | .[0].id) | .[]' "$manifest")
  if [ -n "$dup" ]; then
    printf 'FAIL: duplicate chunk ids: %s\n' "$(echo "$dup" | tr '\n' ' ')" >&2
    exit 1
  fi

  printf 'OK: %s\n' "$manifest"
}

# ─── Dispatch ──────────────────────────────────────────────────────────────────

sub="${1:-}"
shift 2>/dev/null || true
case "$sub" in
  init)         cmd_init "$@" ;;
  approve)      cmd_approve ;;
  audit)        cmd_audit ;;
  next-chunk)   cmd_next_chunk ;;
  mark-chunk)   cmd_mark_chunk "$@" ;;
  status)       cmd_status ;;
  validate)     cmd_validate ;;
  ""|-h|--help|help)
    sed -n '2,25p' "$0"
    ;;
  *)
    die "unknown subcommand: $sub"
    ;;
esac
