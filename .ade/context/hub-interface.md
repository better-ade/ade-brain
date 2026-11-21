# The hub commands `ade` calls (story H1)

The hub side of ade-cli's `.ade/context/hub-interface.md` (`ade setup`, A5; `ade ui` and `ade dash`, A6). `ade` exports
`HUB`, runs `<hub>/bin/<script>` and returns its exit code unchanged. Change a line here only together with ade-cli.

## `bin/agent --live-test <provider[:model]> [--dir <folder>]`
- Task: always `Reply with the word READY and nothing else.`; stdin is never read. No folder context, no tools
  (`--tools ""`). Model default `haiku` (a slot alias; an `anthropic` model must pass `anthropic_model_ok`).
- Folder: `--dir` must be absolute and an empty directory, never `/`, `$HOME`, inside the hub, inside a git work tree,
  or an ancestor of the hub or `$HOME` (else exit 2); the caller removes it. Without `--dir`: `mktemp -d
  /tmp/agent-live.XXXXXX` (`TMPDIR` ignored), the same checks, removed by `agent.py` at the end of the run and by its
  watchdog when `agent.py` is killed (`AGENT_RUN_OWN_DIR`; only a real `/tmp/agent-live.*` directory is removed).
- Same run as `bin/agent --role` (`exec python3 agent.py`, so signals reach it: allowlisted environment, own process
  group, `AGENT_TIMEOUT`, isolation flags, provider settings and config dir), journaled as `role=live-test folder=-`.
  Every `candidate_refusal` check applies (`read` mode: the key is read once) except `HUB_PROVIDERS_ALLOWED`.
  Claude Code asks before `Bash(*bin/agent --live-test*)` in every folder session and at the hub root.
- Unset before the run (and never in the engine's allowlisted environment): `ANTHROPIC_*`, `CLAUDE_CODE_OAUTH_TOKEN`,
  `CLAUDE_CODE_USE_*`, `*_API_KEY`, `*_AUTH_TOKEN`, `TELEGRAM_BOT_TOKEN`.
- Output: the engine's stdout (first 4 KB, keys hidden). Exit 0 only when the whole output (at most 4 KB, strict
  UTF-8) trimmed of whitespace is exactly `READY`. Exit 1 otherwise, the last line `agent: live test of <p>:<m> failed:
  <why>; details: <err file>`, where `<why>` is a refusal, `the output is not exactly READY; it said: <last line>` or
  the engine failure plus its last line (keys hidden). `gemini` (no engine until E1) and `muse` (no provider row) exit 1.
  Exit 2: usage, a bad id, model or folder, or a stored Anthropic key that cannot be read or is empty.
- Hidden (`agent.py --redact`, which `redact` in `bin/lib.sh` runs): escape sequences and control characters (except
  tab and newline) are removed first, then `[0-9]{6,12}:[A-Za-z0-9_-]{30,}` (bot token), `[A-Za-z0-9]{16,}\.[A-Za-z0-9_-]{8,}`
  (GLM-style `<id>.<secret>`), `(sk|pk|ak|key)-[A-Za-z0-9_-]{8,}`, any `[A-Za-z0-9_-]{32,}` run.

## `bin/keys` and the Anthropic API key (ADR 0002)
- `anthropic` is a `key_tools` entry: Keychain name `anthropic-api-key`, `bin/keys set anthropic` (stdin or hidden
  prompt; it prints one line saying where the key is used), `bin/keys forget anthropic`; the list prints
  `anthropic   stored|missing   anthropic-api-key` like every tool (`ade` matches `^<tool> +stored`).
- A stored key is used through a 0600 `--settings` file holding `apiKeyHelper` = `HUB=<hub>
  AGENT_KEYCHAIN_SERVICE=<service> <hub>/bin/secret anthropic-api-key` (`anthropic_settings_write`), never an
  environment variable, and read once before launch (`anthropic_key_ok`). It is used by `--live-test anthropic`, and by
  `bin/agent --role` runs only when `hub.conf` sets `HUB_AGENT_ANTHROPIC_KEY=1` (unset before `hub.conf` is read, so the
  environment cannot set it); otherwise the Claude login, no settings file and no Keychain call.
  `bin/work`, `bin/chat start` and `ade claude` always use the Claude login.

## `bin/chat logs [-n N]` and `bin/chat test [channel]`
- `logs`: the last N lines (1 to 10000, default 50; else exit 2) of `<state dir>/logs/chat.log` through `redact`;
  no log = nothing, exit 0.
- `test`: channel default `telegram` (unknown exit 2). Exit 1, nothing sent, while the orchestrator runs, while its
  launchd job `ai.agent-hub.<hub>.chat` is loaded (`launchctl print`; this hub has no systemd unit yet), while another
  `bin/chat` holds `<state dir>/chat/lock` (the test holds it until it ends), without a stored token, with a token not
  shaped `<digits>:<30+ chars>`, or with an `access.json` whose `allowFrom` is not exactly one id.
- Then a peek: `getUpdates timeout=0` with no offset (it confirms nothing). A failed peek exits 1, and so do pending
  updates ("N unread messages; start the orchestrator first"); neither sends or consumes anything. Then one
  `sendMessage` to that id, and `getUpdates` long polls (at most 20 s each; an offset only once an update was seen)
  until a message from that chat arrives, which is then confirmed (exit 0, "reply received"), or
  `AGENT_CHAT_TEST_TIMEOUT` (default 120, 1 to 600) passes (exit 1, "no reply"). Updates that arrive during the test
  are confirmed. A failed send exits 1 with the API's description.
- The token goes to `curl -q` (first argument: no `.curlrc`) in a config on stdin, written by the printf builtin, with
  `SSLKEYLOGFILE` unset: never an argument, the environment or the output.

## `bin/inbox --count [main|<folder>|<name>]`
- Target: `main` (default), `projects/<n>` or `ops/<n>`, a `bin/sessions` NAME (the registry entry's `folder=`), else a
  bare folder name naming exactly one folder; otherwise exit 2. Prints one number, exit 0 (1 when the log is unusable).
- The count is per folder, not per Claude session: every session of a folder (several tickets) shares one read position.
- Counts the events `for_me` (events.md routing) after `<state dir>/events-read/<main|folder>` (`<inode> <offset>`),
  which every delivery (`bin/inbox` hook, `bin/changes`) writes for its folder; with none, what that folder's first
  delivery would show (its notes of the last 24 h). Reads no stdin, writes nothing.

## `bin/dispatch --list [folder]`
- One `<state><TAB><ref><TAB><folder>` line per ticket, in `tickets next` order: `ready` (ready_to_start, low or medium
  risk, no hitl: starts when a slot is free), `waiting` (ready_to_start needing the owner: high, unset or unverifiable
  risk, or hitl), `running` (a ready_to_start or in_progress ticket whose session or recent start marker runs).
  Refine, blocked and idle in-progress tickets are not listed.
- Every folder by default (one without exactly one BMAD checkout is skipped); a named folder without one exits 1, an
  unknown folder 2. `tickets next` or `bin/sessions` failing exits 1. No lock, no `bin/work`, no marker removed or
  made, no journal line. It does run `bin/sessions`, which prunes the registry entries of sessions whose launcher is gone.
