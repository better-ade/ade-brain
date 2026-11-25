#!/bin/bash
# Browser automation on the server (story V3, .ade/context/browser.md): bin/browser and its part of bin/server.
# bash tests/test_browser.sh [check ...] runs only the named checks (all of them by default).
# Hermetic: fake Chromium (a Playwright-style install under $HOME/.cache/ms-playwright), Xvfb, x11vnc, websockify and
# npx first on PATH; no browser or display is ever opened, and the only ports are the fakes' own on 127.0.0.1.
. "$(dirname "$0")/helpers.sh"
make_hub; cd "$HUB"
S="$(mktemp -d)"; S="$(cd "$S" && pwd -P)"; mkdir -p "$S/bin" "$S/home" "$S/state"
export HOME="$S/home" AGENT_STATE="$S/state" S; unset PLAYWRIGHT_BROWSERS_PATH HUB_BROWSER_VIEW_PORT HUB_BROWSER_VIEW_MINUTES
trap 'for p in $(cat "$S"/*.pid 2>/dev/null); do kill "$p" 2>/dev/null; done; rm -rf "$S" "$(dirname "$HUB")" "$CLAUDE_HOME" "$(dirname "$AGENT_SYNC_LOG")" "$(dirname "$AGENT_SYNC_LOCK")"' EXIT
bin/new projects/acme >/dev/null; bin/new projects/beta >/dev/null; bin/new projects/ops-x >/dev/null; bin/new ops/x >/dev/null
# each fake records its argv, env and pid, then stays up until killed; $S/<name>-dies makes it exit at once.
# Xvfb writes its display to -displayfd; x11vnc reads and removes its rm: password file; x11vnc and websockify listen
# on 127.0.0.1 at the port they were given (a small python listener), as the real ones do
LISTEN='import socket, sys, time; s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(5); time.sleep(30)'
cat > "$S/bin/Xvfb" <<'STUB'
#!/bin/bash
printf '%s\n' "$@" > "$S/Xvfb.argv"; echo $$ > "$S/Xvfb.pid"; [ -e "$S/Xvfb-dies" ] && exit 1
fd=""; p=""; for a; do [ "$p" = -displayfd ] && fd="$a"; p="$a"; done; [ -n "$fd" ] && eval "echo 99 >&$fd"
exec sleep 30
STUB
cat > "$S/bin/x11vnc" <<STUB
#!/bin/bash
printf '%s\n' "\$@" > "\$S/x11vnc.argv"; echo \$\$ > "\$S/x11vnc.pid"; [ -e "\$S/x11vnc-dies" ] && exit 1
port=""; p=""; for a; do case "\$a" in rm:*) f="\${a#rm:}"; cat "\$f" > "\$S/x11vnc.pw"; rm -f "\$f" ;; esac; [ "\$p" = -rfbport ] && port="\$a"; p="\$a"; done
exec python3 -c '$LISTEN' "\$port"
STUB
cat > "$S/bin/websockify" <<STUB
#!/bin/bash
printf '%s\n' "\$@" > "\$S/websockify.argv"; echo \$\$ > "\$S/websockify.pid"; [ -e "\$S/websockify-dies" ] && exit 1
for a; do case "\$a" in 127.0.0.1:*) port="\${a#127.0.0.1:}"; break ;; esac; done
exec python3 -c '$LISTEN' "\$port"
STUB
printf '#!/bin/bash\nprintf "%%s\\n" "$@" > "$S/npx.argv"\n' > "$S/bin/npx"
CH="$HOME/.cache/ms-playwright/chromium-1234/chrome-linux/chrome"
# Chromium: holds SingletonLock (<host>-<pid>) in its profile while up, and writes its disk cache where it is told
make_chromium() { mkdir -p "$(dirname "$CH")"; cat > "$CH" <<'STUB'
#!/bin/bash
printf '%s\n' "$@" > "$S/chrome.argv"; env > "$S/chrome.env"; echo $$ > "$S/chrome.pid"
for a; do case "$a" in --user-data-dir=*) u="${a#*=}" ;; --disk-cache-dir=*) mkdir -p "${a#*=}" && echo x > "${a#*=}/data" ;; esac; done
[ -n "${u:-}" ] && ln -sfn "host-$$" "$u/SingletonLock"; trap '[ -n "${u:-}" ] && rm -f "$u/SingletonLock"; exit 0' TERM EXIT
for i in $(seq 1 120); do [ -e "$S/close-browser" ] && exit 0; sleep 0.25; done
STUB
  chmod +x "$CH"; }
chmod +x "$S"/bin/*; export PATH="$S/bin:$PATH"
conf() { printf '%s\n' "$@" > hub.conf; }
mcp_args() { bin/browser mcp "$1" | python3 -c 'import json, sys; print("\n".join(json.load(sys.stdin)["args"]))'; }
arg_after() { awk -v k="$1" 'p{print; exit} $0==k{p=1}' "$2"; }
alive() { local f; for f in "$@"; do [ -f "$S/$f.pid" ] && kill -0 "$(cat "$S/$f.pid")" 2>/dev/null && return 0; done; return 1; }
free_port() { python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }
P_ACME="$HOME/.config/ade/browser/projects-acme"

server_installs_chromium() {   # AC1
  grep -q 'xvfb x11vnc novnc websockify' bin/server || fail "the server's package list has the view's packages"
  assert_eq "$(bash -c '. bin/lib.sh; browser_mcp_pkg')" "@playwright/mcp@0.0.84" "one pinned Playwright MCP"
  grep -q 'npx -y "$(browser_mcp_pkg)" install-browser --with-deps chromium' bin/server || fail "bin/server installs Chromium with the MCP's own Playwright"
  rm -rf "$HOME/.cache"; bin/browser status > "$S/out" 2>&1; assert_eq "$?" 1 "no Chromium yet"; assert_contains "$S/out" "missing" "status says missing"
  make_chromium; bin/browser status > "$S/out"; assert_eq "$?" 0 "Chromium found"; grep -q "^ready  chromium $CH" "$S/out" || fail "status: $(cat "$S/out")"
  AGENT_PLATFORM=linux bin/server status > "$S/out" 2>&1; grep -q 'browser  *ready' "$S/out" || fail "ade server status shows the browser: $(cat "$S/out")"
}
isolated_by_default() {   # AC2, AC6
  make_chromium; conf '# none'; mcp_args projects/acme > "$S/args"
  grep -qx -- --isolated "$S/args" || fail "isolated by default: $(cat "$S/args")"; grep -qx -- --user-data-dir "$S/args" && fail "no profile by default"
  grep -qx -- --headless "$S/args" && [ "$(arg_after --browser "$S/args")" = chromium ] || fail "headless Chromium"
  assert_eq "$(arg_after --output-dir "$S/args")" "$HUB/projects/acme/reports/browser" "screenshots and downloads in the folder"
  [ -d projects/acme/reports/browser ] || fail "output folder made"
  echo data > projects/acme/reports/browser/download.csv; git check-ignore -q projects/acme/reports/browser/download.csv || fail "browser files never sync to the hub's git"
  rm -f projects/acme/reports/browser/download.csv
  conf 'HUB_BROWSER_PROFILE_PROJECTS_ACME=1'; mcp_args projects/acme > "$S/args"
  assert_eq "$(arg_after --user-data-dir "$S/args")" "$P_ACME" "profile mode per folder"; grep -qx -- --isolated "$S/args" && fail "profile mode is not isolated"
  assert_eq "$(fmode "$P_ACME")" 700 "profile 0700"
  python3 -c 'import json, sys; a = json.load(open(sys.argv[1]))["browser"]["launchOptions"]["args"]; assert "--disk-cache-dir=" + sys.argv[2] + "/cache" in a, a' "$(arg_after --config "$S/args")" "$P_ACME" ||
    fail "the MCP's Chromium keeps its disk cache in the profile"
  mcp_args projects/beta | grep -qx -- --isolated || fail "another folder stays isolated"
  HUB_BROWSER_PROFILE_PROJECTS_BETA=1 bin/browser mcp projects/beta | grep -q user-data-dir && fail "profile mode comes only from hub.conf"
  bin/browser mcp projects/nope >/dev/null 2>&1; assert_eq "$?" 2 "unknown folder"
}
out_dir_stays_in_folder() {   # AC6: no link at any step, checked before anything is made
  conf '# none'; local o; mkdir -p "$S/elsewhere"
  rm -rf projects/acme/reports; ln -s "$S/elsewhere" projects/acme/reports
  bin/browser mcp projects/acme >/dev/null 2> "$S/err"; assert_eq "$?" 1 "reports/ as a link is refused"; assert_contains "$S/err" "link" "says why"
  [ ! -e "$S/elsewhere/browser" ] || fail "nothing is made through the link"; rm -f projects/acme/reports
  mkdir -p projects/acme/reports; ln -s "$S/elsewhere" projects/acme/reports/browser
  bin/browser mcp projects/acme >/dev/null 2> "$S/err"; assert_eq "$?" 1 "reports/browser as a link is refused"; assert_contains "$S/err" "link" "says why"
  bin/browser run projects/acme >/dev/null 2>&1; assert_eq "$?" 1 "run refuses it too"; rm -f projects/acme/reports/browser
  o="$(mcp_args projects/acme | awk 'p{print; exit} $0=="--output-dir"{p=1}')"; assert_eq "$o" "$HUB/projects/acme/reports/browser" "a plain folder is fine"
}
wired_through_folder_mcp() {   # the folder's own MCP server runs bin/browser run <folder>, which execs the pinned Playwright MCP
  make_chromium; conf '# none'; local m=projects/acme/.mcp.json
  [ -f "$m" ] || fail "bin/new writes the folder's MCP override"
  python3 -c 'import json, sys; s = json.load(open(sys.argv[1]))["enabledMcpjsonServers"]; assert "playwright" in s, s' projects/acme/.claude/settings.json || fail "the folder settings turn the override on"
  # as Claude Code starts it in a session there: in the folder, $CLAUDE_PROJECT_DIR the folder (story I1: no hub path)
  effective() { rm -f "$S/npx.argv"; python3 -c 'import json, os, subprocess, sys
s = json.load(open(sys.argv[1]))["mcpServers"]["playwright"]; d = os.path.dirname(os.path.abspath(sys.argv[1]))
sys.exit(subprocess.call([s["command"]] + s["args"], cwd=d, env=dict(os.environ, CLAUDE_PROJECT_DIR=d)))' "$m" || fail "the folder's MCP command ran: $(cat "$m")"; }
  effective; printf -- '-y\n@playwright/mcp@0.0.84\n--browser\nchromium\n--headless\n--isolated\n--output-dir\n%s\n' "$HUB/projects/acme/reports/browser" > "$S/want"
  assert_eq "$(cat "$S/npx.argv")" "$(cat "$S/want")" "the folder's effective MCP command line (isolated)"
  conf 'HUB_BROWSER_PROFILE_PROJECTS_ACME=1'; effective
  assert_eq "$(arg_after --user-data-dir "$S/npx.argv")" "$P_ACME" "profile mode through the override"; grep -qx -- --isolated "$S/npx.argv" && fail "not isolated in profile mode"
  assert_eq "$(arg_after --config "$S/npx.argv")" "$P_ACME/ade-mcp.json" "the disk cache config"
  echo '{"mcpServers": {}}' > "$m"; bin/new --settings projects/acme >/dev/null || fail "bin/new --settings"
  [ -f "$m.bak" ] && grep -q 'bin/browser' "$m" || fail "bin/new --settings re-renders the MCP override: $(cat "$m")"; rm -f "$m.bak"
  python3 -c 'import json, sys; a = json.load(open(sys.argv[1]))["mcpServers"]["playwright"]["args"]; assert a[-1] == "projects/acme" and "bin/browser run" in a[1], a' "$m" || fail "the override names its folder: $(cat "$m")"
  grep -qF "$HUB" "$m" && fail "the override names the hub path: $(cat "$m")"
}
hub_from_own_path() {   # bin/browser never takes another hub from $HUB outside the tests
  conf '# none'; mkdir -p "$S/other/projects/acme"; echo x > "$S/other/projects/acme/ACCESS.md"
  env -u AGENT_PLATFORM_TEST HUB="$S/other" bin/browser mcp projects/acme > "$S/out" 2>&1 || fail "mcp: $(cat "$S/out")"
  grep -q "\"$HUB/projects/acme/reports/browser\"" "$S/out" && [ ! -e "$S/other/projects/acme/reports" ] || fail "the hub comes from bin/browser's own path: $(cat "$S/out")"
  HUB="$S/other" bin/browser mcp projects/acme | grep -q "$S/other/projects/acme/reports/browser" || fail "the test flag lets a test pick the hub"
}
login_tunnelled_view() {   # AC3
  make_chromium; local wp; wp="$(free_port)"; conf 'HUB_BROWSER_PROFILE_PROJECTS_ACME=1' "HUB_BROWSER_VIEW_PORT=$wp"; rm -f "$S"/*.argv "$S"/*.pid "$S/close-browser" "$S/x11vnc.pw"
  # the view waits for the Enter, which it reads (a read timeout is not an end of input, in Bash 3.2 too, whose read -t
  # says 1 for both): the Enter's writer finds the view still reading (else its write fails and $S/entered is missing)
  rm -f "$S/entered"; { sleep 6; echo && touch "$S/entered"; } 2>/dev/null | { bin/browser login projects/acme https://tool.example/login > "$S/out" 2> "$S/err"
    echo $? > "$S/rc"; }; assert_eq "$(cat "$S/rc")" 0 "login: $(cat "$S/err")"
  [ -e "$S/entered" ] || fail "the view closed before Enter: $(cat "$S/out")"
  grep -qx -- -displayfd "$S/Xvfb.argv" || fail "Xvfb picks its own display: $(cat "$S/Xvfb.argv")"
  grep -qx -- -nolisten "$S/Xvfb.argv" && [ "$(arg_after -nolisten "$S/Xvfb.argv")" = tcp ] || fail "Xvfb takes no TCP"
  local xa; xa="$(arg_after -auth "$S/Xvfb.argv")"; [ -n "$xa" ] || fail "Xvfb needs a cookie (-auth)"
  assert_eq "$(arg_after -auth "$S/x11vnc.argv")" "$xa" "x11vnc uses the cookie"; grep -qx "XAUTHORITY=$xa" "$S/chrome.env" && grep -qx "DISPLAY=:99" "$S/chrome.env" || fail "Chromium uses the cookie on the display"
  [ ! -e "$xa" ] || fail "the cookie is gone after the view"
  grep -qx -- -localhost "$S/x11vnc.argv" && grep -qx -- -nevershared "$S/x11vnc.argv" || fail "x11vnc on localhost, one viewer: $(cat "$S/x11vnc.argv")"
  grep -qx -- -shared "$S/x11vnc.argv" && fail "never shared"
  grep -q -- '^rm:' "$S/x11vnc.argv" || fail "one-time password file, read and removed"; [ -s "$S/x11vnc.pw" ] || fail "a password was set"
  grep -qF -- "$(cat "$S/x11vnc.pw")" "$S/x11vnc.argv" && fail "the password is in an argument"
  assert_eq "$(sed -n 3p "$S/websockify.argv")" "127.0.0.1:$wp" "noVNC on 127.0.0.1 only"
  grep -q 'HUB_BROWSER_VIEW_PORT:-6080' bin/browser || fail "the view's port is 6080 by default"
  grep -qx -- "--user-data-dir=$P_ACME" "$S/chrome.argv" && grep -qx -- "--disk-cache-dir=$P_ACME/cache" "$S/chrome.argv" && grep -qx "https://tool.example/login" "$S/chrome.argv" || fail "Chromium on the folder's profile: $(cat "$S/chrome.argv")"
  grep -q "ssh -N -L $wp:127.0.0.1:$wp " "$S/out" && grep -q "http://localhost:$wp/vnc.html" "$S/out" || fail "the tunnel to use: $(cat "$S/out")"
  sleep 0.5; alive Xvfb x11vnc websockify chrome && fail "the view is still up after Enter"
  # closing the browser ends the view
  rm -f "$S"/*.pid; ( sleep 4; touch "$S/close-browser" ) & local tp=$!; sleep 40 | bin/browser login projects/acme https://tool.example/login > "$S/out" 2>&1 &
  local lp=$! i; for i in $(seq 1 80); do kill -0 "$lp" 2>/dev/null || break; sleep 0.25; done
  kill -0 "$lp" 2>/dev/null && { kill "$lp"; fail "closing the browser ends the view"; }; sleep 0.5; alive Xvfb x11vnc websockify && fail "the view is still up after the browser closed"
  wait "$tp"   # the closer has run before its file is removed (else it would close the next view)
  rm -f "$S/close-browser"
  # the deadline ends it too (HUB_BROWSER_VIEW_MINUTES, 10 by default)
  grep -q 'HUB_BROWSER_VIEW_MINUTES:-10' bin/browser || fail "a 10 minute view by default"
  rm -f "$S"/*.pid; conf 'HUB_BROWSER_PROFILE_PROJECTS_ACME=1' "HUB_BROWSER_VIEW_PORT=$wp" 'HUB_BROWSER_VIEW_MINUTES=0.1'
  sleep 40 | bin/browser login projects/acme https://tool.example/login > "$S/out" 2>&1 & lp=$!
  for i in $(seq 1 80); do kill -0 "$lp" 2>/dev/null || break; sleep 0.25; done
  kill -0 "$lp" 2>/dev/null && { kill "$lp"; fail "the view outlived its deadline"; }; sleep 0.5; alive Xvfb x11vnc websockify chrome && fail "a process outlived the deadline"
  grep -qi "minutes" "$S/out" || fail "says the time ran out: $(cat "$S/out")"
  conf '# none'; bin/browser login projects/acme https://tool.example/ >/dev/null 2> "$S/err" </dev/null; assert_eq "$?" 2 "profile mode off"; assert_contains "$S/err" "HUB_BROWSER_PROFILE_PROJECTS_ACME=1" "says how"
  conf 'HUB_BROWSER_PROFILE_PROJECTS_ACME=1'; bin/browser login projects/acme 'javascript:alert(1)' >/dev/null 2>&1 </dev/null; assert_eq "$?" 2 "only http(s)"
}
view_fails_closed() {   # AC3: a view that is not fully up prints no password and leaves nothing running
  make_chromium; local wp t; wp="$(free_port)"; conf 'HUB_BROWSER_PROFILE_PROJECTS_ACME=1' "HUB_BROWSER_VIEW_PORT=$wp"
  python3 -c "$LISTEN" "$wp" & local busy=$!; sleep 0.5; rm -f "$S"/*.pid
  bin/browser login projects/acme https://tool.example/ > "$S/out" 2> "$S/err" </dev/null; assert_eq "$?" 1 "the view's port is taken"
  assert_contains "$S/err" "127.0.0.1:$wp" "names the port"; grep -qi password "$S/out" && fail "no password for a view that never opened"
  alive Xvfb && fail "nothing started on a taken port"; kill "$busy" 2>/dev/null; wait "$busy" 2>/dev/null
  for t in Xvfb x11vnc websockify; do
    rm -f "$S"/*.pid; touch "$S/$t-dies"; bin/browser login projects/acme https://tool.example/ > "$S/out" 2> "$S/err" </dev/null; assert_eq "$?" 1 "$t did not come up"
    grep -qi password "$S/out" && fail "no password when $t is down: $(cat "$S/out")"; sleep 0.5; alive Xvfb x11vnc websockify chrome && fail "everything stopped when $t failed"
    rm -f "$S/$t-dies"; done
  true
}
profiles_per_folder() {   # AC4
  make_chromium; conf 'HUB_BROWSER_PROFILE_PROJECTS_ACME=1' 'HUB_BROWSER_PROFILE_PROJECTS_BETA=1'
  a="$(mcp_args projects/acme | awk 'p{print; exit} $0=="--user-data-dir"{p=1}')"; b="$(mcp_args projects/beta | awk 'p{print; exit} $0=="--user-data-dir"{p=1}')"
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" != "$b" ] || fail "each folder its own profile: [$a] [$b]"
  # projects/ops-x and ops/x: two folders, two switches, two profiles
  conf 'HUB_BROWSER_PROFILE_OPS_X=1'; mcp_args projects/ops-x | grep -qx -- --isolated || fail "ops/x's switch leaves projects/ops-x isolated"
  conf 'HUB_BROWSER_PROFILE_OPS_X=1' 'HUB_BROWSER_PROFILE_PROJECTS_OPS_X=1'
  assert_eq "$(mcp_args ops/x | awk 'p{print; exit} $0=="--user-data-dir"{p=1}')" "$HOME/.config/ade/browser/ops-x" "ops/x's profile"
  assert_eq "$(mcp_args projects/ops-x | awk 'p{print; exit} $0=="--user-data-dir"{p=1}')" "$HOME/.config/ade/browser/projects-ops-x" "projects/ops-x's profile"
  conf 'HUB_BROWSER_PROFILE_PROJECTS_ACME=1' 'HUB_BROWSER_PROFILE_PROJECTS_BETA=1'
  echo cookie > "$a/Cookies"; echo cookie > "$b/Cookies"; mkdir -p "$a/cache"; echo x > "$a/cache/data"
  # a profile Chromium has open is not deleted under it; a stale lock is no obstacle
  sleep 30 & local cp=$!; ln -s "host-$cp" "$a/SingletonLock"
  bin/browser forget projects/acme > "$S/out" 2>&1; assert_eq "$?" 1 "a profile in use is kept"; [ -f "$a/Cookies" ] || fail "the open profile survived"
  kill "$cp"; wait "$cp" 2>/dev/null
  bin/browser forget projects/acme > "$S/out" 2>&1 || fail "forget: $(cat "$S/out")"
  [ ! -e "$a" ] && [ ! -e "$a/cache" ] || fail "acme's profile and cache deleted"; [ -f "$b/Cookies" ] || fail "beta's profile kept"
  [ ! -e "$HOME/.cache/ade/browser" ] || fail "no cache copy outside the profile"
  bin/browser forget projects/acme | grep -q "no profile" || fail "forgetting twice is fine"
  rm -rf "$b"; ln -s "$S" "$b"; bin/browser forget projects/beta >/dev/null 2>&1; assert_eq "$?" 1 "a linked profile is not followed"; [ -d "$S/bin" ] || fail "the link's target survived"; rm -f "$b"
  mkdir -p "$S/real-root/projects-beta"; mv "$HOME/.config/ade/browser" "$S/old-root"; ln -s "$S/real-root" "$HOME/.config/ade/browser"
  bin/browser forget projects/beta >/dev/null 2>&1; assert_eq "$?" 1 "a linked profile root is refused"; [ -d "$S/real-root/projects-beta" ] || fail "nothing deleted through the link"
  rm -f "$HOME/.config/ade/browser"; mv "$S/old-root" "$HOME/.config/ade/browser"
}
ask_first_unchanged() {   # AC5, and the permissions that hold for every browser action and its switches
  local a f; mcp_args projects/acme > "$S/args"
  for a in --allow-unrestricted-file-access --no-sandbox --caps --allowed-origins --blocked-origins --ignore-https-errors; do grep -qx -- "$a" "$S/args" && fail "the hub changes the plugin's rules ($a)"; done
  grep -Eqi 'browser.? plugin.*ask-first' templates/hub/CLAUDE.md && grep -qi 'telegram' templates/hub/CLAUDE.md || fail "the hub rules keep the browser plugin's ask-first rules, asked over Telegram on the server"
  for f in templates/folder-settings.json .claude/settings.json projects/acme/.claude/settings.json; do
    python3 - "$f" <<'PY' || fail "$f: the browser's acting tools, its sign-in and forget, and hub.conf edits ask; profiles are never read"
import json, sys
p = json.load(open(sys.argv[1]))["permissions"]; ask, deny = p["ask"], p.get("deny", [])
for t in ("browser_click", "browser_type", "browser_fill_form", "browser_file_upload", "browser_press_key", "browser_select_option", "browser_evaluate"):
    for srv in ("playwright", "plugin_browser_playwright"):
        assert "mcp__%s__%s" % (srv, t) in ask, (srv, t)
for r in ("Bash(*bin/browser login*)", "Bash(*bin/browser forget*)", "Bash(*ade browser*)", "Bash(*hub.conf*)"):
    assert r in ask, r
assert any(r.startswith("Edit(") and r.endswith("/hub.conf)") for r in ask), "hub.conf edits"
assert "Read(~/.config/ade/browser/**)" in deny, deny
PY
  done
  grep -qi 'policy' .ade/context/browser.md && grep -qi 'same Unix user' .ade/context/browser.md || fail "the contract says folder isolation is policy, not a Unix boundary"
}

ALL="server_installs_chromium isolated_by_default out_dir_stays_in_folder wired_through_folder_mcp hub_from_own_path login_tunnelled_view view_fails_closed profiles_per_folder ask_first_unchanged"
for t in ${@:-$ALL}; do "$t"; done
echo ok
