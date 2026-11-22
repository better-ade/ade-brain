# Auto sync and monitors (config keys and contracts)

- `HUB_AUTO_SYNC` (hub.conf, written by `bin/init --auto-sync on|off`): `1` (default when absent) or `0`. `0` turns off
  the session-end push (`bin/session-end`), the launchd sync job (`bin/schedule install` leaves it out and removes an
  earlier one) and `bin/sync --auto` itself (logs "skipped: auto sync is off", exit 0).
- Env overrides (tests): `AGENT_AUTO_SYNC` (session-end only; wins over `HUB_AUTO_SYNC`), `AGENT_SYNC_CMD` (replaces
  the command session-end starts), `AGENT_SYNC_LOG` (default `$(state_dir)/logs/sync.log`), `AGENT_SYNC_LOCK`
  (default `$(state_dir)/sync.lock`). `tests/helpers.sh` sets all three off/temp in `make_hub`.
- `bin/sync --auto` exit: 0 = synced, nothing to do or skipped (lock held, git busy, off); 1 = refused or failed.
  One log line per run.
- The sync lock (`AGENT_SYNC_LOCK`) is taken by `bin/sync --auto` (never waits), `bin/sync --yes` and the
  `bin/session-end` commit step. `AGENT_HOOK_LOCK_WAIT` (default 5): seconds the session-end hook path (no `--since`)
  waits for a busy lock; `AGENT_LOCK_WAIT` (default 30): seconds session-end `--since` and `--yes` wait (attempts are
  counted, so the wait is at least that long). `bin/sync --yes` exits 1 with `another sync is running` on stderr when
  the lock stays busy (it used to never wait or fail on the lock). A stale lock (its pid names no process; or a live
  process whose start time differs from `<lock>/start`, `<pid> <start>` with the start in UTC, so the pid was reused;
  or no usable pid and older than 10 s) is removed under a guard dir `<lock>.gc`, and a live owner's lock is kept
  however old; only a lock whose pid file is the caller's own pid is released by it.
- `AGENT_SESSION_END_LOG` (default `$(state_dir)/logs/session-end.log`): one line per `bin/session-end --since` run:
  UTC time, folder, `since=<epoch>`, outcome (`committed`, `nothing to commit`, `failed: commit refused`,
  `skipped: sync lock busy`, `refused: <reason>`). On both paths (hook and `--since`) a failed step after the commit
  adds one line `bg step failed: brain index exit <n>` or `bg step failed: sync exit <n>` (never the step's output);
  the hook path's detached job sends its own stdout and stderr to the same log.
- launchd jobs: `ai.agent-hub.<hub name>.{briefing,monitor,sync}`, templates `launchd/<job>.plist.template`.
- Monitors: executable `projects/*/monitors.d/*.sh`, `ops/*/monitors.d/*.sh`; read-only; first output line = status
  (leading `Ddd HH:MM TZ |` or `YYYY-MM-DD HH:MMZ |` stripped before comparing); `ALERT...` lines alert. State in
  `$(state_dir)/monitor-state/`. `MONITOR_TIMEOUT` (300 s), `MONITOR_QUIET=1` (no notification).
- Monitor triage (story M1): `HUB_MONITOR_TRIAGE=1` in hub.conf (default off). On a new ALERT only (the `<key>.alert`
  transition) `bin/monitor` runs `bin/agent --role triage --folder <folder>` once, the task on stdin: the hub's
  `.ade/agents/monitor.md` if present, else a built-in five-line monitor role, then the output between
  `<<<MONITOR-OUTPUT nonce=N>>>` and `<<<END-MONITOR-OUTPUT nonce=N>>>`, marked untrusted data. Nothing from the output
  goes in argv. Report: `reports/monitor/<folder>/<UTC YYYYmmddTHHMMSSZ>-<monitor without .sh>.md` (bin/agent's
  stdout). Verdict: the first `Verdict:` line inside bin/agent's frame, else its first line, control characters
  removed, at most 200 characters. Journal (folder): `monitor triage <monitor>: <verdict> (report <path>)`; the
  notification becomes `<ALERT line>. <verdict>`. A triage exit 1 or 2: `monitor triage failed: <monitor> exit <n>`, no
  report, the alert still notifies, bin/monitor still exits 0. One triage at a time, each capped by `AGENT_TIMEOUT`.
  At most one triage per `bin/monitor` run: a later new ALERT is journaled `monitor triage queued: <monitor>` and marked
  `<key>.queued` in the monitor state; the next run triages it if it still alerts, and drops it if it cleared.
  Secrets: the monitor output in the task and the saved report go through `events.py redact` (the event log's SECRETS
  patterns, each match replaced by `[redacted]`). Reports stay local: `reports/monitor/` is in `.gitignore`; only the
  journal's verdict line is synced.
- `bin/changes [folder]` (UserPromptSubmit in the hub root and every folder): one snapshot per session,
  `$(state_dir)/changes-seen.<session_id>` (from the hook JSON on stdin), removed after 7 days.
