# Design note: a Code row with no remote is a repo

Risk: **medium** (a bug fix in how `bin/work` and `bin/dispatch` read `ACCESS.md`). Verification command:
`bash tests/run.sh`.

## The bug
`ade project add` (ade-cli 0.2.8, A21) writes a repo with no remote as `| (no remote) | ~/Project/calc | ... |`.
`bin/work` and `bin/dispatch` skipped every Repo cell that starts with `(` (meant for placeholders such as
`(none of its own; ...)`), so `bin/work projects/calc` started the focus agent in the hub folder instead of the
checkout, and `bin/dispatch` counted no repo. The golden-path drill (ade-drill) failed at its dispatch step.

## The fix
- A `(...)` Repo cell is a placeholder only when its Checkout cell is not a path: with a Checkout that starts with `/`
  or `~` it is a repo, as `repos_of` in `bin/lib.sh` already reads it.
- `bin/work` refuses (exit 2) such a row whose checkout is gone: it has no remote to clone, and is never cloned.
