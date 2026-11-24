# P1: bring an existing project into a hub with one command

Status: **Ready**. Risk: medium (writes hub files only; never the project's checkout, no secrets).
Owner's intent (2026-11-24): "let's polish ... the experience: I want to use this for my existing projects."
Verification: `bash tests/run.sh`.

## Today and the gap
`bin/init --repo owner/name=checkout` puts every repo into the first folder (`projects/app`), writes the default branch
as `main` whatever the repo uses, and leaves CI as `(fill in)`. After init there is no command at all: adding a
project means `bin/new projects/<name>` and then hand-editing the Code table in its `ACCESS.md`.

## Goal
`bin/new projects/<name> --repo <checkout path | owner/name[=checkout path]>` (repeatable) makes the folder as today
and fills its Code table from the repo itself:

- **Repo:** `owner/name` as given; else read from the checkout's `origin` remote (GitHub https or ssh URL); else the
  directory name.
- **Checkout:** the absolute path (a `~` is expanded); empty when only `owner/name` is given (`bin/work` clones it later,
  as today).
- **Default branch:** `origin/HEAD` of the checkout, else its current branch, else `main`.
- **CI:** `GitHub Actions` when the checkout has `.github/workflows/*.yml` or `*.yaml`, else `(fill in)`.
- **Who merges:** the hub owner (as `bin/init` does today).

Rules: it works on a folder that already exists (keeps its files, only adds rows); it refuses a repo already in that
folder's Code table and a checkout path that is not a directory; it never writes inside the checkout; it adds a new
`owner/name` to `HUB_REPOS` in `hub.conf` (so `bin/doctor` checks it) and prints one line saying to commit `hub.conf`.
`bin/init --repo` builds its rows with the same code (shared in `bin/lib.sh`), so branch and CI are detected there too.
README "Make a hub" gains a short "Bring an existing project" block.

## Acceptance criteria (tests in `tests/test_new.sh` unless named)
1. `--repo <local path>` with a GitHub `origin` (ssh and https forms) writes `owner/name`, the absolute checkout,
   the `origin/HEAD` branch (a repo whose default is `master` gets `master`) and the hub owner.
2. A checkout with no remote gets the directory name, its current branch, and `(fill in)` CI.
3. A checkout with `.github/workflows/ci.yml` gets `GitHub Actions`.
4. `--repo owner/name` alone writes the row with an empty checkout; `--repo owner/name=~/x` expands `~`.
5. On an existing folder it adds the row and keeps every other file byte for byte; a second `--repo` of the same repo
   exits 2 with a message, and so does a checkout path that is not a directory.
6. The checkout's `git status --porcelain` and file list are unchanged after the command.
7. A new `owner/name` is appended to `HUB_REPOS` in `hub.conf` once (no duplicate on a second folder).
8. `tests/test_init.sh`: `bin/init --repo` on a `master` checkout writes `master`, not `main`.
