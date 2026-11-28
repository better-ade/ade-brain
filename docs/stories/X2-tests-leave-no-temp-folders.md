# X2: a test run leaves no temp folders behind

risk: low (test helpers only; no bin/ script, secret or live system)
Status: **Approved** by the owner's standing direction (2026-11-28): "just keep hacking and making these as stable as
possible" (low-risk stability work, no further sign-off).
Verification: `bash tests/run.sh` (docs/architecture.md).

## Story
As the owner, I want running any test file, alone or through `tests/run.sh`, to leave nothing in the system temp folder,
because on 2026-11-28 the Mac's `$TMPDIR` held 12,080 `tmp.*` folders made that day (test hubs, `demo-code`,
`ade-method` fixtures, `session-end.log`, sync locks), slowing the disk and hiding real leftovers. `tests/run.sh`
already gives each file its own TMPDIR and removes it; a test file run directly (how builders and reviewers run
targeted tests) does not.

## Design
`tests/helpers.sh`, when sourced, gives the test process its own `TMPDIR` (`$TMPDIR/ade-test.XXXXXX`) and removes it
when that process exits, whether or not the test file sets its own EXIT trap (19 files do): a detached watcher with
its standard streams on /dev/null waits for the test's PID and removes the folder. Under `tests/run.sh` (which already
did this) nothing changes. Test files that do not source helpers.sh are listed and made to.

## Acceptance criteria
1. **tmp_direct_run_clean** (tests/test_helpers_tmp.sh): running a small test file that sources helpers.sh and calls
   `make_hub` directly (not through run.sh) leaves no new entry in the caller's `$TMPDIR` after it exits, including
   when the file sets its own `trap ... EXIT` and when it fails (exit 1).
2. **tmp_killed_clean** (tests/test_helpers_tmp.sh): a test killed with SIGKILL still has its folder removed within
   5 s.
3. **tmp_all_files_source_helpers** (tests/test_helpers_tmp.sh): every `tests/test_*.sh` and `tests/e2e_*.sh` sources
   helpers.sh or is listed with a reason.
4. The verification command passes.

## Out of scope
Leftover folders already on the machine (the owner's to delete); bin/ scripts' own temp files.
