# Chat channels (`bin/chat`, story C5, ADR 0006)

- **Orchestrator:** the hub's main session at the hub root, run by `bin/chat start`. Name: `HUB_ORCHESTRATOR`
  (default the hub name), also its Remote Control name. Mode: see "Who may act unasked" below (`HUB_WORK_MODE` is not
  inherited). Model: `HUB_MODEL` when set. One per hub: a second
  `start` exits 1 naming the pid (pid file `<state dir>/chat/chat.pid`, "pid since-UTC"; only a live process with
  `--channels` and `--remote-control <HUB_ORCHESTRATOR>` counts, so a reused pid is never taken for it or killed).
- **Lock:** `start` takes `mkdir <state dir>/chat/lock` (holder's pid inside) before the running check, and removes it
  on every refusal; the session keeps it (same pid). A lock whose holder is gone, or is neither `bin/chat` nor a
  channel session, is stale and taken over.
- **Who may act unasked (the chat mode; owner decision 2026-11-23):** `HUB_CHAT_MODE` (`auto`, `manual`,
  `acceptEdits`, `plan`) always wins, `manual` included. With none set, `start` picks the mode from each channel's own
  `access.json`, read as found at that start and as the plugin reads it:
  - **`auto`** only when there is a channel and every channel in `HUB_CHANNELS` is **locked to the owner**: `dmPolicy`
    is `allowlist` (the older `policy` key is never read); `allowFrom` holds **exactly one** id, a string of ASCII
    digits with no leading zero (the plugin compares `String(from.id)`: a JSON number, a negative id, which is a
    group, or anything else is not one); and there are no groups (`groups` absent, null or empty). Then the
    orchestrator acts on the paired owner's Telegram messages with no question at the terminal; Claude Code's auto
    mode still refuses what it judges risky, and nothing skips permissions.
  - **`manual`** otherwise (every permission prompt goes to the owner), with the line `chat: manual mode: the bot is not
    locked to you yet; in the session: /telegram:access policy allowlist`.
  - The file is read by `python3 -I` (json, refusing `NaN` and `Infinity`, which the plugin's `JSON.parse` refuses),
    never by a text match. It must be a plain file owned by the user running `bin/chat` that nobody else can write
    to, opened without following a symlink and checked on the open file, in a channel state folder that is a real
    folder of that user's which nobody else can write to. Missing, unreadable, malformed, a symlink, another user's,
    group- or world-writable, over 1 MB, or not a JSON object: **not locked**.
  - The reasons (`lock_of`), fixed words, never an id: `not paired yet`, `the policy is <pairing|disabled|unknown>`,
    `it has groups`, `nobody is on the allowlist`, `an id is not written as the plugin reads it`, `more than one
    person is on the allowlist`, `the access file cannot be read`, `the access file is not a plain file of yours`,
    `the access file can be written by others`, `the state folder is not yours alone`; with no channel, `no channel`.
  - `start` prints the mode in one line: `chat: auto mode: the bot is locked to you, ...`, the manual line above, or
    `chat: <mode> mode (HUB_CHAT_MODE)`.
  - **Told once.** The first start the rule puts in auto (marker `<state dir>/chat/auto-told`) sends the owner one
    `bin/chat say` line ("your chat now runs in auto mode: ... HUB_CHAT_MODE=manual in hub.conf turns it off") and
    journals it. A mode the owner set is not announced.
  - **Without a terminal** (the launchd or systemd job runs the same `bin/chat start`) the same lock is required to
    start at all, whatever `HUB_CHAT_MODE` says (exit 1 otherwise): an unattended bot is always locked.
  - **The mode is chosen once per start.** A session started before the lock stays in its mode until `bin/chat stop`
    and a new start. **A lock lost while an auto session runs** (the plugin re-reads `access.json` at every message):
    `bin/chat forward`, which runs every 15 s beside the session, checks the lock; when a running session that the
    rule put in auto is no longer locked it sends the owner "your bot is no longer locked to you (<reason>); the chat
    stays in auto until you restart it: bin/chat stop, then bin/chat start" and journals it, once per change of
    reason (marker `<state dir>/chat/lock-lost`, cleared when the lock holds again and at each start). It does not
    stop the session: that would end work in progress with nobody asked; the next start is manual. Not for a mode the
    owner set.
  - **The session may not loosen its own lock unasked.** `.claude/settings.json` `permissions.ask`: `Edit`/`Write` of
    `**/channels/*/access.json` (also `//**/...` and `~/.agent-hub/**/access.json`), and any `Bash` command that
    mentions `access.json` or `channels/telegram`. Ask rules hold in auto mode. `/telegram:access` typed by the owner
    in the session is the owner's own act; what it changes is caught by the lost-lock notice.
  - Never `bypassPermissions` (below).
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
- **No terminal (launchd):** starts only when each channel is locked to the owner by the rule above (`dmPolicy` only;
  else exit 1); pairing happens in a Terminal start. The session runs under `script -q /dev/null` (a
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
  or stopped; pid, since; each channel's line `<type>: policy <name>, groups: <N>, <locked to you|not locked>` (the
  policy from `access.json` `dmPolicy`, shown only when it is `pairing`, `allowlist` or `disabled`, else
  `unknown`; the lock by the rule above), or `<type>: not paired yet (...)`; then the last line, the mode a start
  would use: `mode: auto (<channels> is locked to you; HUB_CHAT_MODE=manual in hub.conf turns it off)`,
  `mode: manual (not locked: <type>: <why>; in the session: /telegram:access policy allowlist)`, `mode: <mode>
  (HUB_CHAT_MODE)` or `mode: refused (...)` for a value `start` refuses. When a running session's
  `--permission-mode` differs, the line ends `; the running session is in <mode>: bin/chat stop, then bin/chat start`.
  `<why>` is one of a fixed set of phrases. Never ids or the token. Other tools read the lock and the mode from these
  lines, never from `access.json` themselves.
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

## Sending an image or a file (`bin/chat send`)
- **`bin/chat send [--document] <file>`**, the caption (optional) on stdin. Without `--document`: one image, PNG or
  JPEG by its first bytes (never by its name), at most 10 MB, sent with the Bot API's `sendPhoto`. With `--document`:
  any one file, at most 20 MB, sent with `sendDocument`. One multipart request over HTTPS from python3's standard
  library (`chat.py file photo|document <path>`).
- **Only to the locked owner:** it sends only when `lock_of` says the first channel is `locked` (the auto-mode rule:
  `dmPolicy` `allowlist`, exactly one id, no groups), and to that one id. Not paired or not locked: exit 2, with
  `lock_of`'s reason, nothing sent. `chat.py` reads the id again under the same rule.
- **Files that are never sent** (exit 2): anything that is not a regular file (a link, a folder, a pipe; the file is
  opened once without following a link and checked on the open file), an empty file, a file over its cap, a `.env`
  (`.env`, `.env.*`, `*.env`), and any file whose real path is under the hub's state folder, `~/.agent-hub`, `~/.ssh`,
  `~/.config`, `~/.aws`, `~/.gnupg`, `~/.claude`, `~/.kube`, `~/.docker` or `~/Library/Keychains`.
- **Token:** read as `say` reads it (`bin/secret` to the helper's stdin, first line); it is in the request's address
  only: never an argument, the environment of a child, a log, the journal or the output. A failure prints the Bot API's
  own `description` (the token replaced if it were in it), never the address. `AGENT_TELEGRAM_API` must be an `https://`
  address (plain `http://` only for `127.0.0.1` and `localhost`, the tests' stand-in).
- **Caption:** one line, control characters removed, keys and tokens hidden (`redact`), cut to 1024 characters. The
  file's name in the request is its own name with anything but letters, digits, `.`, `_` and `-` replaced by `_`.
- **Exit codes:** 0 sent (prints `sent <name> to the paired owner`; one journal line with the name and size); 1 not
  sent (no token, the API failed or refused). Nothing is kept for a retry: the file stays where it was. 2 refused.
- **Owner's Allow:** the hub root's `.claude/settings.json` and every focus folder's (`templates/folder-settings.json`)
  hold `Bash(*bin/chat send*)`, `Bash(*ade chat send*)`, `Bash(*ade shot screen*)` and `Bash(*ade shot*--tg*)` in
  `permissions.ask`: an agent's send, and `ade shot screen` (a capture of the whole screen, ade-cli story A20), run
  only after the owner's own Allow. That prompt is the approval `ade shot screen --yes-screen` relies on.
- **Fake channel (tests):** with `AGENT_CHAT_SEND`, the fake gets `{"chat_id", "kind", "file", "name", "bytes",
  "caption"}` as JSON on stdin and no token is read.
