# claude-code-build-kit

An opinionated build workflow for [Claude Code](https://www.claude.com/product/claude-code) — the orchestrator, hooks, and discipline rules that make multi-commit features ship without drift.

This is the kit, not the kit's documentation. Every file in `claude/` is something currently running on the maintainer's machine. Read [ARCHITECTURE.md](ARCHITECTURE.md) for the system design and [INSTALL.md](INSTALL.md) for setup.

## What you get

Drop this kit on top of an existing Claude Code install and you get:

1. **`/build`** — a single skill that runs an end-to-end feature build: plan → Codex audit → atomic chunked commits → multi-reviewer Codex review per commit → QA → summary. Reads a manifest at `<repo>/plan/.build-state.json` so a session can resume itself without re-asking for context. Push to main is **opt-in** — declare it in your repo's `CLAUDE.md` or `AGENTS.md` if you want auto-push on QA pass.
2. **A 10-section CLAUDE.md** — operating principles (think before coding, simplicity first, surgical changes, persistence, unbiased consults) loaded into every conversation.
3. **9 hooks** that enforce the principles at runtime: auto-Codex on every plan exit, multi-reviewer audit on every commit, vibecop adjudication on every edit, stuck-loop detection, "gave up early" Stop-hook audits, recommendation-hygiene nudges before architectural answers.
4. **A handoff script** that transitions a heavy session into a fresh one without losing context — drops a prompt file, opens a new Terminal tab, the new session picks up via a `.zshrc` cooperator.
5. **Codex CLI defaults** at `gpt-5.5` + `medium` reasoning, set globally so every script invocation inherits.

## Hard dependencies

| Tool | Why | Install |
|---|---|---|
| [Codex CLI](https://github.com/openai/codex) | Plan/commit reviews, vibecop adjudication, stuck-detector consults | Per OpenAI's instructions |
| `jq` | Manifest reads, hook payload parsing | `brew install jq` |
| `git` | Commits, diffs | Standard |

## Soft dependencies

| Tool | What you lose without it |
|---|---|
| [gstack](https://github.com/anthropics/gstack) | `/build` calls `/qa`, `/browse`, `/design-review`, `/emil-design-eng`, `/make-interfaces-feel-better` from gstack during execute + QA phases. Without gstack the design/QA steps degrade or no-op. |
| `vibecop` (npm package, per-repo) | The `vibecop-on-edit` hook no-ops cleanly when not present. Drop `vibecop` into a repo to enable inline lint-style adjudication during edits. |

## Tradeoffs to know before installing

This kit is **opinionated**, not neutral. By design:

- **Stop after QA** is the default ship path. `/build` writes a summary and stops; you push manually. To make `/build` push to main automatically on QA pass, declare it in your repo's `CLAUDE.md` or `AGENTS.md` (e.g. `/build auto-pushes to main on QA pass`). PR-based teams should leave this off.
- **RED→GREEN test receipts** are required for every chunk that has mockable logic. No receipt = chunk isn't done.
- **3-round caps** apply to every loop (Codex debate, fix iterations, vibecop adjudication). After 3 rounds, dispatch a Task sub-agent or surface to the user.
- **No permission overrides included.** The kit's `settings.template.json` only wires hooks; it does not add `permissions.allow` entries. Your existing Claude Code permission prompts will still fire on Bash, Edit, etc. — by design, so a stranger doesn't get auto-allowed Bash on first install. Layer in `permissions.allow` manually after you've watched the kit run for a session or two.
- **macOS handoff**. `handoff-v3.sh` uses AppleScript + Terminal.app. On Linux/Windows the script ships, but you start the new session manually.
- **Handoff sessions launch with `--permission-mode auto`**. The zshrc cooperator launches the new Claude session with permissions auto-granted, so the build can keep moving across the handoff without re-prompting you. The pickup files live under `~/.claude/state/handoff/` (mode 700 dir, mode 600 files, owner-checked before exec) — same-user processes could in principle plant a prompt there, but a different user cannot. If that's not your threat model, remove `--permission-mode auto` from `zshrc-snippet.sh` before installing, or skip the snippet entirely (handoff degrades to "open a new tab and run claude yourself").

## What's deliberately not here

This is the build system. It is not the maintainer's full setup. Excluded by design: project-specific scripts, content/lifestyle skills, personal memory, project paths.

## License

MIT. Adapt freely.

---

This kit is one developer's setup, opened up. If something breaks on your machine, the failure modes most likely live at the dependency boundaries (Codex CLI, gstack, vibecop) — read [ARCHITECTURE.md](ARCHITECTURE.md) to understand which piece is doing what before debugging.
