# P2: a task's Done is the last message on the phone

Status: **Ready**. Risk: medium (the chat relay's order; no secrets, no new sends beyond the ones already made).
Found by: the ade-drill D4 drill (raw Ubuntu, "build a website"): the phone got "Done: build a website; ..." before
the frontend, backend and reviewer notes.
Verification: `bash tests/run.sh`.

## Today and the gap
The focus agents' notes reach Telegram through `bin/chat forward`, which `bin/chat start` runs every
`AGENT_CHAT_FORWARD_EVERY` s. The orchestrator's Done goes straight out through the plugin's reply tool, so notes
written in the last interval arrive after it, and the chat ends on a role note, not on Done.

## Goal
`bin/chat done <text>` sends the agents' queued events first (`bin/chat forward --wait`: waits for a running
forwarder, up to `AGENT_CHAT_DONE_WAIT` s, default 10), then the text as `bin/chat say` sends it. When some events
could not be sent, it says so in one plain stderr line and still sends the text; they follow on the next forward.
The hub rule (`templates/hub/CLAUDE.md`) has the orchestrator send a task's Done or Not done with it. Contract in
`.ade/context/chat.md`.

## Acceptance criteria (tests in `tests/test_chat.sh`)
1. `done_after_queued_notes`: every note queued before the Done reaches the chat before it, also while another
   forwarder holds the lock; none is sent twice; the hub rule names `bin/chat done`.
2. `done_without_waiting_when_nothing_queued`: with nothing queued the Done goes at once, not after the interval.
3. `done_holds_back_no_other_notes`: another folder's queued note goes too, and a note after the Done goes on the next run.
4. `done_after_a_failed_note`: a failed note send, or a forwarder that never lets go, does not block the Done; it is
   reported in one plain line, and the failed note is retried later.
