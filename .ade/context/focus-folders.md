# Focus folders and the hub's rules (contract)

How a focus session (`bin/work <folder>`) gets the hub's rules without Claude Code's "Allow external CLAUDE.md file
imports?" question, and how a start that nobody watches is reported. Code: `focus_hub_sync` and `chat_running` in
`bin/lib.sh`, `bin/work`, `bin/new`, `bin/context`; test: `tests/test_focus_imports.sh`.

## Why
Claude Code calls an import in a project memory file external when it resolves outside the session's working
directory, and asks once per project before loading any (docs: code.claude.com/docs/en/memory, "Import additional
files"; a `.claude/rules/` symlink that points outside is treated the same, so a symlink is no way round it;
`--add-dir` gives file access only and is not documented to make a path internal). A session whose working directory
is `<hub>/projects/<name>` loads `<hub>/CLAUDE.md` as an ancestor, and that file's `@ACCESS.md`, `@memory/MEMORY.md`
and `@.ade/rules.md` resolve to the hub root: outside the folder. With nobody at the terminal the session never
starts. (A session in a code checkout outside the hub never loads the hub's `CLAUDE.md`; it gets the rule sections
from the SessionStart hook, `bin/context <folder> --rules`.)

## Layout
```
<hub>/projects/<name>/
  CLAUDE.md               imports @.claude/hub/CLAUDE.md, then its own @ACCESS.md @memory/MEMORY.md @STATE.md
  .claude/settings.local.json  per machine, untracked (per-machine.md): "claudeMdExcludes": ["<hub>/CLAUDE.md"]
                          (plus the real path when the hub is behind a symlink); nothing else is written there
  .claude/hub/            generated; owned by the hub; never edited, never committed
    .gitignore            says so, and ignores everything in the folder (itself included)
    CLAUDE.md             copy of <hub>/CLAUDE.md
    ACCESS.md             copy of <hub>/ACCESS.md
    memory/MEMORY.md      copy of <hub>/memory/MEMORY.md
    .ade/rules.md         copy of <hub>/.ade/rules.md
```
- **What is copied:** the hub root's `CLAUDE.md` and every hub file it imports (followed up to five deep; code spans
  and fenced blocks are skipped, as Claude Code skips them), each at its path relative to the hub root, so the copy's
  own relative imports resolve inside `.claude/hub/`. An import of a file outside the hub cannot be copied in: one
  warning, and a session there is still asked about that one.
- **Copies** are byte for byte, written to a temp file beside the copy and renamed over it. A symlink at a copy's path,
  at `.claude/hub`, or at a folder under it, is removed and never followed. A `.claude` that is itself a symlink: a
  warning, nothing written. A copy of a file the hub no longer imports is removed.
- **When:** `bin/new` (a new folder) and every `bin/work <folder>` start, for every engine, before the launcher is
  written; never on `WORK_DRY=1`. A change in the hub reaches the next session, not a running one. A session started
  by hand in the folder, or a `bin/agent` run, reads the copies as the last `bin/work` left them.
- **The exclusion** (`claudeMdExcludes`, a documented Claude Code setting, in the folder's own `settings.local.json`, since it names this machine's hub path) keeps
  the hub root's `CLAUDE.md` from loading as an ancestor, so the rules are read once, from the copy. Nothing is ever
  written to Claude Code's trust or approval state (`~/.claude.json`, a config dir).
- **Migration:** on `bin/work`, a folder whose settings lack the exclusion or whose `CLAUDE.md` lacks the import gets
  both; an import in the folder's `CLAUDE.md` of a copied hub file from outside the folder (`@../../ACCESS.md`, an
  absolute path) is rewritten to its copy. Every other line is kept. One line on stderr, only when something changed:
  `work: <folder>: CLAUDE.md now imports the hub's rules from .claude/hub/ ...`. A `CLAUDE.md` that is a symlink is
  left alone, with a warning.

## A start nobody watches
- **When armed:** `bin/work` is run by a Claude session (`CLAUDE_PID` set: the orchestrator) or the hub's chat is on
  (`chat_running`: a live pid in `<state dir>/chat/chat.pid`), and `HUB_WORK_START_WAIT` (seconds, default `90`, `0` =
  off; hub.conf or the environment) is not 0. Claude Code sessions only.
- **Signal:** the session's entry (`<state dir>/sessions/<name>.<launcher pid>`) has a `status=` line. The folder's
  hooks write it: `ready` from SessionStart (`bin/context <folder> --rules`; written only while there is no status),
  `busy` from the first prompt, `idle` from Stop. With `--prompt` the session counts as going only at `busy` or `idle`
  (its first message was taken); without one, at any status.
- **Report:** the launcher starts a detached check (forked twice: never the launcher's child); after the wait, if
  its entry still exists and shows no such
  status, it runs `bin/notify --from <folder> main "<folder> (<name>) has not started after N s: it is waiting at
  its terminal (...)"`, once. The main session gets it as an event (`.ade/context/events.md`); `bin/chat forward`
  sends notes from a folder to the owner. The hub's `CLAUDE.md` tells the orchestrator to tell the owner at once.
- **Limits:** the check runs in the launcher, so a terminal that never ran the launcher (ADE without `capabilities:
  command`, where bin/work prints the line to paste) reports nothing. It says that the session is waiting, not at
  which question. A session whose folder settings lack the SessionStart or UserPromptSubmit hook (an old folder;
  `bin/doctor` warns) is reported although it runs. A Gemini session has no hooks, so no signal: it is never armed.
