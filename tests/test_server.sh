#!/bin/bash
# bin/server (story V2, .ade/context/server.md): `ade server install` and `ade server status` on an Ubuntu VPS.
# bash tests/test_server.sh [check ...] runs only the named checks (all of them by default).
# Hermetic: AGENT_PLATFORM=linux and fakes first on PATH (sudo, apt-get, apt-cache, apt-config, dpkg-query, sshd, ufw, ss,
# systemctl, loginctl, curl, id, uname); nothing is installed, no network is reached, no real service is touched. The
# fake release files have their own sha256, given to bin/server through AGENT_SERVER_SHA_FILE (test flag only).
. "$(dirname "$0")/helpers.sh"
make_hub; cd "$HUB"
S="$(mktemp -d)"; S="$(cd "$S" && pwd -P)"; mkdir -p "$S/bin" "$S/home" "$S/state" "$S/apt" "$S/dl"
export HOME="$S/home" AGENT_STATE="$S/state" AGENT_PLATFORM=linux AGENT_SYSTEMD_USER_DIR="$S/units" AGENT_SSHD_ETC="$S/ssh"
export AGENT_SERVER_SHA_FILE="$S/pins"
export PASSWORD_STORE_DIR="$S/no-pass" S
trap 'rm -rf "$S" "$(dirname "$HUB")" "$CLAUDE_HOME" "$(dirname "$AGENT_SYNC_LOG")" "$(dirname "$AGENT_SYNC_LOCK")"' EXIT
REAL_UID="$(id -u)"
# every fake logs one line to $S/calls; state lives in files under $S
cat > "$S/bin/sudo" <<'STUB'
#!/bin/bash
echo "sudo $*" >> "$S/calls"; [ -e "$S/nosudo" ] && exit 1
while [ "${1#-}" != "$1" ]; do [ "$1" = -v ] && exit 0; shift; done; exec "$@"
STUB
cat > "$S/bin/apt-get" <<'STUB'
#!/bin/bash
echo "apt-get $*" >> "$S/calls"; [ "$1" = install ] || exit 0
for p in "$@"; do case "$p" in -*|install) ;; *) echo "$p" >> "$S/installed" ;; esac; done
STUB
printf '#!/bin/bash\nfor p; do :; done; grep -qx "$p" "$S/installed" 2>/dev/null && printf "install ok installed" || exit 1\n' > "$S/bin/dpkg-query"
# apt-cache: every package is in the archive except those in $S/unpackaged (yazi by default, as on Ubuntu 24.04)
printf '#!/bin/bash\necho "apt-cache $*" >> "$S/calls"; for p; do :; done; grep -qx "$p" "$S/unpackaged" 2>/dev/null && exit 100; echo "Package: $p"\n' > "$S/bin/apt-cache"
# sshd -T: the global settings ($S/sshd.conf); -C user=root and -C user=<other> read sshd.root and sshd.user when present
cat > "$S/bin/sshd" <<'STUB'
#!/bin/bash
echo "sshd $*" >> "$S/calls"; f=sshd.conf
case "$*" in *"-C user=root,"*) [ -f "$S/sshd.root" ] && f=sshd.root ;; *-C*) [ -f "$S/sshd.user" ] && f=sshd.user ;; esac; cat "$S/$f"
STUB
printf '#!/bin/bash\necho "ufw $*" >> "$S/calls"; cat "$S/ufw.status"\n' > "$S/bin/ufw"
printf '#!/bin/bash\necho "ss $*" >> "$S/calls"; cat "$S/ss.out"\n' > "$S/bin/ss"
printf '#!/bin/bash\necho "apt-config $*" >> "$S/calls"; cat "$S/aptconf"\n' > "$S/bin/apt-config"
cat > "$S/bin/systemctl" <<'STUB'
#!/bin/bash
echo "systemctl $*" >> "$S/calls"
case " $* " in *" enable --now "*) for a; do u="$a"; done; echo "$u" >> "$S/active"; exit 0 ;; *" disable --now "*) for a; do u="$a"; done; grep -vx "$u" "$S/active" > "$S/active.t"; mv "$S/active.t" "$S/active"; exit 0 ;;
  *" is-enabled apt-daily-upgrade.timer "*) cat "$S/uu" 2>/dev/null || echo disabled; exit 0 ;; *" is-active "*) for a; do u="$a"; done; grep -qx "$u" "$S/active" 2>/dev/null; exit ;; esac
exit 0
STUB
printf '#!/bin/bash\necho "loginctl $*" >> "$S/calls"; [ "$1" = show-user ] && echo Linger=no; exit 0\n' > "$S/bin/loginctl"
# curl: never the network. The release files from $S/dl (gitleaks, bun, claude); a URL listed in $S/curlfail fails
cat > "$S/bin/curl" <<'STUB'
#!/bin/bash
echo "curl $*" >> "$S/calls"; o=""; u=""
while [ $# -gt 0 ]; do case "$1" in -o|--proto) [ "$1" = -o ] && o="$2"; shift 2 ;; -*) shift ;; *) u="$1"; shift ;; esac; done
grep -qxF "$u" "$S/curlfail" 2>/dev/null && exit 22
case "$u" in
  */gitleaks_*.tar.gz) cp "$S/dl/gitleaks.tar.gz" "$o" ;;
  */bun-v*/bun-linux-*.zip) cp "$S/dl/bun.zip" "$o" ;;
  */claude-code-releases/*/linux-*/claude) cp "$S/dl/claude" "$o" ;;
  *) echo "fake curl: unexpected $u" >&2; exit 22 ;;
esac
STUB
# npx @playwright/mcp install-browser --with-deps chromium (story V3): a Playwright-style Chromium under ~/.cache/ms-playwright
printf '#!/bin/bash\necho "npx $*" >> "$S/calls"; [ -e "$S/npxfail" ] && exit 0; c="$HOME/.cache/ms-playwright/chromium-1234/chrome-linux"; mkdir -p "$c"; printf "#!/bin/bash\\n" > "$c/chrome"; chmod +x "$c/chrome"\n' > "$S/bin/npx"
printf '#!/bin/bash\n[ "${1:-}" = -u ] && [ -e "$S/root" ] && { echo 0; exit 0; }\nexec /usr/bin/id "$@"\n' > "$S/bin/id"
printf '#!/bin/bash\n[ "${1:-}" = -m ] && { cat "$S/arch"; exit 0; }\nexec /usr/bin/uname "$@"\n' > "$S/bin/uname"
chmod +x "$S"/bin/*
# a PATH that holds no real gitleaks, bun or claude: the fakes, then only the system tools the scripts use
mkdir -p "$S/sys"; for c in bash sh env cat grep sed awk tr cut head tail sort uniq wc mkdir rm mv cp ln chmod ls date dirname basename \
  mktemp printf python3 git tar gzip find df stat touch sleep ps pgrep tee xargs readlink id uname shasum sha256sum; do
  p="$(PATH=/usr/bin:/bin:/usr/sbin:/sbin command -v "$c" 2>/dev/null)"; [ -n "$p" ] && [ ! -e "$S/sys/$c" ] && ln -s "$p" "$S/sys/$c"; done
rm -f "$S/sys/id" "$S/sys/uname"; export PATH="$S/bin:$S/sys"
# the fake releases: gitleaks's tarball, bun's zip, Claude Code's binary (which installs itself with `install <version>`)
sha() { python3 -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$1"; }
mkdir -p "$S/g"; printf '#!/bin/bash\necho 8.30.1\n' > "$S/g/gitleaks"; chmod +x "$S/g/gitleaks"
tar -czf "$S/dl/gitleaks.tar.gz" -C "$S/g" gitleaks
python3 -c 'import sys, zipfile; z = zipfile.ZipFile(sys.argv[1], "w"); z.writestr("bun-linux-x64-baseline/bun", "#!/bin/bash\necho 1.3.9\n"); z.close()' "$S/dl/bun.zip"
printf '#!/bin/bash\n[ "$1" = install ] || exit 1\nmkdir -p "$HOME/.local/bin"; printf "#!/bin/bash\\necho $2\\n" > "$HOME/.local/bin/claude"; chmod +x "$HOME/.local/bin/claude"\n' > "$S/dl/claude"
pins() { printf 'gitleaks-x64 %s\nbun-x64 %s\nclaude-x64 %s\n' "$(sha "$S/dl/gitleaks.tar.gz")" "$(sha "$S/dl/bun.zip")" "$(sha "$S/dl/claude")" > "$S/pins"; }

safe() { printf 'port 22\npasswordauthentication no\nkbdinteractiveauthentication no\npermitrootlogin no\n' > "$S/sshd.conf"
  rm -f "$S/sshd.root" "$S/sshd.user"; mkdir -p "$S/ssh/sshd_config.d"; printf 'Include /etc/ssh/sshd_config.d/*.conf\nPasswordAuthentication no\n' > "$S/ssh/sshd_config"; rm -f "$S/ssh/sshd_config.d"/*
  ufw_rules 'OpenSSH ALLOW IN Anywhere' 'OpenSSH (v6) ALLOW IN Anywhere (v6)'
  printf 'tcp LISTEN 0 4096 0.0.0.0:22 0.0.0.0:*\ntcp LISTEN 0 4096 [::]:22 [::]:*\ntcp LISTEN 0 4096 127.0.0.53%%lo:53 0.0.0.0:*\nudp UNCONN 0 0 127.0.0.54:53 0.0.0.0:*\nudp UNCONN 0 0 10.0.0.5%%eth0:68 0.0.0.0:*\n' > "$S/ss.out"
  echo enabled > "$S/uu"; printf 'APT::Periodic::Unattended-Upgrade "1";\n' > "$S/aptconf"; }
# ufw_rules <rule>...: an active ufw (status verbose) that denies incoming by default, with those rules
ufw_rules() { { printf 'Status: active\nLogging: on (low)\nDefault: %s (incoming), allow (outgoing), disabled (routed)\nNew profiles: skip\n\nTo Action From\n-- ------ ----\n' "${DEFAULT_IN:-deny}"; printf '%s\n' "$@"; } > "$S/ufw.status"; }
reset() { echo yazi > "$S/unpackaged"; echo x86_64 > "$S/arch"; pins; rm -rf "$S/calls" "$S/installed" "$S/root" "$S/nosudo" "$S/units" "$HOME/.local" "$HOME/.bun" "$HOME/.cache" "$HOME/Project" "$S/active" "$S/curlfail" "$S/npxfail" "$S/bin/node" "$S/bin/npm"
  : > "$S/calls"; rm -f hub.conf; safe; }
install() { bin/server install "$@" > "$S/out" 2> "$S/err"; rc=$?; }
# changes: every call that is not one of the known read-only ones (a new kind of call counts as a change)
changes() { grep -vE -e '^sudo -v$' -e '^sudo -n (sshd -T|ufw status verbose$|ss -Hltnu$|grep -Eil )' -e '^sshd -T( |$)' -e '^ufw status verbose$' \
  -e '^ss -Hltnu$' -e '^apt-cache show [^ ]+$' -e '^apt-config dump APT::Periodic::Unattended-Upgrade$' -e '^systemctl (--user )?(is-enabled|is-active) [^ ]+$' \
  -e '^loginctl show-user ' "$S/calls"; }

installs_missing_from_fixed_list() {   # AC1
  reset; echo git > "$S/installed"; install; assert_eq "$rc" 0 "install: $(cat "$S/err" "$S/out")"
  grep -q '^apt-get install -y -q --no-install-recommends python3 tmux gh age curl ca-certificates nodejs npm ufw unattended-upgrades xvfb x11vnc novnc websockify bat glow poppler-utils chafa$' "$S/calls" || fail "only the missing packages, ade's tools too: $(grep apt-get "$S/calls")"
  grep -q 'yazi: not packaged for this system; skipped' "$S/out" || fail "an extra that is not packaged is skipped with a note: $(cat "$S/out")"
  [ -x "$HOME/.local/bin/gitleaks" ] || fail "gitleaks installed"
  grep -q "^curl --proto =https --tlsv1.2 -fsSL -o .* https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_linux_x64.tar.gz$" "$S/calls" || fail "gitleaks pinned, over https only: $(grep curl "$S/calls")"
  grep -q "^curl --proto =https --tlsv1.2 -fsSL -o .* https://github.com/oven-sh/bun/releases/download/bun-v1.3.9/bun-linux-x64-baseline.zip$" "$S/calls" && [ "$("$HOME/.bun/bin/bun")" = 1.3.9 ] || fail "bun pinned: $(grep curl "$S/calls")"
  grep -q "^curl --proto =https --tlsv1.2 -fsSL -o .* https://downloads.claude.ai/claude-code-releases/2.1.330/linux-x64/claude$" "$S/calls" && [ "$("$HOME/.local/bin/claude")" = 2.1.330 ] || fail "claude pinned"
  grep -q '^npx -y @playwright/mcp@0.0.84 install-browser --with-deps chromium$' "$S/calls" || fail "Chromium from the MCP's own Playwright (V3): $(grep npx "$S/calls")"
  [ -d "$HOME/Project" ] || fail "code folder"
  [ -f "$S/units/ade-hub-monitor.timer" ] || fail "bin/schedule install ran"
  : > "$S/calls"; install; assert_eq "$rc" 0 "rerun: $(cat "$S/err")"
  assert_eq "$(changes)" "" "a rerun installs nothing"
  grep -q "all present" "$S/out" && grep -q "gitleaks: present" "$S/out" && grep -q "claude: present" "$S/out" && grep -q "chromium: present" "$S/out" || fail "rerun says so: $(cat "$S/out")"
  reset; echo 'HUB_AUTO_SYNC=0' > hub.conf; install; assert_eq "$rc" 0 "install without auto sync: $(cat "$S/err")"
  [ ! -e "$S/units/ade-hub-sync.timer" ] || fail "no sync job with HUB_AUTO_SYNC=0"
  : > "$S/calls"; install; assert_eq "$rc" 0 "rerun without auto sync"; assert_eq "$(changes)" "" "a rerun with HUB_AUTO_SYNC=0 changes nothing"
  reset; printf '#!/bin/bash\necho v20\n' > "$S/bin/node"; printf '#!/bin/bash\necho 10\n' > "$S/bin/npm"; chmod +x "$S/bin/node" "$S/bin/npm"; install; assert_eq "$rc" 0 "node already here"
  grep '^apt-get install' "$S/calls" | grep -qwE 'nodejs|npm' && fail "node and npm already on PATH are left alone: $(grep apt-get "$S/calls")"
  rm -f "$S/bin/node" "$S/bin/npm"
}
downloads_verified() {   # AC1: every download is over https, checked against its pinned sha256, and the tool must be there after
  local t; for t in gitleaks bun claude; do
    reset; printf '%s-x64 %064d\n' "$t" 0 > "$S/pins.t"; grep -v "^$t-" "$S/pins" >> "$S/pins.t"; mv "$S/pins.t" "$S/pins"; install
    assert_eq "$rc" 1 "$t does not match its pinned sha256"; grep -q "sha256" "$S/err" || fail "says why ($t): $(cat "$S/err")"
    grep -q "Pro or Max login" "$S/out" && fail "the install said done after $t failed"
  done
  [ ! -e "$HOME/.local/bin/claude" ] || fail "an unverified claude was installed"
  reset; echo "https://github.com/oven-sh/bun/releases/download/bun-v1.3.9/bun-linux-x64-baseline.zip" > "$S/curlfail"; install
  assert_eq "$rc" 1 "a failed download fails the install"; grep -q "Pro or Max login" "$S/out" && fail "never done after a failed download"
  [ ! -e "$HOME/.bun/bin/bun" ] || fail "no bun after a failed download"
  reset; printf '#!/bin/bash\nexit 0\n' > "$S/dl/claude.t"; cp "$S/dl/claude" "$S/dl/claude.keep"; mv "$S/dl/claude.t" "$S/dl/claude"; pins; install
  assert_eq "$rc" 1 "an installer that leaves no claude"; grep -q "claude" "$S/err" || fail "names the tool"; grep -q "Pro or Max login" "$S/out" && fail "never done without claude"
  mv "$S/dl/claude.keep" "$S/dl/claude"
  reset; touch "$S/npxfail"; install; assert_eq "$rc" 1 "an install-browser that leaves no Chromium"; assert_contains "$S/err" "Chromium" "names it"
  grep -q "Pro or Max login" "$S/out" && fail "never done without Chromium"
  reset; echo riscv64 > "$S/arch"; install; assert_eq "$rc" 1 "an arch with no pinned build"; assert_contains "$S/err" "riscv64" "names the machine"
  assert_eq "$(changes)" "" "nothing changes before the arch is known to be served"
  grep -q 'bun.sh/install\|claude.ai/install.sh' bin/server && fail "no piped installer script"; true
}
refuses_root_needs_sudo() {   # AC2
  reset; touch "$S/root"; install; assert_eq "$rc" 2 "root"; assert_contains "$S/err" "never as root" "says why"
  assert_eq "$(grep -c . "$S/calls")" 0 "nothing ran as root"
  reset; touch "$S/nosudo"; install; assert_eq "$rc" 2 "no sudo"; assert_contains "$S/err" "sudo" "says why"
  assert_eq "$(changes)" "" "nothing installed without sudo"
  reset; AGENT_PLATFORM=macos bin/server install >/dev/null 2>&1; assert_eq "$?" 2 "not Linux"
}
safety_rows() {   # AC3
  reset; install; local r; for r in ssh-password ssh-root firewall upgrades listeners; do grep -q "^OK  *$r " "$S/out" || fail "row $r: $(cat "$S/out")"; done
  grep -q '^sudo -n ufw status verbose$' "$S/calls" && grep -q '^sudo -n ss -Hltnu$' "$S/calls" || fail "reads ufw verbose and the listeners: $(cat "$S/calls")"
  reset; printf 'port 22\npasswordauthentication yes\nkbdinteractiveauthentication no\npermitrootlogin prohibit-password\n' > "$S/sshd.conf"; install
  assert_eq "$rc" 1 "unsafe ssh fails the install"; grep -q '^FAIL  *ssh-password ' "$S/out" && grep -q '^FAIL  *ssh-root ' "$S/out" || fail "rows: $(cat "$S/out")"
  assert_eq "$(changes)" "" "nothing changes on an unsafe host"; grep -q -- "--accept-risk" "$S/err" || fail "names the way out"
  install --accept-risk ssh-password; assert_eq "$rc" 1 "one accepted, one still failing"
  install --accept-risk ssh-password --accept-risk ssh-root; assert_eq "$rc" 0 "both accepted: $(cat "$S/err")"
  grep -q '^ACCEPTED  *ssh-password ' "$S/out" || fail "accepted rows shown as such"
  # keyboard-interactive is password login too
  reset; printf 'port 22\npasswordauthentication no\nkbdinteractiveauthentication yes\npermitrootlogin no\n' > "$S/sshd.conf"; install
  assert_eq "$rc" 1 "kbd-interactive on"; grep -q '^FAIL  *ssh-password .*kbdinteractiveauthentication' "$S/out" || fail "names kbd-interactive: $(cat "$S/out")"
  # a Match block: what holds globally can be undone for one user or address
  reset; printf 'port 22\npasswordauthentication yes\nkbdinteractiveauthentication no\npermitrootlogin no\n' > "$S/sshd.user"; install
  assert_eq "$rc" 1 "a Match block that allows passwords for a user"; grep -q '^FAIL  *ssh-password .*Match' "$S/out" || fail "names the Match block: $(cat "$S/out")"
  grep -q "^sshd -T -C user=root,host=x,addr=203.0.113.1$" "$S/calls" && grep -q "^sshd -T -C user=$(id -un),host=x,addr=203.0.113.1$" "$S/calls" || fail "checks root and this user: $(grep sshd "$S/calls")"
  reset; printf 'port 22\npasswordauthentication no\nkbdinteractiveauthentication no\npermitrootlogin yes\n' > "$S/sshd.root"; install
  assert_eq "$rc" 1 "a Match block that lets root in"; grep -q '^FAIL  *ssh-root .*Match' "$S/out" || fail "ssh-root names the Match block: $(cat "$S/out")"
  reset; printf 'Match Address 10.0.0.0/8\n  PasswordAuthentication yes\n' > "$S/ssh/sshd_config.d/60-lan.conf"; install
  assert_eq "$rc" 1 "a Match block for another address"; grep -q '^FAIL  *ssh-password .*Match' "$S/out" && grep -q '^FAIL  *ssh-root .*Match' "$S/out" || fail "any Match block fails the SSH rows: $(cat "$S/out")"
  # the firewall: active, deny incoming by default, and only the SSH port open (ALLOW or LIMIT)
  reset; printf 'Status: inactive\n' > "$S/ufw.status"; install; assert_eq "$rc" 1 "ufw off"; grep -q '^FAIL  *firewall .*ufw allow 22/tcp' "$S/out" || fail "firewall row with the SSH port: $(cat "$S/out")"
  reset; ufw_rules '22/tcp ALLOW IN Anywhere' '80/tcp ALLOW IN Anywhere'; install
  assert_eq "$rc" 1 "a public web port"; grep -q '^FAIL  *firewall .*80/tcp' "$S/out" || fail "names the extra rule: $(cat "$S/out")"
  reset; DEFAULT_IN=allow ufw_rules '22/tcp ALLOW IN Anywhere'; install
  assert_eq "$rc" 1 "default allow incoming"; grep -q '^FAIL  *firewall .*deny incoming' "$S/out" || fail "names the default: $(cat "$S/out")"
  reset; DEFAULT_IN=reject ufw_rules '22/tcp LIMIT IN Anywhere' '22/tcp (v6) LIMIT IN Anywhere (v6)' 'Anywhere ALLOW OUT 10.0.0.0/8'; install
  assert_eq "$rc" 0 "reject by default, SSH rate-limited, an outgoing rule: $(cat "$S/out")"
  reset; ufw_rules '22/tcp ALLOW IN Anywhere' '8080/tcp LIMIT IN Anywhere'; install
  assert_eq "$rc" 1 "a LIMIT rule opens a port"; grep -q '^FAIL  *firewall .*8080/tcp' "$S/out" || fail "names the LIMIT rule: $(cat "$S/out")"
  reset; ufw_rules '22/tcp (OpenSSH) ALLOW IN Anywhere' 'Anywhere ALLOW IN 203.0.113.9'; install
  assert_eq "$rc" 1 "a rule for every port"; grep -q '^FAIL  *firewall .*Anywhere' "$S/out" || fail "names it: $(cat "$S/out")"
  # SSH on another port: that port is the allowed one, and the hint names it (no lock-out)
  reset; sed -i.b 's/^port 22$/port 2222/' "$S/sshd.conf"; ufw_rules '2222/tcp ALLOW IN Anywhere' '2222/tcp (v6) ALLOW IN Anywhere (v6)'
  sed -i.b 's/:22 /:2222 /' "$S/ss.out"; install; assert_eq "$rc" 0 "SSH on 2222: $(cat "$S/out")"
  ufw_rules 'OpenSSH ALLOW IN Anywhere' '2222/tcp ALLOW IN Anywhere'; install; assert_eq "$rc" 1 "22 open while SSH is on 2222"; grep -q '^FAIL  *firewall .*OpenSSH' "$S/out" || fail "names it: $(cat "$S/out")"
  printf 'Status: inactive\n' > "$S/ufw.status"; install; grep -q '^FAIL  *firewall .*ufw allow 2222/tcp' "$S/out" || fail "the hint keeps SSH on 2222 reachable: $(cat "$S/out")"
  grep -q 'ufw allow 22/tcp\|allow OpenSSH' "$S/out" && fail "the hint opens 22, not the SSH port: $(cat "$S/out")"
  # upgrades: APT's own value and the timer that runs them
  reset; echo disabled > "$S/uu"; install; assert_eq "$rc" 1 "upgrades timer off"; grep -q '^FAIL  *upgrades ' "$S/out" || fail "upgrades row"
  reset; printf 'APT::Periodic::Unattended-Upgrade "0";\n' > "$S/aptconf"; install; assert_eq "$rc" 1 "upgrades off in APT"; grep -q '^FAIL  *upgrades ' "$S/out" || fail "upgrades row (apt)"
  reset; install; grep -q '^apt-config dump APT::Periodic::Unattended-Upgrade$' "$S/calls" && grep -q '^systemctl is-enabled apt-daily-upgrade.timer$' "$S/calls" || fail "reads APT and the timer: $(cat "$S/calls")"
  # listeners: nothing but sshd beyond loopback
  reset; printf 'tcp LISTEN 0 511 0.0.0.0:80 0.0.0.0:*\n' >> "$S/ss.out"; install; assert_eq "$rc" 1 "a public listener"; grep -q '^FAIL  *listeners .*0.0.0.0:80' "$S/out" || fail "names it: $(cat "$S/out")"
  reset; printf 'tcp LISTEN 0 511 [::1]:3000 [::]:*\ntcp LISTEN 0 511 127.0.0.1:6080 0.0.0.0:*\n' >> "$S/ss.out"; install; assert_eq "$rc" 0 "loopback listeners are fine: $(cat "$S/out")"
  reset; printf 'udp UNCONN 0 0 0.0.0.0:5353 0.0.0.0:*\n' >> "$S/ss.out"; install; assert_eq "$rc" 1 "a public UDP port"; grep -q '^FAIL  *listeners .*5353' "$S/out" || fail "names it"
  install --accept-risk listeners; assert_eq "$rc" 0 "accepted"
  install --accept-risk nonsense; assert_eq "$rc" 2 "an unknown row"
}
manual_step_printed() {   # AC4
  reset; install; assert_eq "$rc" 0 "install"
  grep -q "claude .*Pro or Max login" "$S/out" || fail "claude login step: $(cat "$S/out")"
  grep -q "bin/keys set telegram" "$S/out" || fail "telegram key step"
  grep -qi "public port" "$S/out" || fail "says nothing listens"
}
status_report() {   # AC5
  reset; install >/dev/null; printf 'pl-SECRET-%s\n' "$RANDOM" | bin/secret --set telegram-bot-token 2>/dev/null || fail "store a secret"
  mkdir -p "$AGENT_STATE/logs"; echo synced > "$AGENT_STATE/logs/sync.log"; echo ran > "$AGENT_STATE/logs/monitor.log"
  echo ade-hub-monitor.timer > "$S/active"; : > "$S/calls"   # only monitor running
  bin/server status > "$S/out" 2>&1; assert_eq "$?" 0 "status: $(cat "$S/out")"
  grep -q 'loaded  ade-hub-monitor.timer' "$S/out" && grep -q 'absent  ade-hub-sync.timer' "$S/out" || fail "services: $(cat "$S/out")"
  grep -q 'last sync  *20[0-9-]* [0-9:]* UTC' "$S/out" && grep -q 'last monitor  *20' "$S/out" || fail "last runs: $(cat "$S/out")"
  grep -q 'disk  *[0-9.]* GB free' "$S/out" || fail "disk: $(cat "$S/out")"
  grep -q 'pl-SECRET' "$S/out" && fail "status printed a secret"
  rm -f "$AGENT_STATE/logs/sync.log"; bin/server status > "$S/out"; grep -q 'last sync  *never' "$S/out" || fail "never synced"
}
dry_run_changes_nothing() {   # AC6
  # with SIGPIPE ignored, as CI runners leave it: a reader that closed early would make a writer's next write fail
  reset; ( trap '' PIPE; bin/server install --dry-run ) > "$S/out" 2> "$S/err"; assert_eq "$?" 0 "dry run: $(cat "$S/err")"
  grep -q 'write error' "$S/err" && fail "a write failed in the dry run: $(cat "$S/err")"
  assert_eq "$(changes)" "" "a dry run installs nothing"; [ ! -e "$S/units" ] && [ ! -d "$HOME/Project" ] && [ ! -e "$HOME/.local/bin/gitleaks" ] || fail "a dry run changed the machine"
  grep -q '^+ sudo apt-get install -y -q --no-install-recommends git python3 tmux gh .* bat glow poppler-utils chafa$' "$S/out" || fail "prints the apt command, ade's tools too: $(cat "$S/out")"
  grep -q '^+ curl --proto =https --tlsv1.2 -fsSL -o .*gitleaks_8.30.1_linux_x64.tar.gz$' "$S/out" && grep -q '^+ curl .*bun-v1.3.9/bun-linux-x64-baseline.zip$' "$S/out" && grep -q '^+ curl .*claude-code-releases/2.1.330/linux-x64/claude$' "$S/out" || fail "prints the tool downloads: $(cat "$S/out")"
  grep -q 'install 2.1.330$' "$S/out" || fail "prints the claude install: $(cat "$S/out")"
  grep -q '^+ npx -y @playwright/mcp@0.0.84 install-browser --with-deps chromium$' "$S/out" || fail "prints the Chromium install"
  grep -q "^+ mkdir -p $HOME/Project" "$S/out" && grep -q "^+ $HUB/bin/schedule install" "$S/out" || fail "prints the hub steps: $(cat "$S/out")"
  grep -q '^systemctl --user is-active ' "$S/calls" || fail "the dry run checks the jobs with bin/schedule status"
  printf 'passwordauthentication yes\npermitrootlogin no\n' > "$S/sshd.conf"; bin/server install --dry-run > "$S/out" 2>&1; assert_eq "$?" 1 "dry run on an unsafe host exits as the install would"
  grep -q '^+ sudo apt-get install' "$S/out" || fail "still prints the plan"; assert_eq "$(changes)" "" "still changes nothing"
  reset; echo riscv64 > "$S/arch"; bin/server install --dry-run > "$S/out" 2>&1; assert_eq "$?" 1 "dry run on an arch with no pinned build"
  grep -q '^+ sudo apt-get install' "$S/out" && grep -q "^+ $HUB/bin/schedule install" "$S/out" && grep -q riscv64 "$S/out" || fail "prints its plan on an unsupported arch: $(cat "$S/out")"
  assert_eq "$(changes)" "" "still changes nothing"
}

ALL="installs_missing_from_fixed_list downloads_verified refuses_root_needs_sudo safety_rows manual_step_printed status_report dry_run_changes_nothing"
for t in ${@:-$ALL}; do "$t"; done
echo ok
