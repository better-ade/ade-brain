# The server install (contract, story V2)

`ade server install` and `ade server status` (ade-cli) run `<hub>/bin/server install|status` in the hub's checkout on the
VPS. ade-cli clones the hub first; `bin/server` refuses a hub that is not a git checkout. Linux only (`platform`, exit 2
elsewhere); never as root (exit 2); needs `sudo` (`sudo -v`, exit 2 without).

## `bin/server install [--dry-run] [--accept-risk <row>]...`
1. **Safety rows**, read-only, printed as `<OK|FAIL|ACCEPTED> <row> <detail>`; any FAIL that is not accepted exits 1
   before anything changes:
   - `ssh-password`: `passwordauthentication no` and `kbdinteractiveauthentication no` in `sudo sshd -T`, and in
     `sudo sshd -T -C user=<u>,host=x,addr=203.0.113.1` for `root` and for this user (what a Match block makes of them)
   - `ssh-root`: `permitrootlogin no` the same three ways (`prohibit-password` fails)
   - both SSH rows also fail when `/etc/ssh/sshd_config` or `/etc/ssh/sshd_config.d/*.conf` has any `Match` block
     (read with `sudo -n grep`), since `sshd -T` cannot vouch for an address or group it was not asked about
   - `firewall`: `sudo ufw status verbose` is active, has `Default: deny (incoming)` (or `reject`), and every ALLOW or
     LIMIT rule that is not `OUT` is an SSH port from `sshd -T` (`<port>`, `<port>/tcp`, or `OpenSSH` when it is 22;
     v4 or v6). The hint names those ports (`sudo ufw allow <port>/tcp`), so a non-22 SSH port is never locked out
   - `upgrades`: `apt-config dump APT::Periodic::Unattended-Upgrade` is non-zero and `systemctl is-enabled
     apt-daily-upgrade.timer` is `enabled`
   - `listeners`: `sudo ss -Hltnu` shows nothing beyond loopback (`127.*`, `::1`, `%lo`) but TCP on an SSH port (and
     the UDP DHCP clients on 68 and 546)
   `--accept-risk` takes those row names only (exit 2 otherwise). The rows are checked, never changed.
2. **Packages**: `server_packages` (apt, the distribution's versions): ade's tool set `git python3 tmux gh age` (age:
   `bin/keys share` and `receive`, story I4), then
   `curl ca-certificates nodejs npm ufw unattended-upgrades xvfb x11vnc novnc websockify` (the last four for the browser
   sign-in view, V3); `server_extras` for ade's file viewer: `bat glow
   poppler-utils chafa yazi`, each only where the archive has it (`apt-cache show`; otherwise `<pkg>: not packaged for this
   system; skipped`); `server_docker` (`docker.io docker-compose-v2 docker-buildx`, see Docker below) the same optional
   way. Only the missing ones (`dpkg-query`), in one `sudo apt-get install -y -q --no-install-recommends`.
   `nodejs` is skipped when `node` is on PATH, `npm` when `npm` is (or when that `node` is not the distribution's).
   Ubuntu names bat's command `batcat`.
3. **Tools**, only when missing (any version present is left alone), pinned by `server_pin` (gitleaks `8.30.1`, bun
   `1.3.9`, Claude Code `2.1.330`) and `server_sha` (the sha256 of each release file per arch, x64 and arm64, copied from
   the project's published checksums for that version). Each file is fetched with
   `curl --proto '=https' --tlsv1.2 -fsSL -o <tmp file>`, its exit checked, its sha256 checked, and only then unpacked
   or run: gitleaks' tarball into `~/.local/bin`; bun's zip (`bun-linux-x64-baseline` or `bun-linux-aarch64`) into
   `~/.bun/bin`, linked from `~/.local/bin`; Claude Code's binary (`downloads.claude.ai/claude-code-releases/<v>/linux-<arch>/claude`)
   runs `claude install <v>`. Then Playwright's Chromium with its system libraries, when missing:
   `npx -y @playwright/mcp@0.0.84 install-browser --with-deps chromium` (the MCP's own Playwright, `browser_mcp_pkg`;
   story V3, `.ade/context/browser.md`). Each tool must be found afterwards, or the install exits 1 (never "done"). No piped
   installer script. Another arch exits 1 before anything changes. Tests (AGENT_PLATFORM_TEST=1 only) may replace the
   pins with `AGENT_SERVER_SHA_FILE` (`<tool>-<arch> <sha256>` lines). Then Docker's daemon.json and service (below).
4. **Hub**: the code folder `${AGENT_CODE_DIR:-~/Project}` (bin/work clones each checkout there on first use) and
   `bin/schedule install` when any job is absent (`bin/schedule status`, which lists only the jobs install would install,
   so `HUB_AUTO_SYNC=0` reruns change nothing).
5. Prints the one manual step: `claude` (the Pro or Max login, over SSH), then `bin/keys set telegram`; with Docker
   (below), the optional group command.

A rerun on a set-up host changes nothing. Nothing listens on a public port: Telegram, Remote Control and git connect out.
With Docker it adds: `Docker publishes ports on 127.0.0.1 (<etc>/daemon.json "ip") unless you change it; ports it
publishes elsewhere bypass ufw.`
`--dry-run` prints each changing command as `+ <command>` and changes nothing; it runs the read-only checks (the rows,
`bin/schedule status`) and exits as the install would (1 on an unsafe host or an arch with no pinned build, after printing
the whole plan).

## Docker (story V4): recommended, never needed
For isolated system integration tests run locally, in containers. Nothing about Docker ever fails an install.
- **Packages**: `server_docker` (`docker.io docker-compose-v2 docker-buildx`), each only where the archive has it
  (otherwise `<pkg>: not packaged for this system; skipped`). When a `docker` that is not the distribution's is on PATH
  (`docker.io` not installed: Docker's own `docker-ce`, a snap, podman's shim), none of them and no service step: one
  `docker: <path> is not the distribution's; ... left alone` line.
- **Published ports bypass ufw**: Docker writes its own iptables rules, so `-p 8080:80` on the default `0.0.0.0` would
  be reachable from the internet whatever ufw says. With the distribution's `docker.io` (installed, or in this run's
  apt list), when `/etc/docker/daemon.json` does not exist the install writes `{"ip": "127.0.0.1"}` (`sudo mkdir -p`,
  `sudo cp`, `sudo chmod 644`) before the service starts, so `-p` publishes on loopback by default (reach it over an SSH
  tunnel). An existing daemon.json is never changed: without `"ip": "127.0.0.1"` in it, a note says to set it. A port
  published with an explicit address (`-p 0.0.0.0:8080:80`) still bypasses ufw.
- **Service**: when not both active and enabled, `sudo systemctl enable --now docker`; when active and enabled but
  daemon.json was just written, `sudo systemctl restart docker` so it applies. A failure is a note on stderr.
- **Group**: never `usermod` or `gpasswd`. When this user is not in `docker` (`id -nG`), the manual step prints
  `docker_group_line`: `sudo usermod -aG docker <user, printf %q>, then log in again (the docker group is
  root-equivalent)`. On macOS it is empty.
- **VPN ranges**: Docker's default bridge is `172.17.0.0/16` and new networks come from `172.16.0.0/12`, which can clash
  with a VPN or office range (the host loses the route to it). The fix is by hand, in daemon.json:
  `"default-address-pools": [{"base": "10.200.0.0/16", "size": 24}]` (and `"bip": "10.199.0.1/24"` for the default
  bridge), a range nobody uses, then `sudo systemctl restart docker`.
- **Elsewhere** (bin/lib.sh): `docker_install_line` is `brew install colima docker docker-compose && colima start` on
  macOS (colima: the free headless engine; Docker Desktop is not required) and `sudo apt-get install docker.io
  docker-compose-v2 && sudo systemctl enable --now docker` on Linux. `bin/setup` prints one `warning: docker is not
  installed ...` line when `docker` is not on PATH and goes on. `bin/doctor` prints `OK docker <docker --version>` when
  `docker info` works within 15 s; otherwise `WARN docker` with the install line, `did not answer in 15 s` (a timeout),
  the group command (`permission denied`; on macOS, check the socket's owner), or `docker_start_line` (`colima start (or
  open Docker Desktop)` / `sudo systemctl enable --now docker`). Never MISSING; its exit stays 0. Nothing installs or
  starts Docker on macOS.
- Tests (AGENT_PLATFORM_TEST=1 only) may move `/etc/docker` with `AGENT_DOCKER_ETC`.

## `bin/server status`
`== services` (the `bin/schedule status` lines), then `last sync` and `last monitor` (the time of
`$(state_dir)/logs/sync.log` and `monitor.log`, or `never`), `disk` (free and used for `$HOME`) and `browser` (V3). It
reads no secret.
