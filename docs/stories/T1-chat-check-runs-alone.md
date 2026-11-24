# T1: one test_chat check runs on its own, so the no-terminal check fits its time on CI

Status: **Ready**. Risk: medium (test code only, but it is the guard that stops a held output pipe from keeping CI
waiting for hours; it must keep catching that).
Found by: main CI on 7ca4015 (run 45397612643): macOS `ci / verify` failed with "SIGTERM: the stand-in API never ran
(rc None); SIGKILL: the stand-in API never ran (rc None)"; the same tree passed on 37274f2 and on a re-run. C9's
branch failed the same way once (ef3fde0).
Verification: `bash tests/run.sh`.

## Today and the gap
`no_terminal_stand_in_api` starts `bash tests/test_chat.sh bot_send_token_on_stdin_only` twice and waits up to 120 s
for each run's stand-in API. The single-check mode at the end of `tests/test_chat.sh` runs **every earlier check**
first (in subshells, output dropped) and then the named one. That path now takes about 77 s on a laptop (C9 added
checks ahead of it) and more on the macOS runner, so the 120 s wait runs out before the stand-in starts.

The earlier checks are not all needed: run with only `start_launches_channel_session` before it,
`bot_send_token_on_stdin_only` passes in about 10 s; with none, it fails ("forward through the bot []"). The state it
needs is what that first check leaves behind (the stored Telegram token at least).

## Goal
`bash tests/test_chat.sh <check>` runs the shared setup a check needs and then that check, not every check before it.
The shared state now made as a side effect of `start_launches_channel_session` moves into a setup function that both
use. `no_terminal_stand_in_api` keeps its 120 s wait, its two runs (TERM and KILL) and every assertion.

## Acceptance criteria (tests in `tests/test_chat.sh`)
1. `bash tests/test_chat.sh bot_send_token_on_stdin_only` passes on its own and runs no other check (the test proves
   it: e.g. a marker the other checks would write is absent, or a timing bound well under the old path).
2. `no_terminal_stand_in_api` still fails when its guard is broken: with the stand-in's `signal.alarm` and the EXIT
   trap removed in a scratch copy, it reports the stand-in outliving the check (shown once by the builder, recorded in
   the PR).
3. The full file (`bash tests/test_chat.sh`) runs every check in today's order, with the same results.
4. Every other check named in the single-check list still passes when run on its own.

## Out of scope
The 120 s budget, `bin/chat`, and the other test files.
