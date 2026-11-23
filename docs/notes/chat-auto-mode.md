# Design note: the chat runs in auto mode once the bot is locked to the owner

Risk: **high** (it changes who can act through the owner's agent without a question). Owner's intent (2026-11-23):
"i think if telegram is on, auto mode should be on?", then yes to this design: auto only once the bot is locked to an
allowlist. Follows C5 and C7. Verification command: `bash tests/run.sh`.

## What changes
- `bin/chat start` with no `HUB_CHAT_MODE`: `auto` when every channel's `access.json` reads `dmPolicy` `allowlist`,
  exactly one numeric user id in `allowFrom`, and no groups; otherwise `manual`, with the line `chat: manual mode: the bot
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
- **`dmPolicy` only.** The older `policy` key is never read: not for auto, not for the unattended start, not in status.
- **An id is what the plugin compares.** A string of ASCII digits, no leading zero, up to 20; exactly one of them.
- **Chosen once per start.** A session keeps the mode it started in; `status` says when the running session's mode
  differs from what a start would use now, and how to restart.
- **Never a skip.** `auto` is Claude Code's own mode, which still refuses what it judges risky. `bypassPermissions`
  and `--dangerously-skip-permissions` stay refused in arguments, `HUB_*` settings and the claude wrapper.

## Fix round after the adversarial review (2026-11-23)
- **The session could loosen its own lock unasked.** Ask rules in `.claude/settings.json` for `Edit`/`Write` of the
  channel's `access.json` and for `Bash` commands that mention `access.json` or `channels/telegram`; and the
  forwarder checks the lock while the chat runs: a running auto session whose lock no longer holds is told to the
  owner once per change, and journaled. Chosen over stopping the session: a stop ends work in progress with nobody
  asked, and the launchd job would be disabled with it; the notice says how to restart, and the next start is manual.
- **Read as the plugin reads it.** `NaN`/`Infinity` are refused (as `JSON.parse` does); an id is a string of ASCII
  digits with no leading zero (the plugin compares `String(from.id)`), so a JSON number is not locked; the file itself
  must not be group- or world-writable; no channel is manual.
- **Locked to you is one person.** Exactly one id in `allowFrom`, as `bin/chat test` already requires.
- **Told once.** The first start the rule puts in auto sends the owner one line in the chat and journals it.
- **The unattended start uses the same lock.** It read the older `policy` key and did not look at `allowFrom`, so a bot
  the plugin treats as pairing could run with nobody watching. It now requires `lock_of`, whatever `HUB_CHAT_MODE`.

## Known limits (left for the owner to weigh)
- The ask-rule path patterns for a file outside the hub folder (`//**/...`, `~/.agent-hub/**`) follow Claude Code's
  documented forms but were not run against a real Claude Code here (tests use fakes only); the `Bash` rules and
  the lost-lock notice do not depend on them.
- `/telegram:access` typed in the session is the owner's own command; no rule asks before it. What it changes is
  caught by the lost-lock notice within one forwarder round (15 s by default; never with `AGENT_CHAT_FORWARD_EVERY=0`).
- The lost-lock notice goes to whoever is on the allowlist then, and to the journal.
- "Owned by another user" cannot be tested without a second user; the code path is the same as the tested symlink and
  unreadable cases (any failed check is "not locked").

## Tests (`tests/test_chat.sh`, scratch state folder and scratch HOME)
- `mode_follows_lock`: locked (with and without a terminal) is auto. Each of these is manual with the line in a
  terminal, refused without one, and named by its reason in `status`: pairing, disabled, an empty or missing
  `allowFrom`, the old `policy` key, groups, malformed JSON, a non-object, `NaN`/`Infinity`/`-Infinity`, an id not
  written as the plugin reads it (a number, a leading zero, a negative, non-ASCII digits and more), two people, a
  symlink, an unreadable file, a file others can write to, a folder others can write to. No channel is manual.
  `HUB_CHAT_MODE=manual` with a locked bot is manual; `plan` is plan; an explicit `auto` does not open an unattended
  start of an unlocked bot; `bypassPermissions` is refused; the status lines.
- `auto_notice_once`: the one-time notice and its marker. `lost_lock_noticed`: the notice once per change, the
  journal line, the session left running, none for a mode the owner set.
- `answer_needs_owner_permission`: the ask rules for `access.json` and the channel folder.
