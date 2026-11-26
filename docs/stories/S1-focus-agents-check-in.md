# S1: every focus agent checks in periodically, and the orchestrator always knows

Status: **Approved** (owner, 2026-11-26: "S1 approved"). Risk: **medium** (hooks in every folder; no secrets).
Found by: the owner (2026-11-26): "each focus agent needs to sync periodically and ensure that the orchestrator is
informed".
Verification: `bash tests/run.sh`.

## Today
- Hub files are committed by `bin/sync --auto` every 30 minutes and at the end of each focus session.
- A focus session tells main when it stops a turn (`idle`, with its last STATE line), pushes (`pushed`), or ends
  (`ended`).
- A finish report is a rule in CLAUDE.md, not something a hook makes happen.
- Gap: during a long busy turn, nothing reaches main and STATE.md is not updated until the end or a compaction. If the
  session is stuck at a permission prompt, main sees only "busy" with an old time in `bin/sessions`.

## Goal
Every N minutes of work, a focus agent writes a checkpoint: its STATE.md, then one progress note to main. A session
that misses its checkpoint is reported to main automatically, so the orchestrator never has to guess.

## Acceptance criteria (each named by its test in tests/test_checkin.sh)
1. **checkin_due_nudges**: in a folder session, after `HUB_CHECKIN_MINUTES` (default 30; 0 turns it off) of work
   since its last checkpoint, the PostToolUse hook gives it, once, the instruction (as additionalContext): update
   STATE.md, then `bin/notify main "<progress, next step, blocker if any>"`.
2. **checkin_not_early**: before the time is up, or a second time within the same period, it adds nothing. The cheap
   path starts no python, as bin/inbox does today.
3. **checkin_resets**: a note to main from that folder, or a STATE.md change, counts as the checkpoint and restarts
   the clock.
4. **checkin_missed_reported**: a session still busy with no checkpoint 10 minutes after the nudge, or busy with no
   hook activity for `HUB_CHECKIN_MINUTES` (stuck at a prompt), gets one `quiet` event to main. It carries the folder,
   how long it has been quiet, and its last STATE line. The check is run by the 30-minute monitor job; nothing new is
   scheduled.
5. **checkin_event_contract**: `quiet` and the checkpoint are added to .ade/context/events.md, and the checkpoint note
   is recorded with `checkin: true`.
6. **checkin_root_exempt**: the hub root (main) is never nudged. `HUB_CHECKIN_MINUTES` lives in hub.conf and
   `bin/doctor` shows its value.
7. **checkin_sync_follows**: right after a checkpoint, the hub files it changed are picked up by the next `bin/sync
   --auto`. No extra commits, and never a commit from the focus session itself (only main or bin/sync commit to the
   hub).

## Out of scope
- Any UI for these events. That is the monitoring UI, a separate story.
- Nothing more for the chat: `quiet` joins the kinds `bin/chat forward` already sends (idle, ended, note), so it reaches
  main's chat with no new forwarder (coordinator decision, 2026-11-26).
