# C9: Telegram as the console for focus agents

Status: Built (2026-11-24), not Done until `bash tests/run.sh` passes for the reviewer. Risk: high (routes chat to running agents; logs and screenshots leave the machine).
Depends on C5, C6, C7 (`/agents`, `/to`), C8 (`bin/chat send`), the Done-last fix, and ADR 0007 (Telegram widgets
without callbacks).
Owner's intent (2026-11-24): "I'd like the user to see all the focus agents via telegram and asks for updates and view
logs"; "also post images and screenshots on telegram too"; "let's maximize the telegram widgets to enhance user / dev
experience".
Verification command: `bash tests/run.sh`. Proof: ade-drill D4 shows each widget in the "build a website" flow, on a
phone (command links tappable, board pinned and edited, album, thread).

## Today and the gap
C7 gives `/agents` (a text card) and `/to <agent> <text>`; C8 gives `bin/chat send` (a photo or file to the owner).
There is no per-agent log view, no "what are you doing" without typing `/to`, no screenshot an agent posts on its own,
and no one-tap actions. The official Telegram plugin is the only poller on the token and drops every button press
(`callback_query`) except Claude Code's own permission buttons, so per ADR 0007 one-tap actions are command links,
not inline buttons, and pins, edits with state, albums and the menu go through the Bot API from `bin/chat` directly.

## Goal: one live board, one tap per action
- **Live board:** one pinned message per hub, "Agents", edited in place (never re-posted) as agents start, change state
  or end: one line per agent (● busy ○ idle ⚠ blocked ✓ done), with folder, role, ticket and age of its last event,
  then its links `/update_<agent> /log_<agent> /shot_<agent> /stop_<agent>`. Sent, pinned and edited by `bin/chat`
  directly; edits coalesced to one per 5 s; its message id in `<state dir>/chat/board.json` (0600).
- **Actions** (tapped link or typed form, same code): `Update` (asks the agent for a two-line status through
  `bin/notify`; the reply comes back tagged `[agent]`), `Log` (last 50 redacted lines of that agent's session log;
  longer as a `.txt` document), `Shot` (the agent's latest screenshot), `Stop` (a one-time reply keyboard
  `/stop_<agent>_<nonce>` / `/cancel`; the nonce is single use and expires in 120 s), `Diff` (diff stat as a document).
- **Routing:** the orchestrator hands every inbound `/...` message (other than the plugin's `/start`, `/help`,
  `/status`) to `bin/chat act --from <user_id> --reply-to <message_id>` with the text on stdin (a quoted heredoc, as
  C7's owner text), which parses it, checks the
  sender is the paired locked owner, and acts. Agent names in links: lowercased, `[^a-z0-9]` to `_`, at most 32
  characters per command; unknown or ambiguous: reply lists the agents (as C7).
- **Commands** in the bot menu: `setMyCommands` with scope `chat` = the owner, at each `bin/chat start`: `/agents`,
  `/update`, `/log`, `/shot`, `/to` (a bare `/log` replies with the agents' `/log_<agent>` links).
- **Pictures:** a screenshot an agent makes (`bin/browser`, `ade shot`) in its folder's `reports/browser` is posted to
  the owner with `bin/chat send` as a photo, captioned `[agent] <what>`; 2 to 10 from one step go as one album
  (`sendMediaGroup`, caption on the first).
- **Task thread:** each task's messages reply (`reply_parameters`) to the owner's request, whose id comes from the
  inbound message; Done is the last reply and carries `/log_<agent> /shot_<agent> /diff_<agent>`.
- **Never:** `getUpdates`, a webhook, `callback_data`, or a `perm:` prefix from the hub.

## Acceptance criteria (a stand-in Bot API records every call; fake values built at runtime)
| AC | Criterion | Test |
|---|---|---|
| 1 | The board is one message, pinned once, and every agent start, state change and end edits it (`editMessageText`, at most one per 5 s, "not modified" is success); only "message to edit not found" posts and pins a new one | `board_edited_in_place` |
| 2 | Each board row carries `/update_<a> /log_<a> /shot_<a> /stop_<a>` (name normalised; a collision gets the listing); `bin/chat act` with a `--from` other than the paired owner does nothing and logs one line without the id | `links_owner_only` |
| 3 | `/update_api` and `/update api` each send one `bin/notify` to that agent and post its reply tagged as C7 tags every agent event, `[projects/api, claimed] note: ...` | `update_round_trip` |
| 4 | `/log_api` / `/log api 20` sends the last 20 lines of api's log through `redact` (a planted fake key never appears); over 4096 characters it goes as a `.txt` document | `log_redacted_and_sized` |
| 5 | A new PNG in an agent's `reports/browser` reaches the owner as a photo captioned `[agent] ...`; three from one step go as one `sendMediaGroup`; refused files (C8 AC5) never go | `screenshots_posted` |
| 6 | `/stop_api` sends a one-time reply keyboard `/stop_api_<nonce>` / `/cancel`; only that nonce, from the owner, within 120 s and once, ends the agent, and the board shows it | `stop_needs_confirmation` |
| 7 | `bin/chat start` sets the menu with the five commands, scope `chat` = owner, and never `start`, `help` or `status` | `command_menu` |
| 8 | A task's messages reply to the owner's request message id; Done is last with `/log_<a> /shot_<a> /diff_<a>` | `task_thread` |
| 9 | Across the suite the stand-in sees no `getUpdates`, `setWebhook` or `deleteWebhook`, and no hub message carries `callback_data` | `no_poller_no_callbacks` |
| 10 | No token, key or chat id appears in any argument, log, board or caption | `nothing_leaks` |

All ten checks are in `tests/test_console.sh` (with `documented`, which checks this story, ADR 0007, the contract in
`.ade/context/chat.md` and the hub rule). Where the build differs from this draft (the text on stdin, the reply tag,
`/to`), ADR 0007 says so under "As built".

## Verification
Reviewer gate (2026-11-24, b1338e8, after one fix round; merged as 35cc798):
- `bash tests/run.sh`, run alone: 44 `ok`, no `FAIL`, exit 0. Tail: `ok test_chat.sh`, `ok test_console.sh`,
  `ok test_focus_imports.sh`, `ok test_staged_change.sh`, `ok test_sync.sh`, `ok test_work.sh`, `EXIT 0`.
- CI: ci / verify pass (18m15s), ci-linux / verify pass (13m1s).
- Revert checks (first pass, dd5a134): breaking AC2 (owner check; sender id in the log), AC4 (redact; size),
  AC6 (expiry; single use; no confirmation), AC9 (`callback_data`; `getUpdates`) and AC10 (token in board.json, in an
  argument; id in chat.log) each made `tests/test_console.sh` fail.
- Adversarial pass found two material flaws, fixed in b1338e8: log lines cut before redact (a piece of a key reached
  the chat) and screenshots over the 30-a-run cap dropped, then re-posted every 15 s past 500 files. Fix checks:
  undoing each fix fails its new check ("a piece of a key across the cut reached the chat"; "every file of the backlog
  posted: got [30] want [520]"; "never posted twice"; "a nonce under another name stopped its agent"; "the one free
  number"). The key repro now shows `<hidden>`; the 520-file simulation posts each file once (30 a run, then 10, then 0).
- Residual risk accepted: a local process of the owner's user can run `act --from <owner id>` and read a pending stop
  nonce in the state folder; every answer goes only to the locked owner (ADR 0007, "As built").
