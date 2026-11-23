# Design note: the chat runs in auto mode once the bot is locked to the owner

Risk: **high** (it changes who can act through the owner's agent without a question). Owner's intent (2026-11-23):
"i think if telegram is on, auto mode should be on?", then yes to this design: auto only once the bot is locked to an
allowlist. Follows C5 and C7. Verification command: `bash tests/run.sh`.

## What changes
- `bin/chat start` with no `HUB_CHAT_MODE`: `auto` when every channel's `access.json` reads `dmPolicy` `allowlist`, a
  non-empty `allowFrom` of numeric user ids, and no groups; otherwise `manual`, with the line `chat: manual mode: the bot
  is not locked to you yet; in the session: /telegram:access policy allowlist`. One line says the mode at each start.
- An explicit `HUB_CHAT_MODE` always wins, `manual` included.
- `bin/chat status` ends with `mode: <mode> (<why>)`, and each channel's line ends `locked to you` or `not locked`, so
  other tools (the `ade` guide) read the lock from the hub and the rule lives in one place (`lock_of` in `bin/chat`).
- The launchd and systemd jobs run the same `bin/chat start`, so the rule is the same there. The refusal of an
  unattended start with groups, or without an allowlist, is unchanged.

## Decisions
- **Fail closed.** The file is parsed by `python3 -I` (json). It must be a plain file of the user's own, opened with
  `O_NOFOLLOW` and checked with `fstat` on the open file (no check-then-open gap), in a channel folder that is the
  user's own and not writable by anyone else. Anything else is "not locked": manual.
- **`dmPolicy` only.** The older `policy` key still counts for the unattended-start refusal (unchanged), not for auto.
- **Numeric ids are user ids.** Digits only (ASCII), up to 20; a negative id is a group or channel, so it is not a lock.
- **Chosen once per start.** A session keeps the mode it started in; `status` says when the running session's mode
  differs from what a start would use now, and how to restart.
- **Never a skip.** `auto` is Claude Code's own mode, which still refuses what it judges risky. `bypassPermissions`
  and `--dangerously-skip-permissions` stay refused in arguments, `HUB_*` settings and the claude wrapper.

## Known limits (left for the owner to weigh)
- A running auto session is not stopped when `access.json` changes under it (a group added in the session): the new
  state counts from the next start. The plugin itself decides who gets in at every message.
- "Owned by another user" cannot be tested without a second user; the code path is the same as the tested symlink and
  unreadable cases (any failed check is "not locked").

## Tests (`tests/test_chat.sh`, `mode_follows_lock`, scratch state folder and scratch HOME)
locked (with and without a terminal) is auto; pairing, disabled, an empty or missing `allowFrom`, the old `policy` key,
groups, malformed JSON, a non-object, a non-numeric or negative or non-text id, a symlink, an unreadable file and a
folder others can write to are each manual with the line; groups still refuse an unattended start;
`HUB_CHAT_MODE=manual` with a locked bot is manual; `plan` is plan; `bypassPermissions` is refused; the status lines.
