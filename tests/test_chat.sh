#!/bin/bash
# bin/chat (story C5): the hub's orchestrator with its channels (Telegram first). Fake claude, fake security, no network.
. "$(dirname "$0")/helpers.sh"
make_hub; cd "$HUB"; stub_security; export AGENT_STATE="$(mktemp -d)"
K="123456789:TEST-telegram-token-VALUE-abc"
export AGENT_LAUNCHAGENTS="$(mktemp -d)"; FAKE="$(mktemp -d)"; mkdir -p "$FAKE/bin" "$FAKE/rec"; export FAKE_REC="$FAKE/rec"
# the fake claude records its folder, argv and environment (outside the hub and its state dir). Like the plugin, it
# reads the token from its state folder's .env and writes bot.pid (not with FAKE_NOBOT); a child prints its environment.
cat > "$FAKE/bin/claude" <<'STUB'
#!/bin/bash
pwd -P > "$FAKE_REC/pwd"; printf '%s\n' "$@" > "$FAKE_REC/argv"
printf '%s' "${TELEGRAM_BOT_TOKEN:-}" > "$FAKE_REC/envtoken"; printf '%s' "${TELEGRAM_STATE_DIR:-}" > "$FAKE_REC/statedir"
printf '%s' "${CLAUDE_CONFIG_DIR:-}" > "$FAKE_REC/configdir"; d="${TELEGRAM_STATE_DIR:-/nonexistent}"
if [ -f "$d/.env" ]; then python3 -c 'import os, sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$d/.env" > "$FAKE_REC/envmode"; sed -n 's/^TELEGRAM_BOT_TOKEN=//p' "$d/.env" > "$FAKE_REC/filetoken"; fi
bash -c env > "$FAKE_REC/childenv"
[ -n "${FAKE_NOBOT:-}" ] || echo $$ > "$d/bot.pid"
# FAKE_STDIN: whether its stdin is still open after 2 s (open), or ended (eof); Python, as Bash 3.2's read -t says 1 for both
[ -z "${FAKE_STDIN:-}" ] || python3 -c 'import os, select; r = select.select([0], [], [], 2)[0]
print("open" if not r else ("eof" if not os.read(0, 1) else "data"))' > "$FAKE_REC/stdin"
echo SESSION-OUTPUT-MARKER
[ -z "${FAKE_SLEEP:-}" ] || sleep "$FAKE_SLEEP"
exit 0
STUB
printf '#!/bin/bash\nexit 0\n' > "$FAKE/bin/bun"
printf '#!/bin/bash\necho "$*" >> "$FAKE/launchctl.log"\nexit 0\n' > "$FAKE/bin/launchctl"
chmod +x "$FAKE/bin/claude" "$FAKE/bin/bun" "$FAKE/bin/launchctl"; export FAKE PATH="$FAKE/bin:$PATH"
unset TELEGRAM_BOT_TOKEN TELEGRAM_STATE_DIR HUB_CHAT HUB_CHANNELS CLAUDE_CONFIG_DIR
CH="$AGENT_STATE/channels/telegram"
# access state as the plugin keeps it after pairing; a start without a terminal needs allowlist and no groups
# (the groups default is set apart: Bash 3.2 keeps the backslash in "${3:-{\}}", Bash 5 drops it)
access() { local g="${3:-}"; [ -n "$g" ] || g='{}'; mkdir -p "$1"
  printf '{"dmPolicy": "%s", "allowFrom": ["99887766"], "groups": %s}\n' "$2" "$g" > "$1/access.json"
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$1/access.json" 2>/dev/null || fail "the access.json fixture is not JSON [$(cat "$1/access.json")]"; }
access "$CH" allowlist
reset_rec() { rm -f "$FAKE_REC"/*; }
launched() { [ -f "$FAKE_REC/argv" ]; }
arg_after() { awk -v f="$1" 'p{print; exit} $0==f{p=1}' "$FAKE_REC/argv"; }
wait_for() { local i=0; while ! eval "$1"; do i=$((i+1)); [ $i -lt 100 ] || return 1; sleep 0.1; done; }
# start_within <s>: bin/chat start without a terminal must return within s seconds; past that it is stopped (never a hang)
start_within() { local i=0 p; bin/chat start </dev/null >/dev/null 2>&1 & p=$!
  while kill -0 "$p" 2>/dev/null; do i=$((i+1)); [ "$i" -lt $(($1 * 10)) ] || { kill "$p" 2>/dev/null; return 124; }; sleep 0.1; done
  wait "$p"; }
PIDF="$AGENT_STATE/chat/chat.pid"

start_launches_channel_session() {
  printf '%s\n' "$K" | bin/keys set telegram >/dev/null 2>&1 || fail "bin/keys set telegram"
  bin/secret --has telegram-bot-token || fail "the token is stored as telegram-bot-token"
  bin/keys | grep -E '^telegram ' | grep -q stored || fail "bin/keys lists telegram as stored [$(bin/keys)]"
  reset_rec; bin/chat start </dev/null >"$FAKE/out" 2>&1 || fail "start [$(cat "$FAKE/out")]"
  launched || fail "start launched nothing"
  assert_eq "$(arg_after --channels)" "plugin:telegram@claude-plugins-official" "the telegram channel is attached"
  assert_eq "$(cat "$FAKE_REC/pwd")" "$(cd "$HUB" && pwd -P)" "runs at the hub root"
  assert_eq "$(arg_after --permission-mode)" "manual" "the chat session asks for every permission by default"
  assert_eq "$(cat "$FAKE_REC/configdir")" "$CLAUDE_HOME" "the hub's Claude config dir (not ~/.claude) is passed on"
  assert_eq "$(arg_after --remote-control)" "hub" "Remote Control on, named after the orchestrator"
  grep -q dangerously "$FAKE_REC/argv" && fail "skip-permissions reached claude"
  echo 'HUB_WORK_MODE=acceptEdits' > hub.conf; reset_rec; bin/chat start </dev/null >/dev/null 2>&1 || fail "start, work mode set"
  assert_eq "$(arg_after --permission-mode)" "manual" "HUB_WORK_MODE is not the chat mode"
  echo 'HUB_CHAT_MODE=plan' > hub.conf; reset_rec; bin/chat start </dev/null >/dev/null 2>&1 || fail "start in plan mode"
  assert_eq "$(arg_after --permission-mode)" "plan" "HUB_CHAT_MODE sets the mode"
  printf 'HUB_ORCHESTRATOR=desk\n' > hub.conf; reset_rec; bin/chat start </dev/null >/dev/null 2>&1 || fail "start named"
  assert_eq "$(arg_after --remote-control)" "desk" "HUB_ORCHESTRATOR names the session"
  local m; for m in opus sonnet claude-opus-5-5 'opus[1m]' us.anthropic.claude-opus-5-5:0; do
    printf 'HUB_MODEL=%s\n' "$m" > hub.conf; reset_rec; bin/chat start </dev/null >"$FAKE/out" 2>&1 || fail "start with HUB_MODEL=$m [$(cat "$FAKE/out")]"
    assert_eq "$(arg_after --model)" "$m" "HUB_MODEL=$m reaches claude as --model"; done
  for m in -x 'a b' 'a;b' '$(x)' 'a|b'; do
    printf "HUB_MODEL='%s'\n" "$m" > hub.conf; reset_rec; bin/chat start </dev/null >"$FAKE/out" 2>&1 && fail "HUB_MODEL=$m is refused"
    grep -q "bad HUB_MODEL" "$FAKE/out" || fail "HUB_MODEL=$m says bad HUB_MODEL [$(cat "$FAKE/out")]"; launched && fail "HUB_MODEL=$m launched nothing"; done
  printf 'HUB_ORCHESTRATOR="-x"\n' > hub.conf; reset_rec; bin/chat start </dev/null >/dev/null 2>&1; assert_eq "$?" "2" "a bad orchestrator name"
  launched && fail "a bad orchestrator name launched"; rm -f hub.conf
  # the plugin runs on bun: none on PATH refuses before launch
  NS="$(mktemp -d)"; for c in bash sh dirname basename sed grep awk tr cat python3 git ps date mkdir chmod rm wc id sleep stat script env cut head; do
    ln -s "$(command -v "$c")" "$NS/$c"; done; ln -s "$FAKE/bin/claude" "$NS/claude"; ln -s "$(dirname "$STORE")/security" "$NS/security"
  reset_rec; out=$(PATH="$NS" bin/chat start </dev/null 2>&1); assert_eq "$?" "1" "no bun"
  echo "$out" | grep -q bun || fail "the refusal names bun [$out]"; launched && fail "launched without bun"
  # the session's own output never reaches the log without a terminal; bin/chat's own lines do
  reset_rec; bin/chat start </dev/null >"$FAKE/log" 2>&1 || fail "start, logged"
  grep -q SESSION-OUTPUT-MARKER "$FAKE/log" && fail "the session's output is in the log"; grep -q "^chat:" "$FAKE/log" || fail "bin/chat's line is in the log"
  true
}

token_short_lived_file() {
  reset_rec; rm -f "$CH/.env"; bin/chat start </dev/null >"$FAKE/out" 2>&1 || fail "start"
  assert_eq "$(cat "$FAKE_REC/filetoken")" "$K" "the plugin reads the token from its state folder's .env"
  assert_eq "$(cat "$FAKE_REC/envmode")" "600" "the .env is 0600"
  assert_eq "$(cat "$FAKE_REC/envtoken")" "" "the token is not in the session's environment"
  grep -qF "$K" "$FAKE_REC/childenv" && fail "a child of the session sees the token"
  grep -qF "$K" "$FAKE_REC/argv" && fail "the token is in claude's argv"
  grep -qF "$K" "$STORE.argv" && fail "the token is in a security argument"
  grep -qF "$K" "$FAKE/out" && fail "bin/chat printed the token"
  wait_for "[ ! -e '$CH/.env' ]" || fail "the .env was not deleted once the plugin wrote bot.pid"
  grep -rqF --exclude-dir=tests "$K" "$HUB" "$AGENT_STATE" "$CLAUDE_HOME" && fail "the token is left in a file (outside this test)"
  # no bot.pid: deleted after the time limit anyway
  reset_rec; FAKE_NOBOT=1 AGENT_CHAT_ENV_TTL=1 bin/chat start </dev/null >/dev/null 2>&1 || fail "start, no bot.pid"
  wait_for "[ ! -e '$CH/.env' ]" || fail "the .env outlived its time limit"
  # while it runs: no process argument or environment carries it
  reset_rec; FAKE_SLEEP=20 bin/chat start </dev/null >/dev/null 2>&1 & bg=$!
  wait_for "[ -f '$FAKE_REC/argv' ]" || fail "the long session did not start"
  procs="$(ps -axwwe -o command=)"; case "$procs" in *"$K"*) fail "the token is in a running process's argv or environment" ;; esac
  bin/chat stop >/dev/null 2>&1; wait "$bg" 2>/dev/null; true
}

missing_token_refuses() {
  bin/keys forget telegram >/dev/null 2>&1; reset_rec
  out=$(TELEGRAM_BOT_TOKEN=from-shell bin/chat start </dev/null 2>&1); assert_eq "$?" "1" "no token in the Keychain"
  echo "$out" | grep -q "run bin/keys set telegram" || fail "the refusal says how [$out]"
  launched && fail "launched without a Keychain token (a shell token is never used)"
  [ -e "$AGENT_STATE/chat/lock" ] && fail "a refused start kept the lock"
  printf '%s\n' "$K" | bin/keys set telegram >/dev/null 2>&1
}

skip_permissions_refused() {
  reset_rec; bin/chat start --dangerously-skip-permissions </dev/null >/dev/null 2>&1; assert_eq "$?" "2" "the flag as an argument"
  bin/chat start --allow-dangerously-skip-permissions </dev/null >/dev/null 2>&1; assert_eq "$?" "2" "the allow flag as an argument"
  for s in HUB_CHAT_MODE=bypassPermissions HUB_WORK_MODE=bypassPermissions 'HUB_CLAUDE="claude --dangerously-skip-permissions"'; do
    echo "$s" > hub.conf; bin/chat start </dev/null >/dev/null 2>&1; assert_eq "$?" "2" "hub setting $s"; done
  printf '#!/bin/bash\nexec claude --dangerously-skip-permissions "$@"\n' > "$FAKE/bin/yolo"; chmod +x "$FAKE/bin/yolo"
  echo 'HUB_CLAUDE=yolo' > hub.conf; bin/chat start </dev/null >/dev/null 2>&1; assert_eq "$?" "2" "a wrapper that skips permissions"
  echo 'HUB_CHAT_MODE=nonsense' > hub.conf; bin/chat start </dev/null >/dev/null 2>&1; assert_eq "$?" "2" "an unknown mode"
  rm -f hub.conf; launched && fail "a refused start launched claude"; true
}

single_instance() {
  reset_rec; FAKE_SLEEP=30 bin/chat start </dev/null >/dev/null 2>&1 &
  wait_for "[ -f '$FAKE_REC/argv' ] && [ -s '$PIDF' ]" || fail "the session did not start"
  pid=$(awk '{print $1}' "$PIDF"); reset_rec
  out=$(bin/chat start </dev/null 2>&1); assert_eq "$?" "1" "a second start"
  echo "$out" | grep -qw "$pid" || fail "the refusal names the running pid $pid [$out]"
  launched && fail "a second session was launched"; true
}

stop_and_status() {
  pid=$(awk '{print $1}' "$PIDF"); : > "$AGENT_LAUNCHAGENTS/ai.agent-hub.hub.chat.plist"; rm -f "$FAKE/launchctl.log"
  out=$(bin/chat status 2>&1) || fail "status"
  echo "$out" | grep -q "not connected" && fail "a live bot.pid is a connected channel [$out]"
  echo "$out" | grep -q "groups: 0" || fail "status counts groups [$out]"
  echo "$out" | grep -q "running" || fail "status: running [$out]"; echo "$out" | grep -qw "$pid" || fail "status names the pid [$out]"
  echo "$out" | grep -q "since" || fail "status says since when [$out]"
  echo "$out" | grep -q "allowlist" || fail "status names the policy [$out]"
  echo "$out" | grep -qF "99887766" && fail "status showed a Telegram id"; echo "$out" | grep -qF "$K" && fail "status showed the token"
  bin/chat stop >/dev/null 2>&1 || fail "stop"
  kill -0 "$pid" 2>/dev/null && fail "stop returned while pid $pid still runs"; [ -e "$PIDF" ] && fail "stop left the pid file"
  grep -q "disable gui/$(id -u)/ai.agent-hub.hub.chat" "$FAKE/launchctl.log" || fail "stop disables the launchd job [$(cat "$FAKE/launchctl.log")]"
  rm -f "$AGENT_LAUNCHAGENTS/ai.agent-hub.hub.chat.plist"
  out=$(bin/chat status 2>&1); echo "$out" | grep -q "stopped" || fail "status after stop [$out]"
  bin/chat stop >/dev/null 2>&1 || fail "stop when stopped is fine"
  printf '{"dmPolicy": "123456 secret"}\n' > "$CH/access.json"
  out=$(bin/chat status 2>&1); echo "$out" | grep -q "123456" && fail "status repeated an unknown policy value [$out]"
  rm -f "$CH/access.json"; out=$(bin/chat status 2>&1)
  echo "$out" | grep -q "not paired" || fail "status without access state [$out]"
  access "$CH" allowlist '{"-100123": {}, "-100456": {}}'; out=$(bin/chat status 2>&1)
  echo "$out" | grep -q "groups: 2" || fail "status counts 2 groups [$out]"; echo "$out" | grep -q "100123" && fail "status showed a group id"
  access "$CH" allowlist
  # running, but the plugin has not connected (no live bot.pid newer than the session)
  reset_rec; rm -f "$CH/bot.pid"; FAKE_NOBOT=1 FAKE_SLEEP=30 bin/chat start </dev/null >/dev/null 2>&1 &
  wait_for "[ -f '$FAKE_REC/argv' ] && [ -s '$PIDF' ]" || fail "the session did not start"
  out=$(bin/chat status 2>&1); echo "$out" | grep -q "running, channel not connected" || fail "status without bot.pid [$out]"
  bin/chat stop >/dev/null 2>&1
  # a stale pid file (no such process, or not this hub's channel session) is not a running session, and stop spares it
  echo "1 2026-01-01T00:00Z" > "$PIDF"; bin/chat status | grep -q stopped || fail "pid 1 is not the chat session"
  sh -c 'sleep 30; :' x --channels y --remote-control other & f=$!; sleep 0.3; echo "$f 2026-01-01T00:00Z" > "$PIDF"
  bin/chat status | grep -q stopped || fail "another hub's channel session is not this one"
  bin/chat stop >/dev/null 2>&1; kill -0 "$f" 2>/dev/null || fail "stop killed another hub's process"; kill "$f" 2>/dev/null; rm -f "$PIDF"
}

start_lock_and_access() {
  L="$AGENT_STATE/chat/lock"; mkdir -p "$L"; sh -c 'sleep 30; :' bin/chat & f=$!; sleep 0.3; echo "$f" > "$L/pid"
  reset_rec; out=$(bin/chat start </dev/null 2>&1); assert_eq "$?" "1" "a start while another holds the lock"
  echo "$out" | grep -q "lock" || fail "the refusal names the lock [$out]"; launched && fail "launched past a held lock"
  [ -d "$L" ] || fail "a refused start removed another's lock"; kill "$f"; wait "$f" 2>/dev/null
  echo 999999 > "$L/pid"; reset_rec; bin/chat start </dev/null >/dev/null 2>&1 || fail "a stale lock is taken over"; launched || fail "stale lock: nothing launched"
  # without a terminal (launchd) only an allowlist with no groups starts; in a terminal pairing may run
  for a in "pairing" "allowlist|{\"-100123\": {}}" "disabled"; do g=""; case "$a" in *"|"*) g="${a#*|}" ;; esac; access "$CH" "${a%%|*}" "$g"
    reset_rec; out=$(bin/chat start </dev/null 2>&1); assert_eq "$?" "1" "no terminal, access [$a]"
    echo "$out" | grep -qi "allowlist" || fail "the refusal says allowlist [$out]"; launched && fail "launched with access [$a]"; done
  rm -f "$CH/access.json"; reset_rec; bin/chat start </dev/null >/dev/null 2>&1; assert_eq "$?" "1" "no terminal, not paired"
  access "$CH" pairing; reset_rec; in_pty bin/chat start </dev/null >/dev/null 2>&1; launched || fail "a terminal start while pairing"
  access "$CH" allowlist; rm -rf "$L"
}

no_terminal_session_ends() {
  # without a terminal claude runs under script(1) with a stdin that stays open while it runs, and the start returns
  # once the session ends (util-linux script waits for its children and its stdin: a feeder that waited for script hung)
  reset_rec; FAKE_STDIN=1 start_within 15; assert_eq "$?" "0" "a start without a terminal returns once the session ends"
  launched || fail "no session launched"
  assert_eq "$(cat "$FAKE_REC/stdin" 2>/dev/null)" "open" "the session's stdin stays open while it runs (an end would reach claude as Ctrl-D)"
  FAKE_NOBOT=1 AGENT_CHAT_ENV_TTL=60 start_within 15; assert_eq "$?" "0" "a start waits for no .env time limit"
}

same_folder_name() {
  # two hubs whose folders are both named "hub", no HUB_NAME: the second may not share the first's state, Keychain or job
  H1="$HUB"; NH="$(mktemp -d)"; make_hub; H2="$HUB"; access "$NH/.agent-hub/hub/channels/telegram" allowlist
  reset_rec; (unset AGENT_STATE; cd "$H1" && HOME="$NH" HUB="$H1" bin/chat start </dev/null >/dev/null 2>&1) || fail "start, first hub"
  reset_rec; out=$(unset AGENT_STATE; cd "$H2" && HOME="$NH" HUB="$H2" bin/chat start </dev/null 2>&1); assert_eq "$?" "2" "a second hub of the same name"
  echo "$out" | grep -q "HUB_NAME" || fail "the refusal says set HUB_NAME [$out]"; launched && fail "the second hub launched"
  L2="$(mktemp -d)"; echo HUB_CHAT=telegram > "$H2/hub.conf"
  out=$(unset AGENT_STATE; cd "$H2" && HOME="$NH" HUB="$H2" AGENT_LAUNCHAGENTS="$L2" SCHEDULE_DRY=1 bin/schedule install 2>&1)
  [ -f "$L2/ai.agent-hub.hub.chat.plist" ] && fail "the second hub installed a chat job under the first's label [$out]"
  HUB="$H1"; cd "$H1"
}

schedule_installs_chat_job() {
  L="$(mktemp -d)"; C="$L/ai.agent-hub.hub.chat.plist"
  AGENT_LAUNCHAGENTS="$L" SCHEDULE_DRY=1 bin/schedule install >/dev/null || fail "install"
  [ -f "$C" ] && fail "chat job installed without HUB_CHAT=telegram"
  echo HUB_CHAT=telegram > hub.conf
  out=$(AGENT_LAUNCHAGENTS="$L" SCHEDULE_DRY=1 bin/schedule install) || fail "install with chat"
  [ -f "$C" ] || fail "no chat plist with HUB_CHAT=telegram [$out]"
  plist_ok "$C" || fail "chat plist is not valid"
  assert_contains "$C" "<string>ai.agent-hub.hub.chat</string>" "chat label"
  assert_contains "$C" "<string>$HUB/bin/chat</string><string>start</string>" "the job runs bin/chat start"
  assert_contains "$C" "<key>KeepAlive</key><true/>" "restarted if it dies"
  assert_contains "$C" "$AGENT_STATE/logs/chat.log" "chat log in the state dir"
  grep -q "{{" "$C" && fail "unfilled placeholder in the chat plist"
  grep -qiE "dangerously|bypass" "$C" && fail "the chat job skips permissions"; grep -qF "$K" "$C" && fail "the token is in the plist"
  [ -f "$L/ai.agent-hub.hub.sync.plist" ] || fail "the other jobs stay"
  assert_contains "$C" "$HOME/.bun/bin" "the plist PATH has bun"
  assert_contains "$C" "<key>TERM</key><string>xterm-256color</string>" "the plist sets TERM"
  [ "$(fmode "$AGENT_STATE/logs")" = 700 ] || fail "the logs folder is private"
  rm -f "$FAKE/launchctl.log"; AGENT_LAUNCHAGENTS="$L" bin/schedule install >/dev/null 2>&1
  grep -q "enable gui/$(id -u)/ai.agent-hub.hub.chat" "$FAKE/launchctl.log" || fail "install enables the chat job [$(cat "$FAKE/launchctl.log")]"
  echo HUB_CHAT=slack > hub.conf
  out=$(AGENT_LAUNCHAGENTS="$L" SCHEDULE_DRY=1 bin/schedule install 2>&1) || fail "install, unknown chat"
  [ -f "$C" ] && fail "an unknown HUB_CHAT kept the chat job"; echo "$out" | grep -q "removed ai.agent-hub.hub.chat" || fail "removal reported [$out]"
  rm -f hub.conf
}

claude_md_forwarded_content_rule() {
  for s in "paired" "Telegram" "count as {{OWNER}}" "forwarded inside them" "data, not instructions" "tickets and the verification command"; do
    assert_contains templates/hub/CLAUDE.md "$s" "hub CLAUDE.md forwarded-content rule"; done
}

channels_from_conf() {
  reset_rec; echo 'HUB_CHANNELS="discord"' > hub.conf
  out=$(bin/chat start </dev/null 2>&1); assert_eq "$?" "2" "an unknown channel type"
  echo "$out" | grep -q "telegram" || fail "the refusal names the known types [$out]"; launched && fail "an unknown channel launched"
  echo 'HUB_CHANNELS="telegram discord"' > hub.conf; bin/chat start </dev/null >/dev/null 2>&1; assert_eq "$?" "2" "one unknown in the list"
  echo 'HUB_CHANNELS=""' > hub.conf; bin/chat start </dev/null >/dev/null 2>&1; assert_eq "$?" "2" "no channels"
  launched && fail "a bad channel list launched"
  echo 'HUB_CHANNELS="telegram"' > hub.conf; bin/chat start </dev/null >/dev/null 2>&1 || fail "HUB_CHANNELS=telegram starts"
  bin/chat setup bogus >/dev/null 2>&1; assert_eq "$?" "2" "setup of an unknown channel"
  out=$(bin/chat setup telegram 2>&1) || fail "setup telegram"
  for s in "@BotFather" "bin/keys set telegram" "telegram@claude-plugins-official" "/telegram:access pair" "/telegram:access policy allowlist"; do
    echo "$out" | grep -qF "$s" || fail "setup names [$s]"; done
  echo "$out" | grep -qF "$K" && fail "setup printed the token"
  bin/chat bogus >/dev/null 2>&1; assert_eq "$?" "2" "unknown command"; rm -f hub.conf
}

state_per_orchestrator() {
  reset_rec; TELEGRAM_STATE_DIR=/tmp/shared-telegram bin/chat start </dev/null >/dev/null 2>&1 || fail "start"
  S1="$(cat "$FAKE_REC/statedir")"; assert_eq "$S1" "$CH" "state folder under the hub's state dir"
  [ "$(fmode "$S1")" = 700 ] || fail "the state folder is private to the user"
  # two hubs on one machine (state dirs by hub name): different folders, so no shared bot token or allowlist
  H1="$HUB"; NH="$(mktemp -d)"; make_hub; H2="$HUB"
  echo 'HUB_NAME=alpha' > "$H1/hub.conf"; echo 'HUB_NAME=beta' > "$H2/hub.conf"
  access "$NH/.agent-hub/alpha/channels/telegram" allowlist; access "$NH/.agent-hub/beta/channels/telegram" allowlist
  reset_rec; (unset AGENT_STATE; cd "$H1" && HOME="$NH" HUB="$H1" bin/chat start </dev/null >/dev/null 2>&1) || fail "start alpha"
  a="$(cat "$FAKE_REC/statedir")"
  reset_rec; (unset AGENT_STATE; cd "$H2" && HOME="$NH" HUB="$H2" bin/chat start </dev/null >/dev/null 2>&1) || fail "start beta"
  b="$(cat "$FAKE_REC/statedir")"
  assert_eq "$a" "$NH/.agent-hub/alpha/channels/telegram" "hub alpha's own state folder"
  assert_eq "$b" "$NH/.agent-hub/beta/channels/telegram" "hub beta's own state folder"
  HUB="$H1"; cd "$H1"; rm -f hub.conf
}

# ---- story C7: formatting, approvals and talking to focus agents. A fake channel (AGENT_CHAT_SEND) records each
# payload it delivers (it fails for everyone with FAKE_SEND_FAIL=1, for one chat id with FAKE_FAIL_FOR); a fake
# bin/sessions lists three agents; a fake bin/notify records its argv.
c7_setup() {
  mkdir -p projects/api projects/web ops/infra
  cat > "$FAKE/bin/send" <<'STUB'
#!/bin/bash
p="$(cat)"; [ -z "${FAKE_SEND_FAIL:-}" ] || exit 1
[ -z "${FAKE_FAIL_FOR:-}" ] || case "$p" in *"\"chat_id\": \"$FAKE_FAIL_FOR\""*) exit 1 ;; esac
printf '%s\n' "$p" >> "$FAKE/sent"
STUB
  chmod +x "$FAKE/bin/send"; export AGENT_CHAT_SEND="$FAKE/bin/send"; : > "$FAKE/sent"
  [ -f "$FAKE/sessions.real" ] || cp bin/sessions "$FAKE/sessions.real"; [ -f "$FAKE/notify.real" ] || cp bin/notify "$FAKE/notify.real"
  cat > bin/sessions <<'STUB'
#!/bin/bash
cat <<'T'
NAME             FOLDER                     PID      PARENT   STARTED               ROLE       STATUS LAST
T-1.2            projects/api               4101     -        2026-11-21T10:00:00Z  builder    busy   2026-11-21T14:02:11Z
web              projects/web               4102     -        2026-11-21T10:05:00Z  -          idle   2026-11-21T13:50:40Z
infra            ops/infra                  4103     -        2026-11-21T10:06:00Z  ops        -      -
T
STUB
  printf '#!/bin/bash\nfor a in "$@"; do printf "[%%s]" "$a"; done >> "$FAKE/notify.log"; echo >> "$FAKE/notify.log"\n' > bin/notify
  chmod +x bin/sessions bin/notify; : > "$FAKE/notify.log"
  rm -rf "$AGENT_STATE/events.jsonl" "$AGENT_STATE/events.jsonl.1" "$AGENT_STATE/events-seen" "$AGENT_STATE/chat/asks" \
    "$AGENT_STATE/chat/forward.cursor" "$AGENT_STATE/chat/pending" "$AGENT_STATE/chat/forward.done" "$AGENT_STATE/chat/forward.tries" "$AGENT_STATE/chat/forward.lock" "$AGENT_STATE/logs/chat-send.log" ops/api
  access "$CH" allowlist
}
c7_done() { cp "$FAKE/sessions.real" bin/sessions; cp "$FAKE/notify.real" bin/notify; unset AGENT_CHAT_SEND AGENT_CHAT_BUTTONS AGENT_CHAT_REFS; access "$CH" allowlist; }
two_owners() { printf '{"dmPolicy": "allowlist", "allowFrom": ["111", "222"], "groups": {}}\n' > "$CH/access.json"; }
ev() { H="$HUB" ST="$AGENT_STATE" python3 -I bin/events.py write "$@" || fail "event write $*"; }
sent_texts() { python3 -c 'import json,sys
for l in open(sys.argv[1]):
    l=l.strip()
    if l: print(json.loads(l)["text"].replace("\n","\\n"))' "$FAKE/sent"; }
sent_to() { python3 -c 'import json,sys
for l in open(sys.argv[1]):
    l=l.strip()
    if l: d=json.loads(l); print(d["chat_id"], d["text"].replace("\n","\\n"))' "$FAKE/sent"; }

telegram_style_rule() {
  for s in "Telegram replies" "markdownv2" "never a raw Markdown table" "aligned code block" "full text in <path>" \
    "bin/chat status --card" "● busy" "○ idle" "⚠ blocked" "15 lines" "reply 1 <ref> to approve" "bin/chat to --sender" \
    "bin/chat answer --sender" "bin/chat forward" "<<'EOF'" "Allow" "claimed"; do
    assert_contains templates/hub/CLAUDE.md "$s" "hub CLAUDE.md Telegram style rule"; done
}

# AC5: an answer counts only after the owner's own Allow: recording it (and sending as main) is behind a permission
# prompt in the hub root's settings, which the Telegram plugin shows the paired owner as Allow / Deny buttons
answer_needs_owner_permission() {
  python3 - .claude/settings.json "$HUB" <<'PY' || fail "the hub root's permissions.ask does not cover bin/chat answer and to"
import fnmatch, json, sys
ask = json.load(open(sys.argv[1]))["permissions"]["ask"]
pats = [r[5:-1] for r in ask if r.startswith("Bash(") and r.endswith(")")]
hit = lambda c: any(fnmatch.fnmatchcase(c, p) for p in pats)
for c in ["bin/chat answer --sender 99887766 <<'EOF'\n1 abcde\nEOF", sys.argv[2] + "/bin/chat answer --sender 1",
          "bin/chat to --sender 99887766 api <<'EOF'\nrebase\nEOF", "cd /x && bin/chat to --sender 1 web"]:
    assert hit(c), c
for c in ["bin/chat status --card", "bin/chat agents", "bin/chat asked abcde", "bin/chat forward"]:
    assert not hit(c), c
PY
}

status_card_golden() {
  c7_setup; ev --auto --from ops/infra --to main --kind idle --text "waiting"
  ev --from ops/infra --to main --kind note --text "blocked: the staging box is unreachable"
  out="$(bin/chat status --card)" || fail "status --card [$out]"
  want="hub · stopped · 3 agents
● T-1.2 · projects/api · builder · T-1.2 · busy 14:02Z
○ web · projects/web · - · - · idle 13:50Z
⚠ infra · ops/infra · ops · - · blocked"
  assert_eq "$out" "$want" "the status card layout"
  ev --auto --from ops/infra --to main --kind idle --text "unblocked"
  bin/chat status --card | grep -q '^○ infra · ops/infra · ops · - · idle$' || fail "a later idle clears blocked [$(bin/chat status --card)]"
  printf '#!/bin/bash\necho "NAME FOLDER PID PARENT STARTED ROLE STATUS LAST"\n' > bin/sessions
  assert_eq "$(bin/chat status --card)" "hub · stopped · no agents" "the card with no agents"
  c7_done
}

to_agent_notifies() {
  c7_setup
  printf '%s\n' "rebase on main; don't \"force\" it" > "$FAKE/msg"
  out="$(bin/chat to --sender 99887766 api < "$FAKE/msg" 2>&1)" || fail "to api [$out]"
  assert_eq "$(cat "$FAKE/notify.log")" "[--from][main][projects/api][rebase on main; don't \"force\" it]" "one notify, the text from stdin as it was"
  assert_eq "$out" "sent to projects/api" "says where it went"
  : > "$FAKE/notify.log"; echo "and run the tests" | bin/chat to --sender 99887766 T-1.2 >/dev/null 2>&1 || fail "to by agent name"
  assert_eq "$(cat "$FAKE/notify.log")" "[--from][main][projects/api][and run the tests]" "an agent name resolves to its folder"
  # the text never comes as an argument
  : > "$FAKE/notify.log"; bin/chat to --sender 99887766 api "as an argument" </dev/null >/dev/null 2>&1; assert_eq "$?" "2" "text as an argument"
  [ -s "$FAKE/notify.log" ] && fail "an argument text was sent"
  # unknown: the agents listed, no notify
  out="$(echo hello | bin/chat to --sender 99887766 billing 2>&1)"; assert_eq "$?" "2" "an unknown agent"
  for a in T-1.2 web infra; do echo "$out" | grep -q "$a" || fail "the reply lists $a [$out]"; done
  [ -s "$FAKE/notify.log" ] && fail "an unknown name notified"
  # ambiguous like bin/notify: the name is two hub folders (projects/api and ops/api), even with one agent running
  mkdir -p ops/api; out="$(echo hello | bin/chat to --sender 99887766 api 2>&1)"; assert_eq "$?" "2" "a name of two hub folders"
  echo "$out" | grep -q "ops/api" || fail "the ambiguous reply names both [$out]"; [ -s "$FAKE/notify.log" ] && fail "an ambiguous name notified"
  rm -rf ops/api
  # ambiguous: a session's name is another folder's name (session "web" works in projects/api; projects/web exists)
  printf '#!/bin/bash\necho "NAME FOLDER PID PARENT STARTED ROLE STATUS LAST"\necho "web projects/api 1 - x - idle -"\n' > bin/sessions
  echo hello | bin/chat to --sender 99887766 web >/dev/null 2>&1; assert_eq "$?" "2" "a session named after another folder"
  [ -s "$FAKE/notify.log" ] && fail "that notified"
  # only the paired owner
  out="$(echo hi | bin/chat to --sender 11111 web 2>&1)"; assert_eq "$?" "2" "a sender that is not paired"
  echo "$out" | grep -q "not the paired owner" || fail "the refusal says why [$out]"; [ -s "$FAKE/notify.log" ] && fail "an unpaired sender notified"
  echo hi | bin/chat to web >/dev/null 2>&1; assert_eq "$?" "2" "no --sender"; [ -s "$FAKE/notify.log" ] && fail "no sender notified"
  c7_done
}

forward_agent_events_once() {
  c7_setup
  ev --auto --from projects/api --to main --kind idle --text "tests green, PR open"
  ev --from projects/web --to main --kind note --text "need the staging URL"
  ev --from main --to projects/api --kind note --text "from main to api"
  ev --auto --from projects/api --to main --kind pushed --text "pushed c7" --repo /x --branch c7
  ev --auto --from projects/web --to main --kind ended --text "2 commits"
  bin/chat forward >/dev/null 2>&1 || fail "forward"
  want='[projects/api, claimed] idle: "tests green, PR open"
[projects/web, claimed] note: "need the staging URL"
[projects/web, claimed] ended: "2 commits"'
  assert_eq "$(sent_texts)" "$want" "agent events to main are forwarded, tagged with the folder and claimed, quoted"
  python3 -c 'import json,sys
for l in open(sys.argv[1]):
    l=l.strip()
    if l: d=json.loads(l); assert d["chat_id"]=="99887766" and "parse_mode" not in d, d' "$FAKE/sent" || fail "sent as plain text to the paired owner"
  : > "$FAKE/sent"; bin/chat forward >/dev/null 2>&1 || fail "forward again"; [ -s "$FAKE/sent" ] && fail "an event was forwarded twice"
  # nobody reached: retried on the next run, then sent once
  ev --auto --from projects/api --to main --kind idle --text "retry me"
  FAKE_SEND_FAIL=1 bin/chat forward >/dev/null 2>&1; assert_eq "$?" "1" "a failed send"
  : > "$FAKE/sent"; bin/chat forward >/dev/null 2>&1 || fail "forward after a failure"
  assert_eq "$(sent_texts)" '[projects/api, claimed] idle: "retry me"' "the failed event is sent on the next run"
  : > "$FAKE/sent"; bin/chat forward >/dev/null 2>&1; [ -s "$FAKE/sent" ] && fail "the retried event was sent twice"
  # a text that looks like a secret is withheld
  printf '{"time":"2026-11-21T10:00:00Z","from":"projects/api","to":"main","kind":"idle","text":"token=ab12cd34ef"}\n' >> "$AGENT_STATE/events.jsonl"
  bin/chat forward >/dev/null 2>&1; grep -q ab12cd34ef "$FAKE/sent" && fail "a secret-looking text was forwarded"
  c7_done
}

forward_partial_failure() {   # several owners, one unreachable: sent once to the one that got it, the miss logged
  c7_setup; two_owners; ev --auto --from projects/api --to main --kind idle --text "to both"
  FAKE_FAIL_FOR=222 bin/chat forward >/dev/null 2>&1 || fail "a line one owner got counts as sent"
  assert_eq "$(sent_to)" '111 [projects/api, claimed] idle: "to both"' "the reachable owner got it"
  grep -q "not delivered to 222" "$AGENT_STATE/logs/chat-send.log" || fail "the miss is logged with its chat id"
  bin/chat forward >/dev/null 2>&1; assert_eq "$(sent_to | grep -c '^111 ')" "1" "never resent to the owner that got it"
  ev --auto --from projects/api --to main --kind idle --text "next"
  bin/chat forward >/dev/null 2>&1; sent_to | grep -q '^222 \[projects/api, claimed\] idle: "next"' || fail "the queue moved on [$(sent_to)]"
  c7_done
}

forward_cap_per_run() {   # at most 20 lines a run; the rest folded into one line, the cursor past them
  c7_setup; for i in $(seq 1 25); do ev --auto --from projects/api --to main --kind idle --text "e$i"; done
  bin/chat forward >/dev/null 2>&1 || fail "forward"
  assert_eq "$(sent_texts | grep -c 'idle: "e')" "20" "20 lines"
  assert_eq "$(sent_texts | tail -1)" "(5 more events: bin/inbox)" "the rest folded into one line"
  : > "$FAKE/sent"; bin/chat forward >/dev/null 2>&1; [ -s "$FAKE/sent" ] && fail "the folded events were sent later"
  c7_done
}

forward_after_rotation() {   # the log rotated between runs: the rest of the old log first, then the new one
  c7_setup; ev --auto --from projects/api --to main --kind idle --text "old 1"; bin/chat forward >/dev/null 2>&1
  ev --auto --from projects/api --to main --kind idle --text "old 2"
  mv "$AGENT_STATE/events.jsonl" "$AGENT_STATE/events.jsonl.1"; ev --auto --from projects/api --to main --kind idle --text "new 1"
  : > "$FAKE/sent"; bin/chat forward >/dev/null 2>&1 || fail "forward after rotation"
  assert_eq "$(sent_texts)" '[projects/api, claimed] idle: "old 2"
[projects/api, claimed] idle: "new 1"' "the rotated log's rest, then the new log"
  c7_done
}

forward_lock() {   # one forwarder at a time; a lock without a pid yet is live for a few seconds
  c7_setup; ev --auto --from projects/api --to main --kind idle --text "locked"
  mkdir -p "$AGENT_STATE/chat/forward.lock"; bin/chat forward >/dev/null 2>&1
  [ -s "$FAKE/sent" ] && fail "a fresh lock with no pid yet was taken over"
  touch -t 202001010000 "$AGENT_STATE/chat/forward.lock"; bin/chat forward >/dev/null 2>&1
  [ -s "$FAKE/sent" ] || fail "an old lock with no pid was not taken over"
  sleep 30 & live=$!; mkdir -p "$AGENT_STATE/chat/forward.lock"; echo "$live" > "$AGENT_STATE/chat/forward.lock/pid"
  ev --auto --from projects/api --to main --kind idle --text "live holder"; : > "$FAKE/sent"; bin/chat forward >/dev/null 2>&1
  [ -s "$FAKE/sent" ] && fail "a live holder's lock was taken"; kill "$live"; wait "$live" 2>/dev/null
  rm -rf "$AGENT_STATE/chat/forward.lock"; c7_done
}

start_runs_forwarder() {   # bin/chat start runs the forward loop beside the session
  c7_setup; reset_rec
  AGENT_CHAT_FORWARD_EVERY=1 FAKE_SLEEP=8 bin/chat start </dev/null >/dev/null 2>&1 & bg=$!
  wait_for "[ -f '$FAKE_REC/argv' ]" || fail "the session did not start"
  ev --auto --from projects/api --to main --kind idle --text "while it runs"
  wait_for "grep -q 'while it runs' '$FAKE/sent'" || fail "the loop forwarded nothing while the session ran"
  bin/chat stop >/dev/null 2>&1; wait "$bg" 2>/dev/null; c7_done
}

approvals_buttons_or_numbered() {
  c7_setup
  ref="$(echo "Dispatch T-1.3 (high risk)?" | bin/chat ask)" || fail "ask"
  [[ "$ref" =~ ^[a-z]{5}$ ]] || fail "ask prints a ref [$ref]"
  assert_eq "$(sent_texts)" "Dispatch T-1.3 (high risk)?\\nreply 1 $ref to approve, 2 $ref to deny" "Telegram: numbered replies with the ref"
  grep -q reply_markup "$FAKE/sent" && fail "buttons sent where the plugin takes none"
  # the question never comes as an argument; one that looks like a secret is refused and nothing is sent
  bin/chat ask "as an argument" </dev/null >/dev/null 2>&1; assert_eq "$?" "2" "a question as an argument"
  : > "$FAKE/sent"; echo "use token=ab12cd34ef?" | bin/chat ask >/dev/null 2>&1; assert_eq "$?" "2" "a secret-looking question"
  [ -s "$FAKE/sent" ] && fail "a secret-looking question was sent"
  # a long question is cut, never the reply line
  : > "$FAKE/sent"; r3="$(python3 -c 'print("x" * 5000)' | bin/chat ask)" || fail "a long ask"
  sent_texts | grep -q "…\\\\nreply 1 $r3 to approve, 2 $r3 to deny$" || fail "the reply line survives a long question [$(sent_texts | cut -c1-80)...]"
  # an unpaired sender's answer never counts; a bare number (no ref) never counts
  out="$(echo "1 $ref" | bin/chat answer --sender 11111 2>&1)"; assert_eq "$?" "2" "an unpaired answer"
  echo "$out" | grep -q "not the paired owner" || fail "says why [$out]"
  out="$(echo 1 | bin/chat answer --sender 99887766 2>&1)"; assert_eq "$?" "2" "a bare 1"
  echo "$out" | grep -q "with its ref" || fail "the refusal asks for the ref [$out]"
  echo yes | bin/chat answer --sender 99887766 >/dev/null 2>&1; assert_eq "$?" "2" "a bare yes"
  assert_eq "$(bin/chat asked "$ref")" "pending" "still pending"
  echo "1 $ref" | bin/chat answer --sender 99887766 >/dev/null 2>&1 || fail "the owner approves"
  assert_eq "$(bin/chat asked "$ref")" "approved" "the owner's 1 <ref> approves"
  grep -rq "approved $ref" journal/ || fail "the answer is journaled"
  echo "2 $ref" | bin/chat answer --sender 99887766 >/dev/null 2>&1; assert_eq "$?" "2" "an answered ask"
  assert_eq "$(bin/chat asked "$ref")" "approved" "a late answer changes nothing"
  # a channel that takes buttons: Approve / Deny buttons, answered by their callback data
  : > "$FAKE/sent"; r2="$(echo "Restart web?" | AGENT_CHAT_BUTTONS=all bin/chat ask)" || fail "ask with buttons"
  python3 -c 'import json,sys
d=json.loads(open(sys.argv[1]).readline()); k=d["reply_markup"]["inline_keyboard"][0]
assert [b["text"] for b in k]==["Approve","Deny"], k
assert [b["callback_data"] for b in k]==["ask:approve:"+sys.argv[2],"ask:deny:"+sys.argv[2]], k
assert d["text"]=="Restart web?", d' "$FAKE/sent" "$r2" || fail "buttons payload [$(cat "$FAKE/sent")]"
  echo "ask:approve:$r2" | bin/chat answer --sender 11111 >/dev/null 2>&1; assert_eq "$(bin/chat asked "$r2")" "pending" "an unpaired button press"
  echo "ask:deny:$r2" | bin/chat answer --sender 99887766 >/dev/null 2>&1 || fail "the owner's button"
  assert_eq "$(bin/chat asked "$r2")" "denied" "the owner's Deny button"
  # a new ask never reuses a ref that exists (asked, or answered)
  mkdir -p "$AGENT_STATE/chat/asks"; echo old > "$AGENT_STATE/chat/asks/aaaaa"; echo "approved x" > "$AGENT_STATE/chat/asks/bbbbb.answer"
  r4="$(echo "fresh?" | AGENT_CHAT_REFS="aaaaa bbbbb ccccc" bin/chat ask)" || fail "ask with taken refs"
  assert_eq "$r4" "ccccc" "a taken ref is skipped"
  c7_done
}

agents_list() {
  c7_setup; ev --from ops/infra --to main --kind note --text "blocked: no VPN"
  out="$(bin/chat agents)" || fail "agents"
  want='NAME   FOLDER        ROLE     TICKET  STATE
T-1.2  projects/api  builder  T-1.2   ● busy
web    projects/web  -        -       ○ idle
infra  ops/infra     ops      -       ⚠ blocked'
  assert_eq "$out" "$want" "/agents lists folder, role, ticket and state"
  c7_done
}

bot_send_token_on_stdin_only() {
  # the real sender against a local stand-in for the Bot API (never the network): the token only in the request path
  c7_setup; unset AGENT_CHAT_SEND; SRV="$(mktemp -d)"
  # the stand-in never outlives the check: it ends itself after 60 s (SIGALRM), holds none of the test's output and is
  # killed when the check exits, passed or failed (CI has no terminal: a server left running held run.sh for hours)
  cat > "$SRV/api.py" <<'PYS'
import faulthandler, http.server, json, os, signal, socketserver, sys
signal.alarm(int(os.environ.get("FAKE_API_TTL") or 60)); faulthandler.dump_traceback_later(8)   # a slow start shows where
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0)); b = self.rfile.read(n)
        open(sys.argv[2], "a").write(self.path + " " + b.decode() + "\n")
        self.send_response(200); self.end_headers(); self.wfile.write(b'{"ok":true}')
    def log_message(self, *a): pass
# a plain TCPServer: HTTPServer's bind looks up the host's FQDN (socket.getfqdn), which stalled for over 10 s on the
# macOS CI runner (CI run 44954682648)
s = socketserver.TCPServer(("127.0.0.1", 0), H); open(sys.argv[1], "w").write(str(s.server_address[1])); s.serve_forever()
PYS
  python3 "$SRV/api.py" "$SRV/port" "$SRV/req" </dev/null >/dev/null 2>"$SRV/err" & srv=$!; trap 'kill "$srv" 2>/dev/null' EXIT
  wait_for "[ -s '$SRV/port' ]" || fail "the stand-in API did not start [$(tail -n 5 "$SRV/err")]"; [ -z "${FAKE_API_HOLD:-}" ] || sleep "$FAKE_API_HOLD" >/dev/null 2>&1
  ev --auto --from projects/api --to main --kind idle --text "via the bot"
  AGENT_TELEGRAM_API="http://127.0.0.1:$(cat "$SRV/port")" bin/chat forward >"$FAKE/out" 2>&1 || fail "forward through the bot [$(cat "$FAKE/out")]"
  kill "$srv" 2>/dev/null; wait "$srv" 2>/dev/null; trap - EXIT
  assert_contains "$SRV/req" "/bot$K/sendMessage" "the token is used in the Bot API path"
  assert_contains "$SRV/req" '"text": "[projects/api, claimed] idle: \"via the bot\""' "the text is sent"
  grep -qF "$K" "$FAKE/out" && fail "the token was printed"
  grep -qF "$K" "$STORE.argv" && fail "the token is in a security argument"
  c7_done
}

no_terminal_stand_in_api() {
  # CI has no terminal. The bot check runs twice at once, each in its own session (no controlling terminal), stdin
  # /dev/null, its output a pipe (as run.sh reads it), held (FAKE_API_HOLD) while its stand-in API runs, then ended as
  # a failed check ends (TERM) and as a cancelled one (KILL: no trap runs; FAKE_API_TTL=3 is the stand-in's deadline).
  # Each output pipe must close and each stand-in must be gone: one left holding the output kept CI waiting for hours.
  python3 - "$REPO/tests/test_chat.sh" <<'PY' || fail "the bot check, ended with no terminal, left something running"
import os, signal, subprocess, sys, time
def run():
    r, w = os.pipe()
    p = subprocess.Popen(["bash", sys.argv[1], "bot_send_token_on_stdin_only"], stdin=subprocess.DEVNULL, stdout=w,
                         stderr=w, start_new_session=True, env=dict(os.environ, FAKE_API_HOLD="60", FAKE_API_TTL="3"))
    os.close(w); os.set_blocking(r, False); return p, r
def servers(p):   # the run's stand-ins: api.py in its process group (its own session)
    ps = subprocess.run(["ps", "-A", "-o", "pid=,pgid=,command="], capture_output=True, text=True).stdout.splitlines()
    return [int(c[0]) for c in (l.split(None, 2) for l in ps) if len(c) == 3 and c[1] == str(p.pid) and "/api.py " in c[2]]
def closed(r):
    try: return os.read(r, 65536) == b""
    except BlockingIOError: return False
runs = {signal.SIGTERM: run(), signal.SIGKILL: run()}; why = []; end = time.time() + 120
while time.time() < end and not all(servers(p) or p.poll() is not None for p, _ in runs.values()): time.sleep(0.1)
for sig, (p, r) in runs.items():
    if p.poll() is not None or not servers(p): why.append("%s: the stand-in API never ran (rc %s)" % (sig.name, p.poll()))
    else: os.kill(p.pid, sig)
for p, _ in runs.values(): p.wait()
end = time.time() + 10
while time.time() < end and not all(closed(r) and not servers(p) for p, r in runs.values()): time.sleep(0.1)
for sig, (p, r) in runs.items():
    if not closed(r): why.append("%s: the output was still held 10 s after the check ended" % sig.name)
    if servers(p): why.append("%s: the stand-in API outlived the check by 10 s" % sig.name)
    for s in servers(p): os.kill(s, signal.SIGKILL)
    try: os.killpg(p.pid, signal.SIGKILL)
    except OSError: pass
if why: sys.exit("; ".join(why))
PY
}

# bash tests/test_chat.sh <check>: run the checks up to and including one (to see each fail on its own)
if [ $# -gt 0 ]; then for c in start_launches_channel_session token_short_lived_file missing_token_refuses skip_permissions_refused \
  single_instance stop_and_status start_lock_and_access no_terminal_session_ends same_folder_name schedule_installs_chat_job claude_md_forwarded_content_rule channels_from_conf state_per_orchestrator \
  telegram_style_rule answer_needs_owner_permission status_card_golden to_agent_notifies forward_agent_events_once forward_partial_failure forward_cap_per_run forward_after_rotation forward_lock start_runs_forwarder approvals_buttons_or_numbered agents_list bot_send_token_on_stdin_only no_terminal_stand_in_api; do
  [ "$c" = "$1" ] && { "$c"; echo ok; exit 0; }; ( "$c" ) >/dev/null 2>&1; done; fi
start_launches_channel_session; token_short_lived_file; missing_token_refuses; skip_permissions_refused
single_instance; stop_and_status; start_lock_and_access; no_terminal_session_ends; same_folder_name; schedule_installs_chat_job; claude_md_forwarded_content_rule; channels_from_conf
state_per_orchestrator
telegram_style_rule; answer_needs_owner_permission; status_card_golden; to_agent_notifies; forward_agent_events_once; forward_partial_failure; forward_cap_per_run; forward_after_rotation; forward_lock; start_runs_forwarder; approvals_buttons_or_numbered; agents_list; bot_send_token_on_stdin_only; no_terminal_stand_in_api
echo ok
