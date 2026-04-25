# Install

## TL;DR

```bash
git clone https://github.com/ObaCorp/claude-code-build-kit
cd claude-code-build-kit
./install.sh
```

Then restart your shell and try `/build` in any project.

## What `install.sh` does

1. **Checks hard dependencies** — `codex`, `jq`, `git`, `bash`. Fails loud if any are missing.
2. **Warns on the soft dependency** — `gstack`. Install proceeds either way. Vibecop is per-repo (npm), so the installer doesn't probe for it; the `vibecop-on-edit` hook no-ops cleanly when it's not present.
3. **Backs up your existing `~/.claude/`** to `~/.claude.bak.<timestamp>/` before touching anything.
4. **Copies files** into the right paths:
   - `~/.claude/CLAUDE.md`, `CLAUDE_MAINTENANCE.md`, `CLAUDE_MAP.md`
   - `~/.claude/skills/build/SKILL.md`
   - `~/.claude/scripts/build-manifest/manifest.sh`
   - `~/.claude/scripts/codex-commit-review.sh` + `.prompts/`
   - `~/.claude/scripts/vibecop-adjudicate*.sh`
   - `~/.claude/scripts/gave-up-early-review.sh`
   - 9 hooks under `~/.claude/hooks/`
   - `~/.claude/handoff-v3.sh`
5. **Merges hooks into `~/.claude/settings.json`** using `jq`. If you already have hooks, the kit's hooks are appended; nothing is overwritten.
6. **Drops `~/.codex/config.toml`** if you don't have one (`gpt-5.5` + `medium` defaults).
7. **Appends a handoff-pickup block to `~/.zshrc`** (idempotent — checks for the marker before appending).
8. **`chmod +x`** every script.
9. **Smoke-tests** by invoking `manifest.sh` to confirm it's executable.

## Manual install

If you don't trust the installer, the layout maps 1:1:

| Repo path | Install path |
|---|---|
| `claude/CLAUDE.md` | `~/.claude/CLAUDE.md` |
| `claude/CLAUDE_MAINTENANCE.md` | `~/.claude/CLAUDE_MAINTENANCE.md` |
| `claude/CLAUDE_MAP.md` | `~/.claude/CLAUDE_MAP.md` |
| `claude/skills/build/` | `~/.claude/skills/build/` |
| `claude/scripts/` | `~/.claude/scripts/` |
| `claude/hooks/` | `~/.claude/hooks/` |
| `claude/handoff-v3.sh` | `~/.claude/handoff-v3.sh` |
| `claude/settings.template.json` | merge into `~/.claude/settings.json` |
| `codex-config.template.toml` | `~/.codex/config.toml` |
| `zshrc-snippet.sh` | append to `~/.zshrc` |

`chmod +x ~/.claude/handoff-v3.sh ~/.claude/scripts/**/*.sh ~/.claude/hooks/*.sh` after copying.

## Verifying the install

After install + shell restart:

```bash
# 1. Codex defaults are picked up
codex exec --skip-git-repo-check "Reply with the model name and reasoning effort."
# Expected: gpt-5.5 + medium reasoning shown in the header

# 2. Manifest tool runs
~/.claude/scripts/build-manifest/manifest.sh
# Expected: usage help

# 3. Hooks are wired
jq '.hooks' ~/.claude/settings.json
# Expected: PostToolUse, UserPromptSubmit, Stop blocks present
```

In a Claude Code session, the philosophy loads automatically (you'll see CLAUDE.md content in your context). Try `/build` in any project to invoke the orchestrator.

## Uninstall

```bash
./uninstall.sh
```

This restores `~/.claude/` from the most recent `~/.claude.bak.<timestamp>/`, removes the `~/.codex/config.toml` if it matches the kit's template, and removes the zshrc snippet by marker.

## Common issues

**`codex: command not found`** — Install the OpenAI Codex CLI first. The kit is hard-blocked on it.

**`jq: command not found`** — `brew install jq` (macOS) or `apt install jq` (Linux).

**`/build` runs but Codex review hook never fires** — Check `jq '.hooks.PostToolUse' ~/.claude/settings.json`. The `ExitPlanMode` matcher must point at `~/.claude/hooks/codex-plan-review.sh`. If you had pre-existing hooks, the merger may have failed to deduplicate — manually edit.

**Handoff opens a new tab but Claude doesn't launch** — The 120s freshness window is tight. If your `.zshrc` is slow to source (more than 2 minutes), increase the window in the snippet. Also verify `CLAUDE_CODE*` env vars are unset in the new tab.

**Vibecop hook spams output** — The hook only fires when `node_modules/vibecop` exists in the repo's tree. If you don't want vibecop in a repo, just don't install it there.

**My existing CLAUDE.md got overwritten** — `install.sh` overwrites `~/.claude/CLAUDE.md` (and the other kit-tracked files) on every run. The full `~/.claude/` is backed up to `~/.claude.bak.<timestamp>/` first; restore from there. If you want to merge instead of replace, do a manual install from the layout table above and skip the philosophy files.

## Updating

`./install.sh` is idempotent. Re-running it pulls the latest kit content over your install. It still backs up `~/.claude/` first. Customizations under `~/.claude/` outside the kit's file list (your own skills, hooks, memory) are preserved by the merge logic.
