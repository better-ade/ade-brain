# ade at session start (story T1)

- **Check:** `ade_path` (bin/lib.sh): `command -v ade`, else `~/.local/bin/ade` (where ade's installer puts it).
- **Installer:** `curl -fsSL https://raw.githubusercontent.com/better-ade/ade-cli/main/install.sh | bash` (`ade_install_line`).
  `ADE_CLI_INSTALL_URL` overrides the address, for tests only.
  The installer comes from ade-cli's `main` branch: unpinned, accepted with story T1.
- **Session start** (`bin/context` with no args at the hub root, and `bin/context <folder> --rules`): one line from
  `ade_session_line`:
  - present: `ade: <ade --version> is installed; \`ade help\` lists its commands: run it before the first ade command in a session.`
    Found only in `~/.local/bin` (not on this PATH): the line names the full path to run it by, or to add `~/.local/bin` to PATH.
    `ade --version` runs under `timeout 5`.
  - missing: starts the installer in the background (stdin /dev/null, never waited for, a refusing `sudo` first on its
    PATH; it succeeds only when an ade is then found, else "the installer finished but no ade ..." is logged) and prints
    `ade: not installed; installing it in the background (log: <log>); until it lands the bin/ scripts do the same jobs.`
  - the last background install failed: `ade: the last install failed (<log's last non-empty line>; log: <log>); trying again: ...`
  - `HUB_ADE_INSTALL=off`: `ade: not installed (HUB_ADE_INSTALL=off); install it by hand: <install line>. ...`; nothing runs.
- **State** (per machine, `$(state_dir)/ade/`, i.e. `~/.agent-hub/<hub>/ade/`): `install.log`; `install.lock/` (a
  directory, its `pid` inside; one install at a time; stale when the pid is gone, or with no pid after 10 minutes);
  `install.failed` (the last background install failed; removed when it is reported or an install succeeds).
- **hub.conf key:** `HUB_ADE_INSTALL` (`off` turns the install off; anything else, or unset, is on). Read from
  `hub.conf`, then `.local/hub.conf` (a machine may turn it off). `AGENT_ADE_INSTALL` overrides it: `bin/briefing`
  sets it `off` for its unattended `claude -p` (whose own SessionStart hook runs `bin/context`), and for tests
  `tests/helpers.sh` `make_hub` sets it `off` and a dead local `ADE_CLI_INSTALL_URL`, so no test reaches the real installer.
- **bin/setup:** `ade_install_fg`: `ok ade (<version>)`, or runs the installer in the foreground (`installed ade (<version>)`;
  a failure is a warning on stderr and never changes setup's exit status); off: prints the install line.
  Its foreground install does not use the sudo-refusing shim: the installer may prompt for sudo there (setup is interactive).
- **bin/doctor:** `OK ade <version>` or `MISSING ade not installed: <install line>`.
- Out of scope: upgrading an installed ade.
