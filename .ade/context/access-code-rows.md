# ACCESS.md Code rows, as bin/work, bin/dispatch and repos_of read them

- A row of the `## Code` table (or any table row whose Checkout cell starts with `/` or `~`) is
  `| Repo | Checkout | Default branch | Who merges | CI |`. The first such row is the folder's default repo.
- A Repo cell in parentheses is a placeholder (no repo: the folder works in the hub folder) only when its Checkout cell
  is not a path. `(no remote)` with a Checkout path is a repo with no remote (what `ade project add` writes,
  ade-cli's `.ade/context/hub-interface.md`, A21): `bin/work` starts in that checkout, and refuses (exit 2) when the
  checkout is gone, since there is nothing to clone.
