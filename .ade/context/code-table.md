# A folder's Code table and HUB_REPOS (story P1)

- **Row:** `| <repo> | <checkout> | <default branch> | <who merges> | <CI> |` in the `## Code` table of
  `<folder>/ACCESS.md`. Built only by `repo_row <spec> <who>` in `bin/lib.sh` (sets `ROW`, `ROW_REPO`, `ROW_CHECKOUT`),
  for `bin/init --repo` and `bin/new <folder> --repo` alike.
- **Spec:** `owner/name`, `owner/name=<checkout>`, or a checkout path (starts with `/`, `~` or `.`, or is an existing
  directory). A leading `~` is expanded; an existing checkout is made absolute (`cd && pwd`).
- **Detected from the checkout, read only** (`git -C`: `remote get-url`, `symbolic-ref`; nothing that writes):
  repo = the given owner/name, else origin's GitHub `owner/name` (https, `git@github.com:`, `ssh://`), else the
  directory name; branch = `origin/HEAD`, else the current branch, else `main`; CI = `GitHub Actions` when
  `.github/workflows/` holds a `*.yml` or `*.yaml`, else `(fill in)`. Who merges = the hub owner.
- **bin/new --repo:** every spec checked before anything is written; exit 2 for a repo already in that folder's Code
  table (by repo cell), the same repo twice, a checkout that is not a directory, or `|` / a newline in a cell. Rows go
  at the end of the Code table. A new `owner/name` is appended once to `HUB_REPOS` in `hub.conf` (`%q`, the line
  rewritten in place) with one line saying to commit `hub.conf`; a hub with no `hub.conf` is left without one.
- **bin/init --repo:** keeps its `owner/name[=checkout]` check and does not refuse a missing checkout (its row then
  says `main` and `(fill in)`).
