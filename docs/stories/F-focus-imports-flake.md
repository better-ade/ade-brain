# F: the focus start-check test does not flake

Status: **Approved** (owner's standing direction, 2026-11-28: keep making ADE stable). Risk: **low** (a test only; no
product change). Verification: `bash tests/run.sh`.

## Today
`tests/test_focus_imports.sh` `stuck_start_reported` fails about half its runs, and more under load: "a session that
is running is not reported: got [2] want [1]". It blocks every gate.

## Cause (proven by instrumenting the test)
The second part sets `HUB_WORK_START_WAIT=1`; its fake session runs the prompt hook (`bin/changes`, which writes
`status=busy` to the session's entry) and the start check reads that entry 1 s after the launcher starts. The hook
took 1.2 to 1.9 s to finish on this machine, so the entry was marked busy about 0.2 s *after* the check had read it:
in a failing run the entry's `status=busy` was written at 97.30 s, the check fired at 97.1 to 97.3 s (launcher at
96.1 s), and the second note carries that part's second. The first launcher's check is one-shot and had already
posted (and been counted) before; nothing else writes the entry. The product behaves as designed: a session that has
not marked itself when the wait (90 s by default) ends is reported. The test raced a 1 s wait against a hook.

## Acceptance criteria (each named by its test)
1. **stuck_start_reported** (tests/test_focus_imports.sh): the "taken its first message" part is deterministic. The
   check's wait starts only after the prompt hook has run (a `sleep` on the launcher's PATH that waits for the hook's
   marker), and the assertion waits for the check to exit (no forked launcher copy and no `bin/notify` of this hub
   left) instead of a fixed `sleep 2.5`. Without the hook marking busy, the same assertion fails (checked by a
   mutation run).

## Out of scope
`bin/work`'s start check, the other parts of `stuck_start_reported`.
