# The platform layer (contract, story V1)

The same hub runs on macOS and on Linux (Ubuntu, a VPS). Every macOS-only call in `bin/` goes through `bin/lib.sh`;
`tests/test_platform.sh` greps `bin/` (comments aside) for `security `, `launchctl`, `osascript` and `stat -f` outside it.

## Detection
- `platform` prints `macos` or `linux` (`uname -s` Darwin = macos). `AGENT_PLATFORM=macos|linux` overrides it only
  with `AGENT_PLATFORM_TEST=1` (tests: `make_hub` exports both, `macos`, so the suite tests the macOS behaviour with its
  stubs on any machine; `tests/test_platform.sh` sets `linux` with fakes). A stray `AGENT_PLATFORM` alone changes nothing.
- A checkout's `.claude/settings*.json` may not set `AGENT_PLATFORM`, `AGENT_PLATFORM_TEST`, `AGENT_SECRETS_DIR`,
  `PASSWORD_STORE_DIR` or `HUB_SECRET_STORE` in `env` (`checkout_gate_vars`, part of `provider_checkout_refusal`).
- On Linux, `bin/schedule install` and `bin/work` refuse to run as root (exit 2, "create a user").
- File facts follow the machine's own `stat` (GNU `-c` or BSD `-f`, probed once): `file_mtime`, `file_inode`,
  `file_mode` (octal bits, `700`), `file_owner` (uid).

## Secrets (`bin/secret`, `bin/keys`, `bin/doctor`)
- `secret_store`: `HUB_SECRET_STORE` from `hub.conf` only (`keychain|pass|file`; unset before `hub.conf` is sourced),
  default `keychain` on macOS and `file` on Linux. It never switches by itself when pass appears. `secret_store_refusal`
  (empty = usable): an unknown value; `keychain` off macOS; `pass` not installed and initialised
  (`${PASSWORD_STORE_DIR:-~/.password-store}/.gpg-id`). `secret_store_label`.
- pass: entries `ade/<service>/<name>` (service = `keychain_service`); set with `pass insert -m -f` on stdin.
- file store: `${AGENT_SECRETS_DIR:-${XDG_CONFIG_HOME:-~/.config}/ade/secrets}/<service>/<name>`; folders made with umask 077
  and `chmod 0700`, values 0600, written through a noclobber (`set -C`) 0600 temp file and `mv`. Refused (exit 1): a store
  folder whose low nine bits are not 700 or that is not the user's (the message says `chmod 00700`, which also clears a
  setgid bit), a value file that is not 0600, and any parent up to `$HOME` (or `/`) that is writable by group or others
  without the sticky bit or owned by someone other than the user or root (`dir_loose`).
- `bin/doctor`: `WARN secrets ... the weaker store` for the file store; with pass, a real `pass show` of a stored entry
  without a terminal (`</dev/null`, no `GPG_TTY`), `WARN` when it cannot decrypt (scheduled jobs would fail); `WARN secrets
  file store` naming the entries left in the file store after a switch to another store.
- `secret_get`, `secret_has`, `secret_put <name> <value>` (a shell function argument, then read back), `secret_forget`,
  `secret_names`. Names outside the Keychain are `[A-Za-z0-9][A-Za-z0-9._-]*` (exit 2 otherwise). A value is never an
  argument of another program, in a child's environment, or in a log.

## Scheduled jobs (`bin/schedule`)
- macOS: launchd, unchanged (`launchd_bootout`, `launchd_bootstrap`, `launchd_loaded` in `bin/lib.sh`).
- `bin/chat stop` disables the chat job through the layer: `launchd_disable` + `launchd_bootout` on macOS,
  `systemctl --user disable --now ade-<hub>-chat.service` on Linux. The chat job (both platforms) needs `HUB_CHAT=telegram`
  and `hub_name_claim` (this hub owns its name on the machine).
- Linux: systemd **user** units in `${AGENT_SYSTEMD_USER_DIR:-${XDG_CONFIG_HOME:-~/.config}/systemd/user}`:
  `ade-<hub>-<job>.service` (oneshot, `ExecStart=/bin/bash "<hub>/bin/<job>"`, sync with `--auto`, logs appended to
  `$(state_dir)/logs/<job>.log`) and `ade-<hub>-<job>.timer` (briefing `Mon..Fri *-*-* HH:MM:00`, monitor and sync
  `*:0/30`, `Persistent=true`). Values are escaped for systemd (`%` as `%%`, `$` as `$$`; `systemd_escape`), arguments
  and each `Environment=` assignment quoted whole; the hub name must match `^[A-Za-z0-9._-]+$` (exit 2); a unit that fails
  to enable fails the install (exit 1). With `HUB_CHAT=telegram`: `ade-<hub>-chat.service` (`bin/chat start`, `Restart=always`),
  removed on install otherwise; `HUB_AUTO_SYNC=0` removes sync. Install runs `systemctl --user daemon-reload`, turns
  lingering on (`loginctl enable-linger`, once), `enable --now` each unit; uninstall `disable --now` and removes the files;
  status prints `loaded|absent <unit>` from `is-active`.

## Focus sessions (`bin/work`) in tmux
- `AGENT_TERMINAL=tmux` (default on Linux; any platform on request, ade-cli A6 `ade ui`): the session name is `--name N`,
  else the folder name, with `.` and `:` turned into `_` (`tmux_name`). The hub session is `ade-<hub>` (`tmux_hub_session`).
- When `ade-<hub>` exists: `tmux new-window -d -t =ade-<hub>: -n <name> -c <dir> "bash -l '<launcher>'"` (left in the
  background). Otherwise: `tmux new-session -d -s <name> -c <dir> "bash -l '<launcher>'"`; attach with `tmux attach -t <name>`.
- The command starts with a clean environment: `env -i` with only `HOME PATH TERM LANG LC_ALL USER LOGNAME SHELL TMPDIR
  SSH_AUTH_SOCK XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS` (`tmux_env`), so a caller's variables never reach the session.
- A name starting `ade-` is refused (exit 2); so is a hub whose name another hub on the machine claims (`hub_name_claim`):
  its `ade-<hub>` session would not be this hub's.
- A tmux session `<name>`, or a window `<name>` in `ade-<hub>`, already open: exit 3; `--force` opens `<name>-2`
  (then `-3` ...). tmux
  missing: exit 1 (a dry run still prints the command). `AGENT_TERMINAL=terminal|iterm` on Linux: exit 2.
- `bin/sessions` lists it from the launcher registry, as for any focus session.

## Notifications (`bin/monitor`, `bin/briefing`)
- macOS: `desktop_notify <title> <text>` (osascript), unchanged (`MONITOR_QUIET=1` silences it).
- Linux: a new ALERT is written once as a note event from the monitor's folder to `main` (`bin/notify`, `.ade/context/events.md`),
  text `<the ALERT line> (monitor <script>)`; a chat channel (C5) forwards it. `bin/briefing` shows no notification there.

## CI
- `.github/workflows/ci.yml` runs `bash tests/run.sh` on `macos-latest` and on `ubuntu-latest` (job `ci-linux`), both
  through `better-ade/.github` `verify.yml@v1`.
