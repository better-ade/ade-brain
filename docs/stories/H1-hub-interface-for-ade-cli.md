# H1: the hub commands ade-cli calls (setup and ui)

Status: Ready for development (2026-11-21). Risk: **high** (raised from medium while building: the change handles an
Anthropic API key and the Telegram bot token).
Source: the contract ade-cli expects, `.ade/context/hub-interface.md` in ade-cli (branches A5 `ade setup`, A6 `ade ui`).
Verification command: `bash tests/run.sh` (`docs/architecture.md`).

## Goal
`ade setup` and `ade ui` drive the hub through its `bin/` scripts. Five gaps stop them today; this story closes exactly
those, with the hub-side contract recorded in `.ade/context/hub-interface.md`.

## Scope
1. **`bin/agent --live-test <provider[:model]> [--dir <folder>]`**: one tiny read-only task (stdin's first line, else
   "Reply with the word READY and nothing else.") through the run a real `bin/agent` uses (`agent.py`: allowlisted
   environment, own process group, timeout, the same Claude Code flags and provider settings), from a throwaway folder:
   `--dir` (an existing folder that is not a git checkout and not inside the hub; the caller removes it) or, without
   `--dir`, a `mktemp -d` folder the script removes. Default model `haiku` (a slot alias). Every check of a role run
   applies except `HUB_PROVIDERS_ALLOWED` (the live test is how a provider gets in). Exit 0 only when a whole output
   line is `READY` (spaces and CR ignored); otherwise exit 1 and the last line is the reason, with key-shaped strings and
   bot tokens hidden. Exit 2 for bad usage. `gemini` (no engine yet, E1) and `muse` (no provider row) fail with a reason.
   Provider key and backend variables are unset, and never reach the engine.
2. **`bin/keys` supports `anthropic`**: `bin/keys set|forget anthropic` stores the Anthropic API key as
   `anthropic-api-key` through `bin/secret` (stdin or hidden prompt, never an argument), and `bin/keys` lists it as
   stored or missing. A stored key is used by `bin/agent` (role runs and live tests) only through Claude Code's
   `apiKeyHelper` (`bin/secret anthropic-api-key`), never an environment variable; without one, the Claude login.
   `telegram` (bot token) stays as it is.
3. **`bin/chat logs [-n N]`**: the last N (default 50) lines of `<state dir>/logs/chat.log`, with key-shaped strings and
   bot tokens hidden; nothing (exit 0) when there is no log yet. **`bin/chat test [channel]`**: one test message to the
   paired owner (`access.json` `allowFrom`, exactly one id) through the Bot API, then waits for the owner's reply up to
   `AGENT_CHAT_TEST_TIMEOUT` seconds (default 120, at most 600). The token goes to curl on stdin (a config), never an
   argument or the environment. Refused (exit 1) while the orchestrator runs (its plugin reads the bot's updates).
4. **`bin/inbox --count [folder|session|main]`**: the number of unread events for that session (default `main`); `0`
   once read. A delivery (`bin/inbox` hook, `bin/changes`) records the folder's read position in
   `<state dir>/events-read/<main|folder>`; `--count` reads it and writes nothing (no cursor, no delivery, no event).
5. **`bin/dispatch --list [folder]`**: one `<ready|waiting|running><TAB><ref><TAB><folder>` line per ticket, for the
   folder or every folder with a BMAD checkout; read-only (no lock, no start, no marker change, no journal line).

Not in scope: `bin/work`, `bin/chat start` and `ade claude` with an Anthropic API key; the Gemini engine (E1).

## Acceptance criteria
| AC | Criterion | Test |
|---|---|---|
| 1 | `--live-test anthropic` runs the fake engine from the throwaway folder with the task, prints its output, exits 0 on a `READY` line and 1 (reason last) otherwise; no provider or backend variable reaches the engine | `tests/test_hub_interface.sh` `live_test_*` |
| 2 | Without `--dir` the folder it made is removed; a checkout or a hub folder as `--dir` is refused (exit 2); a provider not in `HUB_PROVIDERS_ALLOWED` is still tested, a refused one (owner-only, no key) exits 1 with the reason; gemini and muse exit 1 | same |
| 3 | `bin/keys set anthropic` stores `anthropic-api-key` from stdin; the list shows `anthropic stored`; with it stored a `bin/agent` anthropic run gets `apiKeyHelper` settings and no key in argv or environment | `tests/test_keys.sh`, `test_hub_interface.sh` |
| 4 | `bin/chat logs -n N` prints the last N lines with tokens hidden; bad N exits 2 | `test_hub_interface.sh` `chat_logs_*` |
| 5 | `bin/chat test` sends one message to the paired owner and exits 0 on the reply, 1 on timeout, never with the token in an argument; refused while running or unpaired | `test_hub_interface.sh` `chat_test_*` |
| 6 | `bin/inbox --count` counts unread events for main, a folder or a session name, is 0 after delivery, and writes nothing | `test_hub_interface.sh` `inbox_count_*` |
| 7 | `bin/dispatch --list` prints ready, waiting and running lines for every BMAD folder (or the one named) and starts, locks and journals nothing | `test_hub_interface.sh` `dispatch_list_*` |

## Review fix round (2026-11-22, adversarial review, high risk)
F1 `bin/chat test` peeks (no offset) and refuses on pending updates or a failed peek; F2 `--dir` must be an empty
directory (never `/`, `$HOME`, the hub, a checkout or an ancestor of them), the own folder is under `/tmp`; F3 the live
test sends only the fixed task with no tools, and Claude Code asks before `bin/agent --live-test`; F4 `exec` kept,
`agent.py` removes the run's own folder (also its watchdog); F5 a stored Anthropic key is used by the live test, and by
role runs only with `HUB_AGENT_ANTHROPIC_KEY=1` in `hub.conf`, read once before launch (ADR 0002); F6 `curl -q`,
`SSLKEYLOGFILE` unset; F7 refused while the chat launchd job is loaded, chat lock held for the test; F8 ready only when
the whole trimmed strict-UTF-8 output is `READY`; F9 escapes and control characters removed before redaction, GLM-style
keys hidden whole; F10 the contract notes `--list` runs `bin/sessions` and `--count` is per folder. These supersede the
matching lines in Scope above; `.ade/context/hub-interface.md` is current.

## Verification
(QA records the real output of `bash tests/run.sh` here.)
