# V1: the hub runs on Linux (platform layer)

Status: **Merged (2026-11-22, PR #55)**: `bash tests/run.sh` green in CI on the merge. Earlier: ready for development
(2026-11-21). Risk: high (secrets and services).
Owner's intent (2026-11-21): the orchestrator runs as a long-running process on an Ubuntu VPS, with code checkouts on
the server too. Verification command: `bash tests/run.sh`, on macOS and in CI on ubuntu-latest.

## Goal
Every macOS-only call in `bin/` goes through a small platform layer in `bin/lib.sh`, so the same hub runs on Ubuntu.

| Need | macOS (unchanged) | Linux |
|---|---|---|
| secrets (`bin/secret`, `bin/keys`) | Keychain (`security`) | `pass` when installed and initialised; else a store at `~/.config/ade/secrets/` (dir 0700, files 0600, owner-only), and `bin/doctor` says it is the weaker store |
| scheduled jobs (`bin/schedule`) | launchd | systemd **user** units and timers (with `loginctl enable-linger`) |
| focus sessions (`bin/work`) | Terminal / iTerm / ADE | a detached `tmux` session named after the folder; `bin/sessions` lists it; attach with `tmux attach -t <name>` |
| notifications (`bin/monitor`) | `osascript` | an event in the hub log (C6), forwarded to Telegram by C5 |
| file times (`stat -f`) | BSD `stat` | GNU `stat -c` |

## Acceptance criteria (`tests/test_platform.sh`; Linux cases run in CI on ubuntu-latest, macOS cases on macOS)
| AC | Criterion |
|---|---|
| 1 | `platform` prints `macos` or `linux`; every `bin/` script that used a macOS-only tool now calls the layer (a grep test lists none left outside `lib.sh`) |
| 2 | Linux secrets: set, has, read, forget round-trip with `pass` (fake) and with the file store; the file store refuses to run if its dir is not 0700 |
| 3 | A value never appears in argv, the environment of child processes, or a log (same checks as on macOS) |
| 4 | `bin/schedule install` on Linux writes the units and timers for briefing, monitor, sync (and chat with `HUB_CHAT=telegram`), and `uninstall` removes them (fake `systemctl`) |
| 5 | `bin/work` on Linux opens a detached tmux session running the launcher; a second one for the same folder is refused (as today) |
| 6 | `bin/monitor` on Linux writes an ALERT event instead of calling `osascript` |
| 7 | The whole suite passes on ubuntu-latest in CI (the hub's CI gains a Linux job) |
