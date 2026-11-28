# {{NAME}}

{{OWNER}}'s AI **{{TITLE}}** for **{{CLIENT}}**, made from
[ade-brain](https://github.com/better-ade/ade-brain). It holds the **context, state and
history** of the work and runs Claude Code agents that know them. Client code stays in its own repos.

## Use it

1. `ade`: your workspace, with the main agent in tab 0 and a tab per agent (`ade claude`: the
   main agent at the hub root). Without `ade`, run `claude` at the hub root. Either way the session starts with every folder's state and
   the recent journal.
2. On a new Mac or a fresh clone, `bin/setup` once (links Claude's memory and the BMAD skills, sets the git hooks;
   `ade hub import` runs it for you). `ollama pull nomic-embed-text` and `bin/brain index` for searchable memory.
3. `ade doctor` (the hub's `bin/doctor`) until what you need is OK. AI tool keys: `ade keys` asks for the missing ones
   at a hidden prompt. Other secrets `bin/doctor` checks: `bin/secret --set <name>`.
4. `bin/schedule install`: the weekday morning briefing, `bin/monitor` and `bin/sync --auto` (both every 30 minutes).
   Auto sync off: `HUB_AUTO_SYNC=0` in `hub.conf`, then `bin/schedule install` again.

## Who does the work

A task runs one of four ways; the main agent names the one it picks when it starts a task:
- **Ask in plain words** (a subagent): the main session hands the task to that project's agent and reports back. The usual way.
- **Deep work** (a focus agent): a full session in the project's code, in its own tab, reporting to the main session.
- **`ade dispatch`**: one focus agent per ready ticket; a high-risk ticket waits for {{OWNER}}'s yes.
- **A second opinion** (a role run): read-only work on another AI model; it reports, never edits.

## Folders

{{FOLDER_LIST}}

## Commands

| Command | Does |
|---|---|
| `bin/context [folder]` | every folder's state, or one folder's state and journal |
| `ade work <folder>`, `bin/work [opts] <folder> [repo]` | deep work in the folder's repo checkout, as the caller's Claude install and account (`CLAUDE_CONFIG_DIR`): `ade work` opens it as a tab of `ade`'s workspace; `bin/work` on its own opens a new Terminal window on macOS (a sub-terminal inside the ADE app), a tmux window on Linux |
| `bin/review [folder]` | a read-only summary of this hub: whose it is, what is in progress, recent work, memory, reach, agents and skills |
| `bin/journal <folder> "<text>"` | one dated journal entry |
| `bin/new projects/<name>` / `ops/<name>` | a new folder plus its agent |
| `bin/brain search "<words>"` | search every section of the hub (keywords + meaning); `bin/brain index` refreshes |
| `bin/learn confirm`, `bin/learn list\|show\|edit\|forget` | what the hub learned about you (`memory/users/<you>/`): agents capture with `bin/learn feedback` and `bin/learn profile`; nothing loads until you confirm it in your own terminal; then each session starts with your rules for that folder |
| `bin/remote <cmd>` | a command on the remote box over SSH |
| `ade keys`, `bin/keys set <tool>` | the AI tools' keys (anthropic, deepseek, glm, muse, gemini, telegram): stored or missing; set one at a hidden prompt |
| `bin/secret <name>` | a secret from the Keychain (`--set`, `--has`, `--forget`, `--list`) |
| `bin/doctor` | what this Mac can reach; never prints a secret |
| `bin/briefing`, `bin/schedule install` | the morning briefing; the launchd jobs (briefing, monitor, sync, recover at login, chat with `HUB_CHAT=telegram`) |
| `bin/chat setup`, `bin/chat start\|stop\|status` | the main session on Telegram (paired account only) |
| `bin/recover` | after a crash or reboot: stale locks, dead agents (ticket blocked, work kept), a torn event log, a full disk; `bin/doctor` shows the same checks |
| `bin/monitor` | run every folder's `monitors.d/*.sh`; journal status changes and ALERTs, notify on ALERT |
| `bin/work --model M --agent-model [name=]M` | override this hub's models for one session (defaults in `hub.conf`; subagents with no model use an inherited `CLAUDE_CODE_SUBAGENT_MODEL`, else `HUB_SUBAGENT_MODEL`) |
| `bin/work --force <folder>`, `bin/sessions` | a second session for a folder already running (refused without it); the running sessions (`--mine`: yours) |
| `bin/sync`, then `bin/sync --yes` | review, then commit and push hub files only |
| `bin/sync --auto` | the same, unattended (the 30-minute job and each session end); log `~/.agent-hub/{{NAME}}/logs/sync.log` |

Rules: [CLAUDE.md](CLAUDE.md). Verification: `bash tests/run.sh`.
