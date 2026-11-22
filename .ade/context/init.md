# bin/init: questions and a run again (story H3)

- **Questions:** only when stdin is a terminal and `--persona`, `--client` or `--owner` is missing; prompts go to
  stderr. Without a terminal: one line `init: missing --persona, --owner; ...` on stderr, exit 2. All questions come
  before anything is written.
- **Persona match** (the question and `--persona` alike): the answer and each persona's slug and `title` lower-cased
  with spaces, `-`, `_` and `/` removed; accepted are the list number (the `personas/*.md` glob order, as
  `bin/init --list`), an exact slug or title, or a prefix exactly one persona has. Unknown `--persona`: exit 2 naming up
  to three closest (a shared prefix of 3+ letters, or a word of the answer in the slug or title).
- **End of input at a question:** exit 1 and one stderr line
  `init: stopped at the <q> question (end of input), nothing written; to continue: cd <pwd> && <template>/bin/init ...`
  with every option given and every answer so far, each one shell word (bare, single-quoted, or `$'...'` when it holds a
  control character).
- **`.init-pending`** (hub root, gitignored, never copied by `--dest`): written before the first write into a copy,
  removed after the last step. It is sourced bash: `INIT_PERSONA`, `INIT_CLIENT`, `INIT_OWNER` (`%q`) and `INIT_REST=(...)`,
  every other option except `--dest`. Its presence is the only sign of a half-finished copy:
  - present: `bin/init` (in place, or `--dest` at that copy) finishes it with the recorded values; a persona, client or
    owner given now must equal the recorded one, and other options must be none or the same list, else exit 2 naming the
    recorded command. `--dest` completes the copy without overwriting a file (`tar -k` / GNU `--skip-old-files`).
  - absent with `hub.conf`: an initialized hub, refused (exit 2). Absent with an existing `--dest`: refused (exit 2).
- **Idempotent steps on a run again:** `hub.conf`, the root `CLAUDE.md`, `ACCESS.md`, `README.md`, the persona agent,
  `_bmad/config.toml` keys and `.claude/settings.json` keys are bin/init's own and rendered again from the templates
  (never from their output); `bin/new` keeps every file it finds; repo rows are added only when missing; the journal
  entry and a `synced no <pin>` line are written once.
- **Git:** decided by `git rev-parse --is-inside-work-tree`. Not inside a repo: `git init`, `branch -M main`,
  `core.hooksPath .githooks` (as before). Inside one (a clone, a linked worktree, a submodule, a folder of a bigger
  repo): never `git init`, never a branch renamed or moved. `core.hooksPath` is set only when `git_config_own`
  (`bin/lib.sh`) holds: the folder is the repo's top and its git dir is the common dir, so the config is not shared with
  other checkouts. Otherwise it is left as is and bin/init says so in one stderr line; `bin/setup` follows the same rule.
- **Client and hub name:** without `--name`, the hub name is the client slugified plus the persona. A client with no
  letter or digit a-z 0-9 is asked again (one line naming `--name`); as `--client` it exits 2 before anything is
  written, naming `--name`.
