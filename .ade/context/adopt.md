# Adopting a hub (story I2)

`bin/adopt` runs in a fresh clone of a hub, after `bin/setup`. Tests: `tests/test_adopt.sh`, `tests/e2e_adopt.sh`.

| Mode | Changes | Commits |
|---|---|---|
| `--share` | nothing | none |
| `--handover --owner <name> [--from <user>\|none]` | the owner everywhere bin/init and bin/new wrote it; `HUB_OWNER`; the previous owner's `memory/users/<user>/` leaves the tree (it stays in git history); one journal line `Handover: <old> handed this hub to <new> (bin/adopt)` | one: `adopt: <old> hands the hub over to <new> (story I2)` |
| `--clone --owner <name> --name <new>` | owner and hub name (`HUB_OWNER`, `HUB_NAME`, `HUB_KEYCHAIN_SERVICE` when it was the old name, `_bmad/config.toml` `project_name`); every STATE.md reset from `templates/STATE.md`; `memory/users/` and `journal/<date>.md` removed; `.ade/session.md` is `# Session journal`; a new `.git` (branch main, `core.hooksPath .githooks`, the clone's local user), no remote | one, the only one |

- **Where the owner/name are rewritten:** the root `CLAUDE.md`, `ACCESS.md`, `README.md` and the persona agent
  (`templates/hub/*` and the persona body; `{{OWNER}}`, `{{NAME}}`), each folder's `ACCESS.md` (`templates/ACCESS.md`),
  every other `.claude/agents/*.md` (`templates/agent.md`; `{{OWNER}}`, `{{HUBNAME}}`), and the "who merges" cell of a
  `## Code` row (`repo_row`). A line is changed only when it matches a template line with the old value in that
  placeholder; any line that still holds an old value (whole word) is printed as `check: <file>:<line>`.
- **Owner gate (handover and clone):** after the rewrite, any tracked file outside `journal/`, `memory/`,
  `.ade/session.md`, `.ade/archive/` and `tests/` that still names the old owner (whole word) fails the run: each
  `file:line` is listed, the tree is rolled back, exit 1. Old hub-name leftovers stay `check:` warnings.
- **hub.conf:** `conf_set` replaces the `KEY=` line, or appends one when there is none.
- **Clone's old claim:** `~/.agent-hub/<old name>/hub-path` is removed when it holds this hub's path, else kept.
- **Handover memory folder:** `--from <dir>` (must exist), `--from none` keeps all; otherwise the old owner's name
  through `hub_user` when that folder exists; otherwise refused (exit 2) when other folders exist: folders are named
  after the computer login, pass `--from <login>`.
- **Refused, exit 2, nothing changed:** unknown mode or option, missing `--owner`/`--name`, an owner with control
  characters, a newline, `|` or a backtick (`|` breaks a table row), or edge spaces, a handover to the current owner, a name not `^[a-z0-9][a-z0-9-]*$` or equal to the old one
  or with `~/.agent-hub/<name>` present, not at a git top level, a tree that is not clean, a clone with a branch or tag
  whose commits are on no remote (named) or with a stash, a clone in a git worktree (`git_config_own`). A failure after
  the first write resets the tree (exit 1). A clone sets the old `.git` aside in `<hub's parent>/.adopt-git.XXXXXX`
  (same filesystem) and puts it back on a failure or INT/TERM/HUP; if it cannot, it runs no git command, prints where
  the old history is and exits 1; a backup folder it leaves is printed.
- **What's left (every mode ends with "Left to do by hand:"):** `bin/setup` when `.local/hub.conf` is missing, each
  `HUB_SECRETS` key and AI tool key not stored here, the keys line, `ade setup --telegram`, `bin/schedule install`.
  Share and handover print exactly (I4's hook, `.ade/context/keys-share.md`):
  `Keys: bin/keys share <new person> --all   (they run: bin/keys receive)`
  A handover adds, for the previous owner, the GitHub repo transfer and exactly:
  `Replace the shared keys at their source (each provider's console), then bin/keys forget <tool> for each.`
  A clone says the new hub keeps its own key store.
