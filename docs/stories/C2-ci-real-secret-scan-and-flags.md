# C2: CI runs the real secret scan, and the untested flags get tests

Status: **Approved** (owner, 2026-11-26: "make sure we add all test cases for all commands on the ci", then "yes
please" to C1 and C2). Risk: **low** (CI setup and tests only; no script behaviour changes). Verification:
`bash tests/run.sh`.

## Today and the gap
An audit found every `bin/` script has a test that runs in CI on macOS and Ubuntu, but:
- The shared verify workflow downloads gitleaks, scans, then deletes it before the tests run. So the pre-commit
  secret block (tests/test_precommit.sh, `if command -v gitleaks`) and the real secret scan in bin/learn
  (tests/test_learn.sh, `REALGL`, whose comment says "CI runs it") never run in CI.
- Four flags are never called by a test: `bin/brain search -n N`, `bin/init --ollama-url URL`,
  `bin/models set subagents <model>` and `bin/models set briefing <model>`.

## Goal
Both CI jobs install gitleaks in their own `setup:` (brew on macOS, the distribution's package or the pinned release on
Ubuntu), so it is on PATH when the tests run. Do not change the shared better-ade/.github workflow. Add a test for
each untested flag.

## Acceptance criteria
1. **ci_gitleaks_installed**: ci.yml's `ci` and `ci-linux` setups install gitleaks; a test reads ci.yml and fails if
   either does not.
2. **precommit_secret_runs**: in CI the pre-commit secret block runs (gitleaks present); when gitleaks is absent with
   `CI=true`, test_precommit.sh fails instead of skipping silently.
3. **learn_real_scan_runs**: likewise for the real gitleaks branch of test_learn.sh; its comment says what is true.
4. **brain_search_n**: `bin/brain search -n 1 <query>` returns at most one result where the plain search returns more.
5. **init_ollama_url**: `bin/init ... --ollama-url http://127.0.0.1:11999` writes that URL to hub.conf as the brain's
   Ollama URL (whatever key bin/init uses); a bad value is refused as bin/init refuses others.
6. **models_set_subagents_briefing**: `bin/models set subagents <m>` sets HUB_SUBAGENT_MODEL and `set briefing <m>`
   sets HUB_BRIEFING_MODEL in hub.conf; `bin/models` then shows both.

## Out of scope
The real Gemini CLI, real Keychain, launchd, systemd and pass stay tested through fakes and the owner's manual checks.
ade-cli is C1.
