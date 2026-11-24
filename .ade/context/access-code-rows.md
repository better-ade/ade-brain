# ACCESS.md Code rows and HUB_REPOS: how bin/init and bin/new write them, how bin/work, bin/dispatch and repos_of read them

- A row of the `## Code` table (or any table row whose Checkout cell starts with `/` or `~`) is
  `| Repo | Checkout | Default branch | Who merges | CI |`. The first such row is the folder's default repo.
- **Placeholders:** a Repo cell in parentheses is a placeholder. With a Checkout cell that is not a path it means no
  repo: the folder works in the hub folder. With a Checkout path, `(no remote)` is a repo with no remote (what
  `ade project add` writes, ade-cli's `.ade/context/hub-interface.md`, A21, and what `repo_row` writes): `bin/work`
  starts in that checkout, and refuses (exit 2) when the checkout is gone, since there is nothing to clone. A
  placeholder never joins `HUB_REPOS`.

## Writing a row (story P1)

- Built only by `repo_row <spec> <who>` in `bin/lib.sh` (sets `ROW`, `ROW_REPO`, `ROW_CHECKOUT`), for
  `bin/init --repo` and `bin/new <folder> --repo` alike.
- **Spec:** `owner/name`, `owner/name=<checkout>`, or a checkout path (starts with `/`, `~` or `.`, or is an existing
  directory). A leading `~` is expanded; an existing checkout is made absolute (`cd && pwd`).
- **Detected from the checkout, read only** (`git -C`: `remote get-url`, `symbolic-ref`; nothing that writes):
  repo = the given owner/name, else origin's GitHub `owner/name` (https, `git@github.com:`, `ssh://`), else
  `(no remote)` when there is no origin, else (an origin that is not GitHub) the directory name; branch =
  `origin/HEAD`, else the current branch, else `main`; CI = `GitHub Actions` when `.github/workflows/` holds a `*.yml`
  or `*.yaml`, else `(fill in)`. Who merges = the hub owner.
- **bin/new --repo:** every spec checked before anything is written; exit 2 for a repo already in that folder's
  ACCESS.md (by Repo cell; a `(no remote)` row by its Checkout cell, `~` expanded, so two `(no remote)` rows with
  different checkouts are both allowed), the same repo twice, a checkout that is not a directory, or `|` / a newline in
  a cell. Rows go at the end of the Code table. A new `owner/name` is appended once to `HUB_REPOS` in `hub.conf`
  (`%q`, the line rewritten in place) with one line saying to commit `hub.conf`; a hub with no `hub.conf` is left
  without one.
- **bin/init --repo:** keeps its `owner/name[=checkout]` check and does not refuse a missing checkout (its row then
  says `main` and `(fill in)`).
