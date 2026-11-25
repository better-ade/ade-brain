# Per-machine values (story I1)

A hub runs from any path, under any user: nothing tracked names a machine path. What is per machine lives in untracked
files, written by `bin/setup` (and refreshed by `bin/new`, `bin/new --settings` and every `bin/work` start).

| Where | Holds | Written by |
|---|---|---|
| `.local/hub.conf` | `HUB_CLAUDE`, `HUB_CLAUDE_CONFIG_DIR`, `HUB_REMOTE_KEY`, `HUB_BRAIN_PATHS` (`machine_conf_keys`, bin/lib.sh), and `HUB_USER` when set | `bin/init`, `bin/setup` (moves a key out of `hub.conf` only when its value is this machine's: empty, under `$HOME`, an existing path, or for `HUB_CLAUDE` a command found; otherwise drops it and prints it under "set by hand"; `HUB_USER` is moved by hand, doctor flags it) |
| `<folder>/.claude/settings.local.json` | only `claudeMdExcludes` of the hub root `CLAUDE.md` (and its real path); rendered from `templates/folder-settings-local.json` | `folder_local_write` (bin/lib.sh): adds missing entries, removes nothing |
| `ACCESS.md` checkout cells (`## Code` table) | `~/...` for a checkout under `$HOME` (expanded when read: `repos_of`, `bin/work`, `bin/dispatch`); a clone `bin/work` makes is recorded with `tilde_path` | `bin/new`, `bin/init`, `bin/work`, `bin/setup` (rewrites old absolute cells of that table only) |
| `_bmad/config.toml` | `output_folder = "_bmad-output"` (relative) | `bin/init`, `bin/setup` |

**Tracked and portable** (from `templates/folder-settings.json` and `templates/folder-mcp.json`): a folder's
`.claude/settings.json` hooks run `"$CLAUDE_PROJECT_DIR"/../../bin/<hook> <folder>` (a folder session starts in the
folder), its asks are `Edit(//**/hub.conf)`, `Edit(//**/memory/users/**)`, `Write(//**/memory/users/**)`, and
`.mcp.json` runs Playwright as `bash -c 'exec "$CLAUDE_PROJECT_DIR"/../../bin/browser run "$1"' bin/browser <folder>`.

- **Order:** `bin/lib.sh` (and `bin/brain`) source `hub.conf`, then `.local/hub.conf`; a key in the local file wins.
- **Policy exception:** `HUB_PROVIDER`, `HUB_PROVIDERS_ALLOWED`, `HUB_OWNED_BY_OWNER`, `HUB_GEMINI_CLIENT_APPROVED`,
  `HUB_AGENT_ANTHROPIC_KEY`, `HUB_SECRET_STORE`, every `HUB_ROLE_*` and every `HUB_BROWSER_PROFILE_*` are read from the
  committed `hub.conf` only (`hub_policy_vars`): a local file cannot loosen the hub's policy. A value set there is ignored.
- **Migration** (`folder_local_write <folder> --migrate`, run by `bin/setup` on a folder from before I1): in place, it
  rewrites only the hub-path prefix of a hook that is exactly a pre-I1 template command (`"<a hub>"/bin/<hook> ...`),
  the asks `Edit(/<that hub>/hub.conf)` and `Edit|Write(/<that hub>/memory/users/**)` (to `//**/`, without repeats),
  drops the exclude `<that hub>/CLAUDE.md` from `settings.json` (the local file gets this hub's), and rewrites the
  Playwright server `<a hub>/bin/browser run <folder>`. Every other hook, ask, exclude and server is kept. A local file
  that is not a JSON object is left as it is, with a warning. Temps sit beside the file (`<name>.*.tmp`). Idempotent.
- **Commit:** `bin/setup` commits its own migration as one commit (`setup: this machine's paths out of git (story I1)`)
  only when the index was empty before it ran; otherwise it prints the `git add`/`git commit` command. A folder it
  cannot migrate makes it exit non-zero, naming the folder.
- **Launch:** `--settings` takes one file, so `bin/work` deep-merges `settings.json` and `settings.local.json`
  (`folder_settings_merged`: dicts recursive, lists joined without repeats, local scalars win) into a mode-600 temp
  file that the launcher removes. It is built after `focus_hub_sync`. For a session in a checkout outside the folder
  (where `$CLAUDE_PROJECT_DIR` is the checkout) the merged hooks name the hub as `"<hub>"/` instead.
- **Ignored** (`hub_gitignore_ensure`, called by `bin/setup` and `folder_local_write`; a missing line is appended after a
  newline when the file lacks a final one): `.local/`, `.claude/settings.local.json`, `projects/*/` and `ops/*/`
  `.claude/settings.local.json`, `.claude/*.bak`, `.claude/*.tmp`, `.mcp.json.bak`, `.mcp.json.*.tmp`. `bin/setup`
  untracks committed `settings.local.json` files (`:(glob)` pathspecs).
- **Doctor:** WARN when `hub.conf` holds `HUB_USER` or a machine key; WARN `settings <folder>` when `settings.json` lacks a
  template hook event, names a hub path (a folder from before I1: `bin/setup`) or lacks a `//**/` ask; MISSING when a
  folder has no `settings.local.json`, WARN when it lacks this hub's `CLAUDE.md` exclude.
- `bin/sync` never commits `hub.conf` (its paths exclude it, as before); `.local/` is never shared.
