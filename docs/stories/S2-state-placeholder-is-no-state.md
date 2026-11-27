# S2: the template's STATE placeholder is not a state

Status: **Approved** (owner, 2026-11-27: "All", on the devex evaluation). Risk: **medium** (hub scripts' wording; no
change to when a check-in or a quiet event fires). Verification: `bash tests/run.sh`.
Pairs with: ade-cli M3 (the page side of the same finding).

## Today
A new folder's STATE.md is `templates/STATE.md`, whose only content line is `Updated: (UTC date and time, by whom)`.
`bin/checkin` and `bin/events.py last_state_line` take it as the folder's state, so a quiet event on a fresh folder
reads `last STATE: Updated: (UTC date and time, by whom)`, and so do idle events and the page.

## Acceptance criteria (each named by its test)
1. **placeholder_skipped** (tests/test_checkin.sh): a line whose whole value is a parenthesised placeholder
   (`^[^:]{1,40}: \(.*\)$`) is skipped by `bin/checkin`'s state line; a STATE.md with only headings and placeholders
   gives `last STATE: (no STATE yet)`.
2. **placeholder_skipped_events** (the events.py test): `last_state_line` skips the same lines, so `bin/stop-check`'s
   idle event agrees with `bin/checkin`.
3. **real_line_kept**: a filled line (`Updated: 2026-11-27 13:40Z, by monitoring`) is still used, in both.

## Out of scope
The template's wording, ade web (M3), when check-ins or quiet events fire.
