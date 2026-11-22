# R1: crash-proof continuity

Status: **Merged (2026-11-21, PR #53)**: `bash tests/run.sh` green in CI on the merge. Earlier: ready for development
(2026-11-21). Risk: high. Owner's intent (2026-11-21): "crash proof scenarios for continuity."
Verification command: `bash tests/run.sh` (each scenario is a test that kills a part and checks the recovery).

## Goal
Any one part can die (kill -9, power loss, reboot, network loss) and the hub comes back on its own, loses no committed
work, and tells the owner what it recovered. `bin/recover` (run at boot, by the orchestrator's service before it starts,
and by hand as `ade recover`) checks and repairs; `bin/doctor` shows the same checks read-only.

| # | Crash | Recovery |
|---|---|---|
| 1 | Orchestrator process dies | launchd/systemd restarts it (C5); on start it reads the journal, STATE.md files and the event log since its last `ended`, and posts "restarted, N agents running, M waiting" to its channel |
| 2 | Machine reboots | services start at login (macOS) or boot (Linux); `bin/recover` runs first |
| 3 | A focus agent dies mid-task (no SessionEnd hook ran) | its session entry has no live process: `bin/recover` journals "agent <name> died", commits nothing on its behalf, marks the ticket `blocked: agent died` (never Done) and notifies main; `ade dispatch` can restart it with Claude Code's `--continue` in the same worktree |
| 4 | Uncommitted work left in a worktree | kept as-is (never reset or stashed); listed in the recovery note with its diff stat |
| 5 | Stale locks (sync, dispatch, chat) | removed only when their owner process is gone (S1b owner rule), each removal journaled |
| 6 | Half-written event log or cursor | the log keeps only whole lines (a torn last line is skipped); a cursor past the end is reset to the end |
| 7 | Network down | sync and Telegram retry with backoff; nothing is lost; the orchestrator keeps working locally |
| 8 | Disk full | writers fail closed (no partial files), doctor shows it, the channel gets one alert |
| 9 | `tmux`/`ade ui` closes | agents keep running (tmux server); `ade ui` re-attaches |
| 10 | Claude Code login expired | the orchestrator's service stops retrying after 3 starts, posts "login expired: run `claude` once" to the channel (or the journal) |

## Acceptance criteria (`tests/test_recover.sh`, one check per row above, fakes for claude/launchctl/systemctl)
| AC | Criterion |
|---|---|
| 1–10 | Each scenario row: kill or simulate the failure, run `bin/recover`, assert the recovery in the table and one journal line |
| 11 | `bin/recover` is idempotent: a second run changes nothing and prints "nothing to recover" |
| 12 | `bin/doctor` lists every check read-only, and never changes anything |
