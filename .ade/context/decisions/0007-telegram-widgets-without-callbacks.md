# 0007: Telegram widgets without callbacks

- Status: Accepted (architect, 2026-11-24; built in story C9).
- Context: C9 wants inline buttons (Update, Log, Shot, Stop), a pinned board edited in place, a bot command menu,
  photo albums and reply threads. The hub's Telegram channel is the official Claude Code plugin
  (`telegram@claude-plugins-official`, `server.ts`), kept by the owner's route D (2026-11-23). It is the only
  `getUpdates` poller on the token, and must stay so (a second poller or a webhook takes updates away from it; the
  plugin exits after 8 409 Conflicts). What the plugin does, from its source:
  - **callback_query:** handled only when the data matches `perm:(allow|deny|more):<5 letters>`, Claude Code's own
    permission relay. Any other callback is answered empty and **dropped; it never reaches the session**.
  - **Inbound text:** every `message:text` from an allowlisted sender reaches the session as a `<channel>` message with
    `chat_id`, `message_id`, `user`, `user_id`, `ts`. There is no `reply_to_message` id in the meta. The plugin handles
    `/start`, `/help` and `/status` itself and does not pass them on, so a deep-link `/start <payload>` never reaches
    the session.
  - **Tools:** `reply` (text, `reply_to`, `files`: each file sent alone with sendPhoto or sendDocument, so no albums; no
    `reply_markup`), `edit_message` (editMessageText text only; no `reply_markup`, so an edit would drop inline
    buttons), `react`, `download_attachment`. There is no pin, no setMyCommands, no sendMediaGroup, no keyboards.
  - **Menu:** at every poll start the plugin calls setMyCommands (`start`, `help`, `status`) with scope
    `all_private_chats`.
  - Outbound Bot API calls from anywhere else (the hub's `bin/chat say` and `bin/chat send`: sendMessage, sendPhoto,
    sendDocument, token from the Keychain through `bin/secret`, never in the environment, an argument or a log, only to
    the paired locked owner) do not conflict with the poller.
- Decision:
  1. **No inline callback buttons for hub actions.** Callbacks cannot reach the hub without a second poller or a
     changed plugin. Rejected routes: forwarding callbacks as messages (needs a fork of the official plugin, against
     route D, lost on each plugin update; can be revisited if the plugin ever forwards callbacks, superseding this
     record); a deep-link `/start` payload (the plugin swallows `/start`, and each tap takes two steps). The hub never
     sends `callback_data`, and never a `perm:` prefix (that prefix answers Claude Code's own permission prompts).
  2. **Buttons are tappable commands.** Telegram turns `/word` in a bot's message into a link; one tap in a private
     chat sends that text, which the plugin forwards as an ordinary owner message. Each action has a one-word form,
     `/<action>_<agent>` (`/update_api`, `/log_api`, `/shot_api`, `/stop_api`, `/diff_api`), and a typed form with
     arguments (`/log api 20`, `/to api <text>`). The agent part is the agent name lowercased, every character outside
     `[a-z0-9]` turned into `_`, the whole command at most 32 characters; a name that does not resolve to one agent gets
     the C7 listing. Typed and tapped forms run the same code. Numbered replies stay as C7's fallback for channel types
     that render no command links.
  3. **Confirmations use a one-time reply keyboard** (sendMessage with `reply_markup.keyboard`, `one_time_keyboard`),
     whose buttons send plain text: `Stop api` gets a keyboard of `/stop_api_<nonce>` and `/cancel`. The nonce is 4
     digits, single use, expires after 120 s. Without the keyboard the owner can type the same text.
  4. **Parsing is deterministic, in `bin/chat act`.** The orchestrator's rule (hub CLAUDE.md) is: an inbound channel
     message that starts with `/` and is not a plugin command goes to
     `bin/chat act --from <user_id> --reply-to <message_id>`, the text on stdin, which parses, checks `user_id` against the
     paired locked owner (anyone else: nothing done, one log line without the id), runs the action and sends the
     answer. The model does not interpret commands.
  5. **Route per widget** (direct means the Bot API from `bin/chat`, with its existing token handling):
     | Widget | Route |
     |---|---|
     | Board: post once, pin once (pinChatMessage, no notification), edit in place (editMessageText) | direct |
     | Board edits: coalesced to at most one per 5 s; "message is not modified" counts as success; only "message to edit not found" posts and pins a new board | direct |
     | Board `message_id` | `<state dir>/chat/board.json`, mode 0600 |
     | Per-agent actions on the board and on Done | command links in the text (no markup, so an edit keeps them) |
     | Command menu: `/agents`, `/update`, `/log`, `/shot`, `/to` | direct setMyCommands, scope `chat` = owner, at each `bin/chat start` (more specific than the plugin's `all_private_chats`, so the plugin's reset does not hide it); never `start`, `help`, `status` |
     | One screenshot, a log or diff as `.txt` | direct (`bin/chat send`) |
     | Album (2 to 10 images from one step, caption on the first) | direct sendMediaGroup |
     | Reply threads | the owner's request `message_id` from the inbound meta is the thread root; replies use `reply_parameters` (direct) or the plugin's `reply_to` |
     | Stop confirmation | direct sendMessage with a one-time reply keyboard |
     | Conversational replies in a turn | the plugin's `reply` tool, as today |
  6. **Never** `getUpdates`, `setWebhook` or `deleteWebhook` from the hub, in code or tests.
- Consequences: one tap per action without touching the plugin; owner-only holds twice (the plugin's allowlist, then
  `bin/chat act`'s owner check). Command links look like text, not button chips; the drill (D4) must show them tappable
  on a phone. Each tap costs one orchestrator turn (it relays to `bin/chat act`). A press from a non-allowlisted sender
  is dropped by the plugin before the hub sees it, so the hub can log only senders the plugin let through. If the
  plugin later forwards callbacks, a new record can move actions to inline buttons. The builder records the command
  grammar, `board.json` and the `act` contract in `.ade/context/chat.md`.
- As built (C9 checked this record against `bin/chat`; where they differed, the code's way was kept):
  - **The text comes on stdin**, not `-- "<text>"`: C7 already takes all owner text on stdin from a quoted heredoc, so
    nothing the owner types is ever a shell word. The sender goes to the helper (`bin/console.py`) in its environment,
    so the id is in no argument but `act`'s own `--from` (as C7's `--sender`).
  - **The reply tag is C7's** `[<folder>, claimed] <kind>: "<text>"`, not `[api]`: every agent event already reaches the
    chat that way, and "claimed" says the sender is not authenticated.
  - **`/to` stays with `bin/chat to --sender`**, behind the owner's Allow (`permissions.ask`); `act` refuses it (exit 2)
    so owner text never reaches an agent without that prompt. `act` itself is not in `permissions.ask`: it sends
    nothing but fixed asks and the owner's own agents' logs, pictures and diffs, to the owner alone.
  - **`getUpdates` stays in one place**: H1's `bin/chat test`, which runs only while the orchestrator and its job are
    stopped. Item 6 holds for everything else; the console never polls (checked by `no_poller_no_callbacks`).
  - **`callback_data` stays only for channel types whose `channel_buttons` is `all`** (C7's ask buttons); Telegram is
    `permission`, so a Telegram message never carries it.
  - **Screenshots are posted by the forwarder's loop** (`bin/chat shots`, after `forward` and `board`), from each running
    agent's `<folder>/reports/browser`, each file judged by C8's `read_file`; one scan of a folder is "one step".
  - Residual risk: `act --from` names the owner, and any local process of the owner's user can run it, as with C7's
    `--sender`. What it can do is bounded: fixed asks, and the owner's own chat as the only recipient. `/stop` needs the
    nonce sent to the owner; a process that can read the hub's state folder could read that nonce too.
