# Crash recovery (`bin/recover`, story R1)

- **When:** at login (launchd `ai.agent-hub.<hub>.recover`, RunAtLoad, installed by `bin/schedule install`), at the
  start of every `bin/chat start` (after its hub-name claim, before the session), `bin/recover --agents` from every
  `bin/monitor` run (agents check only), and by hand. A hub whose name another existing hub claimed (`hub_name_claim`)
  recovers nothing (exit 2; `--check` prints one `WARN recover hub name` row) and gets no recover job. One run at a time: `<state dir>/recover.lock`
  (the sync-lock rules). `bin/recover --check` (shown by `bin/doctor`) prints one `OK|WARN  recover <check>  <detail>`
  row per check and changes nothing.
- **Output:** one line per repair, each also one journal line `recover: <line>` (folder `.`); with any repair a note
  `<state dir>/recover/<UTC>.<pid>.md` ("recovery note: <path>" printed last). Nothing found: `nothing to recover`, no
  journal line, no note. A second run right after the first finds nothing.
- **Never:** commits, resets, stashes or checks out anything; marks a ticket Done.
- **Checks and repairs:**
  - `orchestrator`: `<state dir>/chat/chat.pid` names no live channel session -> removed; the chat gets
    `restarted, <N> agent(s) running, <M> waiting` (N = `bin/sessions` rows, M = unanswered `bin/chat ask`s), at most
    once per 10 minutes (`<state dir>/chat/restarted-at`), so a crash loop posts it once.
  - `agents`: a session entry (`<state dir>/sessions/*`, or `sessions-dead/*`, where `bin/sessions` moves the
    entries it prunes) whose launcher is no live `-work.` process, or whose pid runs a launcher with another start time
    than the entry's `start=` (`launcher_alive` in `bin/lib.sh`). Journaled `agent <name> died (<folder>)`; main notified
    (`bin/notify --from <folder> main "blocked: agent <name> died; <restart line>"`); the checkout's changes against
    HEAD (`git --no-optional-locks diff HEAD --stat`, `status --porcelain`) and commits not pushed (`log --oneline
    @{u}..HEAD`) listed, never touched. Restart line: `CLAUDE_CONFIG_DIR=<config_dir> bin/work --resume <session_id>
    [--role R] [--ticket T] [--model M] --name <name> <folder>` (`--continue` when no session id is known); a provider
    session gets a fresh start (`bin/work --provider P --model M ...` or `--role R`), never a resume.
  - **Ticket:** only the entry's `ticket=` (the real ref bin/dispatch passed with `bin/work --ticket`), never the session
    name. `tickets find <ref>` first: `in-progress` or `ready-for-dev` -> `tickets mark <ref> blocked --blocked "agent
    died"`; any other status is left and journaled (`ticket <ref> left as <status>`). Node missing, or find/mark failing:
    journaled `ticket <ref> could not be marked blocked (<reason>); retried on the next run`, the entry kept in
    `sessions-dead/` with `recovered=<UTC>` (the death is not reported again), retried by every run (bin/monitor's too).
  - `locks`: `<state dir>/chat/lock`, `chat/forward.lock`, `dispatch.lock` and the sync lock, removed only when stale
    by the S1b owner rule (`_sync_lock_stale` / `_sync_lock_reap` in `bin/lib.sh`); a live owner's lock is kept.
  - `event log`: `events.py repair` drops a torn last line under the log's lock (never more than the last MiB it read:
    with no line end there it prints `event log: not repaired` and cuts nothing) and resets every cursor
    (`events-seen/*`, `chat/forward.cursor`) whose offset is past the end to the end.
  - `disk`: under `AGENT_DISK_MIN_MB` (default 200) MB free (`df -Pk`) for the hub or the state dir: one journal line
    and one chat alert, then quiet (`<state dir>/recover/disk-alert`) until there is space again.
  - `chat service` (`--check` only): `<state dir>/chat/gave-up` exists.
- **Chat messages** go through `bin/chat say`; when the channel is down the message is kept in
  `<state dir>/chat/pending/` and `bin/chat forward` sends it first next time (journal: `recover: chat unreachable: the
  message is kept`).
- **Session entry fields** (bin/work's launcher): `ticket`, `provider`, `model`, `config_dir`, `start` (`proc_start` of
  the launcher), and `session_id` from the first prompt hook (`bin/changes` -> `session_mark <folder> busy <id>`).
- **Restart a dead agent:** `bin/work --resume <id>` (Claude sessions only) or `--continue`.
- **Not covered here:** Linux/systemd units (no Linux layer yet, story V1); tmux (agents run in Terminal/ADE tabs, which
  are separate processes from any UI); `bin/sync` already keeps commits when a push fails and retries on its next run.
