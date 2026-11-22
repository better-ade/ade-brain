# {{NAME}}

{{OWNER}}'s AI **{{TITLE}}** for **{{CLIENT}}**, made from
[ade-brain](https://github.com/better-ade/ade-brain). It holds the **context, state and
history** of the work and runs Claude Code agents that know them. Client code stays in its own repos.

## Use it

1. `bin/setup` once per Mac (links Claude's memory and the BMAD skills, sets the git hooks); `ollama pull nomic-embed-text`
   and `bin/brain index` for searchable memory.
2. `bin/doctor` until what you need is OK. Store secrets with `bin/secret --set <name>`.
3. Start `claude` at the repo root. The SessionStart hook prints every folder's state and the recent journal.
4. `bin/schedule install`: the weekday morning briefing, `bin/monitor` and `bin/sync --auto` (both every 30 minutes).
   Auto sync off: `HUB_AUTO_SYNC=0` in `hub.conf`, then `bin/schedule install` again.

## Folders

{{FOLDER_LIST}}

## Commands

| Command | Does |
|---|---|
| `bin/context [folder]` | every folder's state, or one folder's state and journal |
| `bin/work [opts] <folder> [repo]` | deep work in a new Terminal in the folder's repo checkout, as the caller's Claude install and account (`CLAUDE_CONFIG_DIR`) |
| `bin/journal <folder> "<text>"` | one dated journal entry |
| `bin/new projects/<name>` / `ops/<name>` | a new folder plus its agent |
| `bin/brain search "<words>"` | search every section of the hub (keywords + meaning); `bin/brain index` refreshes |
| `bin/remote <cmd>` | a command on the remote box over SSH |
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
