# I1: a hub runs from any path on any machine, and two people can share one without churn

Status: **Approved** (owner, 2026-11-25). Risk: **high** (moves hook commands and permissions of every
folder session, and the hub's config: access).
Found by: the owner wants to import a hub (handover, sharing, clone). Today a hub works only at the absolute path it
was made at (README "A new Mac: clone to the same absolute path").
Verification: `bash tests/run.sh`.

## Today and the gap
Committed files carry one machine's paths: each folder's `.claude/settings.json` (6 hook commands,
`claudeMdExcludes`, permissions on `<hub>/hub.conf` and `memory/users/**`; written by `bin/new` from
`templates/folder-settings.json`, appended to by `focus_hub_sync` on every `bin/work`), each folder's `.mcp.json`
(`<hub>/bin/browser`), the checkout paths in folder `ACCESS.md` Code tables (`repo_row` expands `~`), `output_folder`
in `_bmad/config.toml` (absolute), and in `hub.conf` `HUB_CLAUDE_CONFIG_DIR`, `HUB_REMOTE_KEY`, `HUB_BRAIN_PATHS`,
`HUB_CLAUDE`. A hub at another path runs hooks that do not exist; two people syncing one hub rewrite each other's
paths on every sync. The hub root's own settings already use `$CLAUDE_PROJECT_DIR` and are fine.

## Goal
Committed files hold nothing machine-specific. What is per machine is written on that machine, uncommitted:
- Folder hooks, path permissions and `claudeMdExcludes` go to the folder's gitignored `.claude/settings.local.json`
  (Claude Code merges it); the committed `settings.json` keeps the rest. `.mcp.json` becomes gitignored and generated.
  `bin/work` sessions in an outside checkout get the same merged settings they get today.
- Checkout paths under `$HOME` are stored as `~/...`; every reader expands `~`.
- `output_folder` is relative (`_bmad-output`; the runtime joins it to the project root).
- The four machine keys move to a gitignored `.local/hub.conf`, read after `hub.conf`; `bin/init` writes them there.
- `bin/setup` (re)writes this machine's files, so a fresh clone at any path is one `bin/setup` from working.
  Existing hubs: `bin/setup` moves their committed machine values out (one commit the person makes).

## Acceptance criteria (tests in `tests/`)
1. A hub made by `bin/init` + `bin/new` has no absolute path of the machine (`$HUB`, `$HOME`) in any tracked file
   (`git grep` in the test).
2. The same hub cloned to a second path and a second `$HOME`, after `bin/setup` there, passes `bin/doctor`, and a
   folder's hook commands resolve to scripts that exist under the second path.
3. Running `bin/work` in both clones and syncing leaves `git status` clean in both (no churn).
4. A Code-table checkout under `$HOME` is stored as `~/...` and `repos_of`, `bin/work`, `bin/dispatch` find it on
   both machines.
5. A key set in `.local/hub.conf` wins over `hub.conf`; `HUB_USER` in the committed `hub.conf` is flagged by
   `bin/doctor` (it would make every person the same user).
6. An existing hub (today's layout) is migrated by `bin/setup`: machine values leave the tracked files, sessions keep
   their hooks and permissions, a second run changes nothing.
7. **End to end** (`tests/e2e_share.sh`, run by `tests/run.sh`): two scratch HOMEs, a bare remote, hub made in A,
   cloned in B at a different path; both run `bin/setup`, `bin/new`, `bin/work` (fake claude), `bin/sync --auto`;
   both end with the same tree, a clean status and passing `bin/doctor`.

## Out of scope
Owner change and clone (I2); the `ade hub import` command (I3); a merge driver for `STATE.md`.
