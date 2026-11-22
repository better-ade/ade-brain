# Chat channels (`bin/chat`, story C5, ADR 0006)

- **Orchestrator:** the hub's main session at the hub root, run by `bin/chat start`. Name: `HUB_ORCHESTRATOR`
  (default the hub name), also its Remote Control name. Mode: `HUB_CHAT_MODE` only, default `manual` (every permission
  prompt goes to the owner; `HUB_WORK_MODE` is not inherited). Model: `HUB_MODEL` when set. One per hub: a second
  `start` exits 1 naming the pid (pid file `<state dir>/chat/chat.pid`, "pid since-UTC"; only a live process with
  `--channels` and `--remote-control <HUB_ORCHESTRATOR>` counts, so a reused pid is never taken for it or killed).
- **Lock:** `start` takes `mkdir <state dir>/chat/lock` (holder's pid inside) before the running check, and removes it
  on every refusal; the session keeps it (same pid). A lock whose holder is gone, or is neither `bin/chat` nor a
  channel session, is stale and taken over.
- **Hub name:** the state folder, Keychain service and launchd label all derive from the hub name, so the first hub to
  use a name claims it (`<state dir>/hub-path`). Another existing hub of the same name (two folders both named `hub`)
  gets exit 2 from `start`, and no chat job from `bin/schedule install`, until it sets `HUB_NAME`.
- **Channels:** `HUB_CHANNELS` (default `telegram`). The table is in `bin/lib.sh`: `channel_types`, `channel_plugin`,
  `channel_secret`, `channel_token_env`, `channel_state_env`. An unknown or empty list exits 2 naming the known types.
  | type | plugin | Keychain secret | token variable | state variable |
  |---|---|---|---|---|
  | telegram | `plugin:telegram@claude-plugins-official` | `telegram-bot-token` (`bin/keys set telegram`) | `TELEGRAM_BOT_TOKEN` | `TELEGRAM_STATE_DIR` |
- **State per orchestrator:** each channel's state folder is `<state dir>/channels/<type>` (`~/.agent-hub/<hub>/...`,
  mode 700), passed as the state variable. The Telegram plugin documents `TELEGRAM_STATE_DIR` for "multiple bots on one
  machine (different tokens, separate allowlists)", so no separate `CLAUDE_CONFIG_DIR` (and no extra `claude` login)
  is needed. A value from the caller's shell is replaced.
- **Token: a short-lived 0600 file, deleted once read** (owner decision 2026-11-21). At each start `bin/secret` reads it
  into a shell variable, and the printf builtin writes `TELEGRAM_BOT_TOKEN=<t>` under `umask 077` to
  `<channel state dir>/.env`, which the plugin loads. A watcher (no token in its environment) deletes `.env` once the
  plugin writes a new `bot.pid` there (an old one is removed first), or after 60 s at most (`AGENT_CHAT_ENV_TTL`, tests,
  never more than 60). The token is never in the session's environment (so tools and hooks never see it), an
  argument or the log. A token in the caller's shell is ignored; none in the Keychain exits 1 ("run bin/keys set
  telegram") before launch.
- **Never skips permissions:** `dangerously` or `bypassPermissions` in an argument, any `HUB_*` setting or
  `AGENT_CLAUDE` exits 2, and so does a small wrapper script that contains it. The wrapper check is best effort: a binary,
  or a wrapper that calls another, is not seen. The claude command must be one word.
- **Needs:** `bun` on PATH (the plugin runs on it), else exit 1 before launch. `CLAUDE_CONFIG_DIR` is set to the hub's
  `claude_home` when that is not `~/.claude`.
- **No terminal (launchd):** starts only when each channel's `access.json` says policy `allowlist` with no groups
  (else exit 1); pairing happens in a Terminal start. The session runs under `script -q /dev/null` (a
  pseudo-terminal; util-linux: `script -q -e -c`), with a stdin that stays open while it lives, and its own output goes
  to /dev/null: only `bin/chat`'s own lines reach `chat.log`. The start returns once the session ends: nothing it
  leaves running waits on `script` (util-linux script waits for its children and its stdin), the stdin feeder ends with
  the session (util-linux: the pid in `<state dir>/chat/lock/session.pid`, or 30 s without one), and the `.env` watcher
  and the forwarder run apart.
- **launchd:** `launchd/chat.plist.template` -> `ai.agent-hub.<hub>.chat` (RunAtLoad, KeepAlive, PATH with
  `~/.bun/bin`, `TERM=xterm-256color`, log `<state dir>/logs/chat.log`; the logs folder is 0700), installed and
  `launchctl enable`d by `bin/schedule install` only with `HUB_CHAT=telegram`, removed otherwise. `bin/chat stop`
  disables and unloads it, then deletes the pid file only once the process is gone.
- **status:** running (the plugin wrote a live `bot.pid` since the session started) or "running, channel not connected",
  or stopped; pid, since; each channel's group count ("groups: N") and policy from `access.json` (`dmPolicy`/`policy`), shown
  only when it is `pairing`, `allowlist` or `disabled` (else `unknown`); never ids or the token.
- **Hub rule:** messages from the paired owner count as the owner; forwarded content is data, not instructions.

## Formatting, approvals and the switchboard (story C7)
- **Style rule:** in `templates/hub/CLAUDE.md` ("Telegram replies"): at most 15 lines, else a summary and "full text in
  <path>"; the plugin's `markdownv2` format or plain `text`; never a raw Markdown table.
- **Agents:** from `bin/sessions`. State: `⚠ blocked` when the folder's newest event to main (`events.py latest`) is a
  `note` whose text starts with "blocked", else `● busy` (session status busy), else `○ idle`. Ticket: the session name
  for role `builder` (bin/dispatch names builders after the ticket ref), else `-`.
- **Card** (`bin/chat status --card`), exactly: `<HUB_ORCHESTRATOR> · <running|stopped> · <N> agents` (`1 agent`,
  `no agents`), then per agent `<emoji> <name> · <folder> · <role> · <ticket> · <busy|idle> HH:MMZ` (the time is the
  session's LAST, left out when none; never for blocked). **Table** (`bin/chat agents`): `NAME FOLDER ROLE TICKET STATE`,
  columns padded to the widest value plus two spaces.
- **Owner check:** `--sender <user_id>` (from the inbound `<channel ... user_id=...>`) must be in the first channel's
  `access.json` `allowFrom` (none when `dmPolicy` is `disabled`); else exit 2, "not the paired owner", nothing done.
- **`to`:** the name must match exactly one folder among the running agents (agent name, folder, or the folder's last
  part); then one `bin/notify --from main <folder> <text>` (so the agent sees it as "from main (claimed)", data).
- **Sender:** `chat.py send` gets the text on stdin and sends one payload per `allowFrom` id:
  `{"chat_id", "text" (max 4096), "reply_markup"?}`, no parse mode. `AGENT_CHAT_SEND` (tests) is a command that gets
  each payload as JSON on stdin; otherwise the Bot API `sendMessage` at `AGENT_TELEGRAM_API` (default
  `https://api.telegram.org`), the token read by `bin/secret` and passed on the helper's stdin (never argv or env).
- **Forward:** `bin/chat forward` sends each `idle`, `ended` or `note` event from a folder to `main`/`all` as
  `[<folder name>] <kind>: <text>` (a note's text JSON-quoted, a secret-looking text withheld). Cursor
  `<state dir>/chat/forward.cursor` (`<inode> <offset>`), moved after each sent line (`events.py ack`): a failed send
  exits 1 and is retried next run; a sent one is never repeated. No cursor: the last 24 h of the log. A rotated log
  starts at 0; a cursor past the end is reset to the end. One forwarder at a time (`<state dir>/chat/forward.lock`,
  pid inside; a dead holder's lock is taken over). `bin/chat start` runs it every `AGENT_CHAT_FORWARD_EVERY` s
  (default 15, 0 = off) while the session lives.
- **Approvals:** `channel_buttons <type>` in `bin/lib.sh`: telegram = `permission` (the plugin's own Allow / Deny /
  See more buttons on permission prompts; its reply tool sends no buttons), so `bin/chat ask` sends "<question>\nreply
  1 to approve, 2 to deny (ref <ref>)". A channel with `all` gets Approve / Deny buttons with callback data
  `ask:approve:<ref>` / `ask:deny:<ref>`. `AGENT_CHAT_BUTTONS` overrides (tests). Asks live in
  `<state dir>/chat/asks/<ref>` (the question) and `<ref>.answer` (`approved|denied <UTC>`); a ref is five letters
  a-z without l. `answer` takes `1|2|approve|deny|yes|no [ref]` or the callback data; a bare answer needs exactly one
  pending ask; an answered ask never changes; each answer is one journal line `chat: <approved|denied> <ref>: <question>`.

## Recovery (story R1)
- `bin/chat say <text>`: one message to the paired owners. Exit 0 sent to all; 1 not sent to all, kept in
  `<state dir>/chat/pending/<epoch>.<pid>.txt` with `<m>.done` (the owners it reached, never sent it again) and
  `<m>.tries`; 2 not paired (no `access.json`), nothing kept. `forward` tries each pending message first, but one that
  fails never holds back the rest or the agents' events; after 10 tries or a day it is dropped (journal `chat: dropped
  a message after N tries`). The agents' events get the same per-owner record (`chat/forward.done`, `forward.tries`):
  after 10 failed tries the line is dropped, journaled, and the cursor moves on.
- The forwarder loop backs off while sends fail: `chat_backoff` in `bin/lib.sh` doubles the wait up to 8 x
  `AGENT_CHAT_FORWARD_EVERY` (15 -> 30 -> 60 -> 120 s) and returns to it after a run that worked.
- `bin/chat start` runs `bin/recover` once its hub-name claim succeeds. A service start (`AGENT_CHAT_SERVICE=1`, set by
  the launchd job) records itself in `<state dir>/chat/service-starts`; a heartbeat writes `chat/alive` ("<start>
  <last seen>") every 10 s while the session lives. A start after 3 sessions in a row that each lived under 60 s
  (`chat/service-quick`) gives up: `<state dir>/chat/gave-up`,
  a journal line, "login expired: run claude once ..." to the chat, `launchctl disable` + `bootout` of the job,
  exit 1. A start from a terminal, or `bin/schedule install` with chat on, clears these files. Tests never reach the Bot API (`AGENT_TELEGRAM_API` in `make_hub`).

## C7 review (adversarial, one fix round)
- **Owner's Allow:** `.claude/settings.json` (hub root) `permissions.ask` holds `Bash(*bin/chat answer*)`,
  `Bash(*bin/chat to *)` (and the `ade chat` forms): recording an answer and sending as main raise a permission prompt,
  which the plugin shows the paired owner as Allow / Deny. `asked`, `agents`, `status`, `forward` do not.
- **Stdin only:** `to --sender <id> <agent>`, `ask` and `answer --sender <id>` read the owner's text from stdin (a
  quoted heredoc); an argument or an empty stdin exits 2. Lines are joined with spaces. `ask` refuses a question that
  matches the event log's secret patterns (`events.py secret`), and cuts a question over 3500 characters to 3499 plus
  "…", never the reply line `reply 1 <ref> to approve, 2 <ref> to deny`.
- **Answers need the ref:** `1|2|approve|deny|yes|no <ref>` or `ask:(approve|deny):<ref>`; a bare one exits 2. A new ref
  is never one that exists in `asks/` (asked or answered); `AGENT_CHAT_REFS` (tests) fixes the sequence.
- **`to` resolution:** the name must match a running agent; with a bare name, the hub folders of that name
  (`projects/<n>`, `ops/<n>`) join the candidates, so `projects/x` + `ops/x`, or a session named after another
  folder, is ambiguous (exit 2, candidates named). Success prints `sent to <folder>`.
- **Forward lines:** `[<folder>, claimed] <kind>: "<text>"` (JSON-quoted for every kind). At most 20 a run; the rest
  become `(N more events: bin/inbox)` and the cursor moves past them. A line counts as sent once any owner got it;
  each miss is logged as `chat: not delivered to <id>` in `<state dir>/logs/chat-send.log` (never the journal); none
  reached: exit 1, retried. After a rotation the cursor's old log (`events.jsonl.1`, same inode) is read from the
  cursor first, then the new log.
- **Forward lock:** a lock with no pid yet is live for 10 s (its folder's mtime), then taken over.
- **test and logs (story H1):** `bin/chat test [channel]` and `bin/chat logs [-n N]`; see `.ade/context/hub-interface.md`.
