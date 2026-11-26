# K3: the bot token waits for the plugin, and status says why the bot is not connected

Status: **Approved** (owner, 2026-11-26: "approve"). Risk: **high** (the Telegram bot token: how long it sits on disk).
Found by: the owner, in `ade setup --telegram` on hub narralearn (2026-11-26): "just keeps repeating". The step
"bin/chat start" was done, yet setup said "your bot has not connected to it yet" every time.
Verification: `bash tests/run.sh`.

## Today
`bin/chat start` writes the bot token to a 0600 `.env` in the channel's own 0700 state folder, then deletes it once
the plugin writes `bot.pid` **or after at most 60 s** (`AGENT_CHAT_ENV_TTL`, capped at 60). Claude Code loads the
plugin only after its startup questions are answered (trust this folder, allow channels, sign in). If the owner takes
more than 60 s to answer, the `.env` is gone and the plugin exits with "no token". The session keeps running with no
bot. `bin/chat status` says only "running, channel not connected", so setup repeats one step that cannot succeed. On
narralearn: the session ran, the plugin had no process, and the channel folder was empty.

## Goal
The token stays until the plugin has read it or the session has ended, never longer. Status names the reason the bot
is not connected, so setup can say what to do.

## Acceptance criteria (each named by its test in tests/test_chat.sh)
1. **env_kept_until_bot_pid**: with a plugin that starts late (later than the old 60 s, made short in the test by a
   stand-in time), the `.env` is still there when it starts; it is deleted as soon as `bot.pid` appears.
2. **env_gone_when_session_ends**: if the session ends without `bot.pid` (killed, `/exit`, a refused question), the
   `.env` is deleted within 2 s of the end.
3. **env_hard_cap**: whatever happens, the `.env` is deleted after at most 15 minutes (`AGENT_CHAT_ENV_TTL`, now
   capped at 900, default 900). Nothing else changes: still 0600, still written by a builtin, never an argument or
   the environment.
4. **status_reason_waiting**: running, no `bot.pid`, `.env` present: status says
   `channel not connected (the plugin has not started: answer any question in the chat session's terminal)`.
5. **status_reason_no_token**: running, no `bot.pid`, `.env` gone: status says
   `channel not connected (the plugin did not get the token: stop the session and run bin/chat start again)`.
6. **status_reason_bot_died**: `bot.pid` written but its process is gone: status says
   `channel not connected (the bot stopped: bin/chat logs)`.
7. **status_never_shows_token**: none of the status lines contains the token or any part of it (existing check
   extended to the new lines).

## Out of scope
- ade-cli's `ade setup --telegram` step. As follow-up **K3b** (low), it prints the reason from `ade chat status`
  instead of the fixed "the hub's own words" line. It is a separate PR in ade-cli, after K3 merges.
- The plugin itself, pairing, and the Keychain.
