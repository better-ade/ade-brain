# V2: `ade server install` sets up an Ubuntu VPS

Status: **Merged (2026-11-22, PR #58)**: `bash tests/run.sh` green in CI on the merge. Earlier: ready for development
(2026-11-21). Risk: high (a server reachable from the internet). Depends on V1, A1 (ade-cli).

## Goal
`ade server install` (run on the VPS over SSH, as a normal user with sudo) makes it a hub host: installs git, python3,
node, bun, tmux, gitleaks and Claude Code; clones the hub; checks out code under `~/Project`; runs `bin/schedule
install`; and checks the host's safety. Nothing listens on a public port: Telegram, Remote Control and git all connect out.

## Acceptance criteria (`tests/test_server.sh` with fake `apt-get`, `systemctl`, `ufw`, `sshd`; no network)
| AC | Criterion |
|---|---|
| 1 | Installs only missing packages, from a fixed list, with pinned versions where the tool allows; reruns change nothing |
| 2 | Refuses to run as root; needs a user with sudo |
| 3 | Safety check, reported as rows and failing the install unless `--accept-risk <row>`: SSH password login off, root login off, ufw on allowing only SSH, unattended security upgrades on |
| 4 | Prints the one manual step: `claude` login over SSH (the Pro or Max login), then `bin/keys set telegram` |
| 5 | `ade server status`: services running, last sync, last monitor run, disk space; never a secret |
| 6 | A dry run (`--dry-run`) prints every command and changes nothing |
