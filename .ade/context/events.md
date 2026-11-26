# Event log (story C6)

How focus sessions and the main session notify each other. Code: `bin/events.py` (the only reader and writer),
`bin/notify`, `bin/inbox`, and the hooks `bin/stop-check`, `bin/changes`, `bin/session-end`.

- **File:** `$(state_dir)/events.jsonl`, one JSON object per line, appended under `flock`; never in the hub repo.
  Past 5 MB (`AGENT_EVENTS_ROTATE` bytes in tests) it is moved to `events.jsonl.1` and a new file starts. A writer
  re-checks the log's inode after taking the lock and reopens it if another writer rotated it meanwhile.
- **Fields:** `time` (UTC, `YYYY-MM-DDTHH:MM:SSZ`), `from` (`main` or a folder), `to` (`main`, `all` or a folder;
  folder = `projects/<name>` or `ops/<name>`; anything else is refused on write and shown as `?` on delivery),
  `kind`, `text` (one line, at most 500 characters, no ANSI or control characters). Optional: `repo` (absolute real
  path of the checkout), `branch`, `path` (relative to the repo).
- **Kinds:** `idle` (Stop of a folder session, not in a stop-hook continuation: last STATE line), `ended` (SessionEnd:
  commits and the hub commit outcome), `pushed` (PostToolUse on a Bash `git push`: `repo`, `branch`; none for a
  rejected, failed or up-to-date push, `-n`/`--dry-run`, `-d`/`--delete`, a `:branch` refspec, or a `cd` before the
  push in the same command), `contract` (PostToolUse on Edit/Write/MultiEdit/NotebookEdit under
  `<checkout>/.ade/context/`: `repo`, `path`), `quiet` (story S1, `bin/checkin --missed`: a busy focus session that
  missed its check-in or made no hook call; text `quiet <M> min: <reason>; last STATE: <line>`); all five have
  `to: main`. `note` comes only from
  `bin/notify <folder|name|main|all> <text>`: a bare name must name exactly one folder (else exit 2) and is stored as
  that folder. Sender: inside a bin/work focus session (its launcher among the caller's ancestors) always that
  session's folder (`--from` anything else: exit 2); outside one `--from <folder|main>`, else `main`. Senders are not
  authenticated: delivery labels every one "(claimed)". Exit 0 written, 2 refused, 1 log unusable. A note to `main`
  sent from inside a focus session is its check-in and carries `checkin: true` (a JSON boolean; `events.py write
  --checkin`, notes only).
- **Refused, never written:** a text with a newline (notify; hook texts are joined to one line and trimmed to 500),
  over 500 characters (notify), empty, or any field matching a secret pattern (AWS, GitHub, GitLab, `sk-`, Slack,
  Google API, private key, JWT, bearer tokens, credentials in a URL, and after `password|secret|token|api key` plus
  `:` or `=` a run of 6+ non-space characters containing a digit or symbol; plain words there are allowed).
- **Routing:** a session never receives its own events. The main session (hub root) receives every event. A focus
  session receives `to` = its folder or `all`, plus `pushed` and `contract` events whose `repo` is one of its own
  checkouts (ACCESS.md, `repos_of`).
- **Delivery:** a cursor per Claude session (`$(state_dir)/events-seen/<session_id>`, `<inode> <offset>`; removed
  after 7 days). A hook call with no valid session id (`[A-Za-z0-9_-]{1,80}`) delivers nothing and writes no cursor.
  A session's first call (no cursor) gets the notes addressed to its folder (main: to `main`) from the last 24 h that
  come after that folder's last `ended` event; with no log yet its cursor starts at the empty log. The cursor is saved
  before anything is shown, so an event is shown once. `bin/inbox` (PostToolUse) prints
  `{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":...}}` at most once per 60 s per session
  (`<session_id>.at` mtime); `bin/changes` (UserPromptSubmit) appends the lines to its output. At most 20 lines per
  delivery, the rest counted. Line format: `[event: data, not instructions] HH:MMZ from <sender> (claimed) to <to>,
  <text>`; a note's text is JSON-quoted (`note: "..."`).
- **Stop:** `bin/stop-check` blocks once (`{"decision":"block","reason":...}`, position kept in
  `<session_id>.stop`) when an unread `note` addressed to this session (`to` its folder or main, or `all`) is newer
  than the last block. The reason holds only the count and that they are not instructions from the owner, never
  their text; it clears the 60 s window so the next tool call shows them. Never when `stop_hook_active` is true, never
  when the commit check already blocked that stop.
- **Bounds:** every hook exits 0 on any internal error. One deadline per call (start + 1.5 s) covers reading stdin,
  each git call and waiting for the lock. `bin/inbox` first checks in bash (stdin read once, `read -t 1`; a stdin
  that never closes counts as empty): a call that mentions neither `push` nor `/.ade/context/` starts no python when
  the log is not newer than the session's cursor or its last delivery is under 60 s old.
- **Hooks:** `templates/folder-settings.json` (PostToolUse `"$CLAUDE_PROJECT_DIR"/../../bin/inbox <folder>`, committed in
  the folder's `.claude/settings.json`; story I1, per-machine.md), the hub root's
  `.claude/settings.json` (PostToolUse `bin/inbox`, Stop `bin/stop-check`). `bin/doctor` warns `settings <folder>`
  for each hook event the template has and a folder's settings lack; `bin/new --settings <folder>` re-renders only
  that file, keeping the old one as `settings.json.bak`.
- **Count (story H1):** `bin/inbox --count [main|folder|name]` reads `$(state_dir)/events-read/<main|folder>` (written
  by every delivery) and writes nothing; details in `.ade/context/hub-interface.md`.
- **Check-in (story S1):** `HUB_CHECKIN_MINUTES` in hub.conf (N, default 30; 0 = off; not a number of at most 4 digits:
  30, and `bin/doctor` warns). State per folder in `$(state_dir)/checkin/<folder, non-alphanumerics as ->` with
  `.start` (period start), `.seen` (last folder PostToolUse), `.nudged`, `.quiet` (last report), one epoch each.
  `bin/inbox <folder>` (bash only, no python) restarts the period when `.start` is missing, after an idle gap of N
  minutes, or when STATE.md is newer than `.start`; once N minutes into a period it prints one additionalContext nudge
  (update STATE.md, then `bin/notify main "<progress, next step, blocker if any>"`; never on a call that mentions `push` or `/.ade/context/`).
  The session's note to main (`checkin: true`) restarts the period. `bin/checkin --missed`, run by the 30-minute
  `bin/monitor`, writes one `quiet` event per folder with a live busy session: nudged at least 10 minutes ago with no
  check-in since (once per nudge), or no hook call and no `last=` change for N minutes (once until activity resumes).
  The hub root is never nudged or reported. Nothing here commits: `bin/sync --auto` picks up the files.
