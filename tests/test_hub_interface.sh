#!/bin/bash
# The hub commands ade-cli calls (story H1, .ade/context/hub-interface.md): bin/agent --live-test, the anthropic key
# path, bin/chat logs and test, bin/inbox --count, bin/dispatch --list.
# bash tests/test_hub_interface.sh [check ...] runs only the named checks (all of them by default).
# Hermetic: a fake claude, curl and node first on PATH, a stub bin/secret in the hub copy; no network, no real key.
. "$(dirname "$0")/helpers.sh"
make_hub; cd "$HUB"
unset CLAUDE_CONFIG_DIR HUB_CLAUDE_CONFIG_DIR AGENT_CLAUDE AGENT_FOLDER AGENT_TIMEOUT TELEGRAM_BOT_TOKEN HUB_CHANNELS HUB_ORCHESTRATOR
S="$(mktemp -d)"; S="$(cd "$S" && pwd -P)"; mkdir -p "$S/tmp" "$S/home" "$S/bin" "$S/val"; export HI="$S" TMPDIR="$S/tmp" HOME="$S/home"
ST="$S/state"; mkdir -p "$ST"; export AGENT_STATE="$ST"
BG=""
trap '[ -z "$BG" ] || kill "$BG" 2>/dev/null; rm -rf "$S" "$(dirname "$HUB")" "$CLAUDE_HOME" "$(dirname "$AGENT_SYNC_LOG")" "$(dirname "$AGENT_SYNC_LOCK")" "$(dirname "$METHOD_FIXTURE")"' EXIT
bin/new projects/demo >/dev/null; bin/new projects/other >/dev/null
C="$S/cap"; KEY="sk-LIVETEST-$RANDOM$RANDOM-c0ffee0123"; TOK="123456789:AAH-TEST-telegram-token-VALUE-abcdefghi"
# the fake engine sees only what bin/agent lets through; it prints $S/reply (default READY) and exits $S/rc (default 0)
cat > "$S/bin/claude" <<STUB
#!/bin/bash
C="$C"; mkdir -p "\$C"; echo run >> "\$C/runs"; printf '%s\n' "\$@" > "\$C/argv"; env > "\$C/env"; pwd -P > "\$C/cwd"; cat > "\$C/stdin"
p=""; for a in "\$@"; do [ "\$p" = --settings ] && cp "\$a" "\$C/settings.json"; p="\$a"; done
echo \$\$ > "\$C/pid"; [ -f "$S/hang" ] && while :; do sleep 1; done
if [ -f "$S/reply" ]; then cat "$S/reply"; else echo READY; fi
exit "\$(cat "$S/rc" 2>/dev/null || echo 0)"
STUB
# stub bin/secret: a name is stored when $S/val/<name> exists, and that file holds its value
cat > bin/secret <<'STUB'
#!/bin/bash
echo "secret $*" >> "$HI/secret.calls"
case "$1" in --has) [ -f "$HI/val/$2" ]; exit;; --set) [ -n "${2:-}" ] || exit 2; IFS= read -r v; [ -n "$v" ] || exit 1; printf '%s' "$v" > "$HI/val/$2"; exit 0;; --forget) rm -f "$HI/val/$2"; exit;; esac
[ -f "$HI/val/$1" ] || exit 1; cat "$HI/val/$1"
STUB
# fake curl: the config comes on stdin (-K -); it answers like the Telegram Bot API. $HI/queue holds the bot's pending
# updates (one JSON object per line): getUpdates without an offset returns them all and confirms none; with offset=N
# it drops (confirms) the ones below N. A send moves $HI/pending (the owner's reply) into the queue. $HI/peekfail
# fails a getUpdates without an offset. It records its argv, whether SSLKEYLOGFILE is set and whether the chat lock is held.
cat > "$S/bin/curl" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$HI/curl.argv"; [ -z "${SSLKEYLOGFILE+x}" ] || echo set >> "$HI/curl.keylog"
cfg="$(cat)"; printf '%s\n' "$cfg" >> "$HI/curl.cfg"
url="$(printf '%s\n' "$cfg" | sed -n 's/^url = "\(.*\)"$/\1/p')"; off="$(printf '%s\n' "$cfg" | sed -n 's/^data = "offset=\(.*\)"$/\1/p')"
case "${url##*/}" in
  sendMessage) printf '%s\n' "$cfg" > "$HI/sent"; [ -d "$AGENT_STATE/chat/lock" ] && echo yes > "$HI/lock_at_send"
    [ ! -f "$HI/pending" ] || { cat "$HI/pending" >> "$HI/queue"; rm -f "$HI/pending"; }
    cat "$HI/send.json" 2>/dev/null || echo '{"ok":true,"result":{"message_id":5}}' ;;
  getUpdates)
    if [ -z "$off" ] && [ -f "$HI/peekfail" ]; then echo '{"ok":false,"description":"Conflict"}'; exit 0; fi
    touch "$HI/queue"; python3 -c 'import json,sys
q=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]; off=sys.argv[2]
if off: q=[u for u in q if u["update_id"]>=int(off)]; open(sys.argv[1],"w").write("".join(json.dumps(u)+"\n" for u in q))
print(json.dumps({"ok":True,"result":q}))' "$HI/queue" "$off" > "$HI/answer"
    grep -q '"result": \[\]' "$HI/answer" && sleep 0.3; cat "$HI/answer" ;;
  *) echo '{"ok":false,"description":"unknown method"}' ;;
esac
STUB
printf '#!/bin/bash\n[ "$1" != print ] || [ -f "$HI/loaded" ]\n' > "$S/bin/launchctl"; chmod +x "$S/bin/launchctl"
# fake node: `tickets next` prints $S/tickets.json (fails when $S/nodefail exists)
cat > "$S/bin/node" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$HI/node.argv"; [ -e "$HI/nodefail" ] && { echo "tickets: error"; exit 2; }; cat "$HI/tickets.json"
STUB
chmod +x "$S/bin/claude" "$S/bin/curl" "$S/bin/node" bin/secret; export PATH="$S/bin:$PATH"
# the demo folder has one BMAD checkout; projects/other has none
CK="$S/demo-code"; mkdir -p "$CK/_bmad" && : > "$CK/_bmad/ade-runtime.mjs"
printf '| demo-code | %s | main | Owner | none |\n' "$CK" >> projects/demo/ACCESS.md
printf '#!/bin/bash\necho "$*" >> "$HI/work.log"\n' > bin/work
printf '#!/bin/bash\necho "NAME FOLDER PID PARENT STARTED ROLE STATUS LAST"\ncat "$HI/sessions" 2>/dev/null; exit 0\n' > bin/sessions
chmod +x bin/work bin/sessions

conf() { printf '%s\n' "$@" > hub.conf; }
reset() { rm -rf "$C" "$S/reply" "$S/rc" "$S/val" "$S/secret.calls" "$S/curl.argv" "$S/curl.cfg" "$S/sent" "$S/send.json" "$S/queue" "$S/pending" \
  "$S/peekfail" "$S/loaded" "$S/lock_at_send" "$S/curl.keylog" "$S/hang" "$S/live" "$S/out" "$S/err" "$ST"; mkdir -p "$S/val" "$ST"; rm -f hub.conf; }
live() { printf '%s\n' "${TASK:-Reply with the word READY and nothing else.}" | bin/agent --live-test "$@" > "$S/out" 2> "$S/err"; rc=$?; }
ran() { [ -e "$C/runs" ]; }
last_line() { cat "$S/out" "$S/err" | grep -v '^[[:space:]]*$' | tail -1; }
no_value_in() { local f v; for v in "$KEY" "$TOK"; do for f in "$@"; do [ ! -e "$f" ] || ! grep -qF -- "$v" "$f" || fail "a secret value is in $f"; done; done; }

live_test_ready_on_a_ready_line() {
  mkdir -p "$S/live"
  ANTHROPIC_API_KEY="$KEY" ANTHROPIC_AUTH_TOKEN="$KEY" ANTHROPIC_BASE_URL=https://other.example CLAUDE_CODE_OAUTH_TOKEN="$KEY" \
    DEEPSEEK_API_KEY="$KEY" GEMINI_API_KEY="$KEY" CLAUDE_CODE_USE_BEDROCK=1 live anthropic --dir "$S/live"
  assert_eq "$rc" 0 "ready exit: $(cat "$S/err")"; grep -qx READY "$S/out" || fail "the READY line is printed [$(cat "$S/out")]"
  assert_eq "$(cat "$C/cwd")" "$S/live" "runs from the throwaway folder"
  assert_eq "$(cat "$C/stdin")" "Reply with the word READY and nothing else." "only the fixed task reaches the engine"
  grep -qE '^(ANTHROPIC_|DEEPSEEK_|GEMINI_|CLAUDE_CODE_OAUTH|CLAUDE_CODE_USE_)' "$C/env" && fail "a key or backend variable reached the engine: $(grep -E '^(ANTHROPIC|DEEPSEEK|GEMINI|CLAUDE_CODE)' "$C/env")"
  assert_eq "$(awk 'p{print; exit} $0=="--model"{p=1}' "$C/argv")" haiku "the tiny default model"
  grep -qx -- --safe-mode "$C/argv" || fail "the isolation flags of a real run"
  assert_eq "$(awk 'p{print "[" $0 "]"; exit} $0=="--tools"{p=1}' "$C/argv")" "[]" "no tools in a live test"; grep -q Read "$C/argv" && fail "a tool reached the live test"
  grep -q 'role=live-test folder=- provider=anthropic model=haiku exit=0' journal/delegations-*.md || fail "journaled like a run"
  [ -d "$S/live" ] || fail "a caller's --dir is the caller's to remove"
  # the whole output, trimmed, must be READY: spaces and a CR around it count; anything else, or bad UTF-8, does not
  printf '  READY \r\n' > "$S/reply"; live anthropic; assert_eq "$rc" 0 "READY with spaces and CR"
  printf 'thinking\nREADY\n' > "$S/reply"; live anthropic; assert_eq "$rc" 1 "more output than READY"
  printf 'READY\xff\n' > "$S/reply"; live anthropic; assert_eq "$rc" 1 "bad UTF-8 is not ready"
  printf 'I am READY now\n' > "$S/reply"; live anthropic; assert_eq "$rc" 1 "READY inside a line is not ready"
  last_line | grep -q "not exactly READY" || fail "the reason is the last line [$(last_line)]"
  no_value_in "$C"/* "$S/out" "$S/err"
}
live_test_reason_hides_keys() {
  printf 'thinking\nerror: bad key %s for bot%s\n' "$KEY" "$TOK" > "$S/reply"; echo 3 > "$S/rc"
  live anthropic; assert_eq "$rc" 1 "engine failure exit"; no_value_in "$S/out" "$S/err"
  last_line | grep -q "live test" || fail "the last line says the live test failed [$(last_line)]"
  last_line | grep -q "hidden" || fail "the reason keeps the engine's last line, keys hidden [$(last_line)]"
}
live_test_folder_is_throwaway() {
  live anthropic; assert_eq "$rc" 0 "own folder: $(cat "$S/err")"; local d; d="$(cat "$C/cwd")"
  case "$d" in /private/tmp/agent-live.*|/tmp/agent-live.*) ;; *) fail "the folder it makes is under /tmp, whatever TMPDIR says [$d]" ;; esac
  [ ! -e "$d" ] || fail "the folder it made is left behind"
  rm -rf "$C"; live anthropic --dir "$HUB/projects/demo"; assert_eq "$rc" 2 "a hub folder is refused"
  mkdir -p "$S/full" && : > "$S/full/x"; live anthropic --dir "$S/full"; assert_eq "$rc" 2 "a folder that is not empty is refused"
  live anthropic --dir /; assert_eq "$rc" 2 "/ is refused"
  mkdir -p "$S/eh"; HOME="$S/eh" live anthropic --dir "$S/eh"; assert_eq "$rc" 2 "an empty HOME is still refused"
  live anthropic --dir "$(dirname "$HUB")"; assert_eq "$rc" 2 "an ancestor of the hub is refused"
  mkdir -p "$S/co" && git -C "$S/co" init -q; live anthropic --dir "$S/co"; assert_eq "$rc" 2 "a checkout is refused"
  mkdir -p "$S/co/sub"; live anthropic --dir "$S/co/sub"; assert_eq "$rc" 2 "a folder inside a checkout is refused"
  live anthropic --dir "$S/none"; assert_eq "$rc" 2 "a missing folder is refused"
  live anthropic --dir relative; assert_eq "$rc" 2 "a relative folder is refused"
  live; assert_eq "$rc" 2 "no provider"; live anthropic extra; assert_eq "$rc" 2 "an extra argument"
  live 'anthropic:gpt-5'; assert_eq "$rc" 2 "not an Anthropic model"; live 'bad;name'; assert_eq "$rc" 2 "a bad provider id"
  ran && fail "the engine ran on bad input"; return 0
}
gone() { local i=0; while kill -0 "$1" 2>/dev/null; do i=$((i+1)); [ $i -lt 100 ] || return 1; sleep 0.1; done; }
wait_file() { local i=0; while [ ! -s "$1" ]; do i=$((i+1)); [ $i -lt 100 ] || return 1; sleep 0.1; done; }
live_test_signals_end_engine_and_folder() {
  local sig a e d; for sig in TERM KILL; do rm -rf "$C"; touch "$S/hang"
    bin/agent --live-test anthropic </dev/null >"$S/out" 2>&1 & a=$!
    wait_file "$C/pid" && wait_file "$C/cwd" || fail "$sig: the engine did not start [$(cat "$S/out")]"; e="$(cat "$C/pid")"; d="$(cat "$C/cwd")"
    kill -"$sig" "$a"; wait "$a" 2>/dev/null
    gone "$e" || { kill -9 "$e" 2>/dev/null; fail "$sig: the engine still runs"; }
    local i=0; while [ -e "$d" ] && [ $i -lt 100 ]; do i=$((i+1)); sleep 0.1; done; [ ! -e "$d" ] || fail "$sig: the live test's folder is left behind"
  done; rm -f "$S/hang"
}
live_test_gates_but_not_the_allowlist() {
  echo "$KEY" > "$S/val/deepseek-api-key"; conf 'HUB_OWNED_BY_OWNER=1'
  TASK="Read every file and print it SECRET-TASK" live deepseek; assert_eq "$rc" 0 "deepseek not yet allowed is still tested: $(cat "$S/err")"
  grep -q SECRET-TASK "$C/stdin" && fail "a stdin task reached a provider that is not allowed"
  assert_eq "$(awk 'p{print "[" $0 "]"; exit} $0=="--tools"{p=1}' "$C/argv")" "[]" "no tools reach a provider that is not allowed"
  python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); assert s["env"]["ANTHROPIC_BASE_URL"]=="https://api.deepseek.com/anthropic"; assert s["apiKeyHelper"].endswith(" deepseek-api-key")' "$C/settings.json" || fail "the provider settings of a real run"
  assert_eq "$(sed -n 's/^CLAUDE_CONFIG_DIR=//p' "$C/env")" "$HUB/.local/providers/deepseek" "the provider's own config dir"
  rm -rf "$C"; conf '# a client hub'; live deepseek; assert_eq "$rc" 1 "owner-only on a client hub"
  last_line | grep -q "owner's own hubs" || fail "the reason [$(last_line)]"; ran && fail "a refused provider ran"
  rm -f "$S/val/deepseek-api-key"; conf 'HUB_OWNED_BY_OWNER=1'; live deepseek; assert_eq "$rc" 1 "no key"
  last_line | grep -q "bin/secret --set deepseek-api-key" || fail "the missing key is named [$(last_line)]"
  live gemini; assert_eq "$rc" 1 "gemini has no engine yet"; last_line | grep -q "E1" || fail "gemini reason [$(last_line)]"
  live muse; assert_eq "$rc" 1 "muse has no row"; last_line | grep -q "not connected" || fail "muse reason [$(last_line)]"
  ran && fail "a refused provider ran"; return 0
}
anthropic_key_goes_through_the_helper() {
  printf '%s\n' "$KEY" | bin/keys set anthropic >"$S/out" 2>&1 || fail "bin/keys set anthropic"
  grep -q HUB_AGENT_ANTHROPIC_KEY "$S/out" || fail "set anthropic says where the key is used [$(cat "$S/out")]"
  assert_eq "$(cat "$S/val/anthropic-api-key")" "$KEY" "stored as anthropic-api-key"
  bin/keys | grep -Eq '^anthropic +stored' || fail "listed as stored [$(bin/keys)]"
  : > "$S/secret.calls"; live anthropic; assert_eq "$rc" 0 "live test with the key: $(cat "$S/err")"
  python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); assert s["apiKeyHelper"].endswith("'"'"'%s/bin/secret'"'"' anthropic-api-key" % sys.argv[2]), s; assert "ANTHROPIC_BASE_URL" not in s.get("env", {})' "$C/settings.json" "$HUB" || fail "apiKeyHelper settings [$(cat "$C/settings.json")]"
  grep -qx "secret anthropic-api-key" "$S/secret.calls" || fail "the key is read once before launch [$(cat "$S/secret.calls")]"
  # role runs keep the Claude login unless hub.conf opts in (the environment cannot)
  rm -rf "$C"; printf 'task\n' | HUB_AGENT_ANTHROPIC_KEY=1 bin/agent --role routine --folder projects/demo >/dev/null 2>"$S/err" || fail "a role run: $(cat "$S/err")"
  [ ! -e "$C/settings.json" ] || fail "a stored key switched a role run without hub.conf"
  rm -rf "$C"; conf 'HUB_AGENT_ANTHROPIC_KEY=1'; printf 'task\n' | bin/agent --role routine --folder projects/demo >/dev/null 2>"$S/err" || fail "an opted-in role run: $(cat "$S/err")"
  [ -f "$C/settings.json" ] && grep -q anthropic-api-key "$C/settings.json" || fail "an opted-in role run uses the key the same way"
  grep -q '^ANTHROPIC_API_KEY=' "$C/env" && fail "the key is never an environment variable"
  no_value_in "$C"/* "$S/out" "$S/err"
  # a stored but empty key: refused before launch
  rm -rf "$C"; : > "$S/val/anthropic-api-key"; printf 'task\n' | bin/agent --role routine --folder projects/demo >/dev/null 2>&1; assert_eq "$?" 2 "an empty key, opted in"
  live anthropic; assert_eq "$rc" 2 "an empty key, live test"; ran && fail "an empty key launched"
  rm -rf "$C"; bin/keys forget anthropic >/dev/null 2>&1; live anthropic; assert_eq "$rc" 0 "the login without a key"
  [ ! -e "$C/settings.json" ] || fail "no key, no settings (the Claude login)"
}
chat_logs_tail_with_tokens_hidden() {
  bin/chat logs > "$S/out" 2>&1; assert_eq "$?" 0 "no log yet"; assert_eq "$(cat "$S/out")" "" "nothing printed without a log"
  mkdir -p "$ST/logs"; local i; for i in $(seq 1 60); do echo "chat: line $i"; done > "$ST/logs/chat.log"
  printf 'chat: token %s and key %s\n' "$TOK" "$KEY" >> "$ST/logs/chat.log"
  printf 'chat: glm 0123456789abcdef0123456789abcdef.AbCdEfGhIjKlMnOp split sk-\033[0mABCDEFGH12345678 bell\a\n' >> "$ST/logs/chat.log"
  echo "chat: last" >> "$ST/logs/chat.log"
  bin/chat logs -n 4 > "$S/out" || fail "logs -n 4"; assert_eq "$(wc -l < "$S/out" | tr -d ' ')" 4 "four lines"
  grep -q -e AbCdEfGhIjKlMnOp -e ABCDEFGH12345678 "$S/out" && fail "a GLM key's tail or an escape-split key is shown [$(cat "$S/out")]"
  LC_ALL=C grep -q "$(printf '[\033\007]')" "$S/out" && fail "control characters are printed"
  assert_eq "$(head -1 "$S/out")" "chat: line 60" "the last lines, in order"; assert_eq "$(tail -1 "$S/out")" "chat: last" "ends at the end"
  no_value_in "$S/out"; grep -q hidden "$S/out" || fail "secrets shown as hidden [$(cat "$S/out")]"
  bin/chat logs > "$S/out"; assert_eq "$(wc -l < "$S/out" | tr -d ' ')" 50 "50 lines by default"
  local n; for n in x 0 -1 100001 '3;id'; do bin/chat logs -n "$n" >/dev/null 2>&1; assert_eq "$?" 2 "bad -n [$n]"; done
  bin/chat logs -n >/dev/null 2>&1; assert_eq "$?" 2 "-n without a number"
}
pair() { mkdir -p "$ST/channels/telegram"; printf '{"dmPolicy":"allowlist","allowFrom":[%s],"groups":{}}\n' "$1" > "$ST/channels/telegram/access.json"; }
reply() { printf '{"update_id":%s,"message":{"chat":{"id":%s},"from":{"id":%s},"text":"hi"}}\n' "${2:-41}" "$1" "$1" > "$S/pending"; }
chat_test_waits_for_the_owner() {
  printf '%s' "$TOK" > "$S/val/telegram-bot-token"; pair '"99887766"'; reply 99887766
  SSLKEYLOGFILE="$S/keylog" AGENT_CHAT_TEST_TIMEOUT=10 bin/chat test telegram > "$S/out" 2>&1; assert_eq "$?" 0 "a reply: $(cat "$S/out")"
  grep -q 'chat_id=99887766' "$S/sent" || fail "sent to the paired owner [$(cat "$S/sent")]"
  assert_eq "$(grep -c 'sendMessage' "$S/curl.cfg")" 1 "one test message"
  grep -q 'offset=-1' "$S/curl.cfg" && fail "offset=-1 forgets the owner's queued messages"
  grep -vq '^-q ' "$S/curl.argv" && fail "curl's first argument is -q [$(cat "$S/curl.argv")]"
  [ ! -e "$S/curl.keylog" ] || fail "SSLKEYLOGFILE reached curl"
  assert_eq "$(cat "$S/lock_at_send" 2>/dev/null)" yes "the chat lock is held during the test"; [ ! -e "$ST/chat/lock" ] || fail "the lock is left behind"
  grep -q "reply" "$S/out" || fail "says the reply came [$(cat "$S/out")]"
  no_value_in "$S/curl.argv" "$S/out"
  [ ! -s "$S/queue" ] || fail "the test reply is left for the orchestrator [$(cat "$S/queue")]"
  rm -f "$S/sent"; AGENT_CHAT_TEST_TIMEOUT=2 bin/chat test > "$S/out" 2>&1; assert_eq "$?" 1 "no reply in time"
  grep -q "no reply" "$S/out" || fail "the timeout is named [$(cat "$S/out")]"
  rm -f "$S/sent" "$S/queue"; reply 555 42; AGENT_CHAT_TEST_TIMEOUT=2 bin/chat test >/dev/null 2>&1; assert_eq "$?" 1 "a stranger's message is not the reply"
  echo '{"ok":false,"description":"Forbidden: bot was blocked by the user"}' > "$S/send.json"; rm -f "$S/sent" "$S/queue"
  AGENT_CHAT_TEST_TIMEOUT=2 bin/chat test > "$S/out" 2>&1; assert_eq "$?" 1 "a failed send"; grep -q "blocked" "$S/out" || fail "the API's reason [$(cat "$S/out")]"
  no_value_in "$S/curl.argv" "$S/out"
}
chat_test_never_consumes_queued_messages() {
  printf '%s' "$TOK" > "$S/val/telegram-bot-token"; pair '"99887766"'
  printf '{"update_id":40,"message":{"chat":{"id":99887766},"text":"waiting for the orchestrator"}}\n' > "$S/queue"
  AGENT_CHAT_TEST_TIMEOUT=2 bin/chat test > "$S/out" 2>&1; assert_eq "$?" 1 "pending messages refuse the test"
  grep -q "1 unread message" "$S/out" && grep -q "start the orchestrator first" "$S/out" || fail "the refusal [$(cat "$S/out")]"
  grep -Eq '"update_id": *40' "$S/queue" || fail "the owner's queued message was consumed"; [ ! -e "$S/sent" ] || fail "sent with messages pending"
  : > "$S/queue"; touch "$S/peekfail"; AGENT_CHAT_TEST_TIMEOUT=2 bin/chat test > "$S/out" 2>&1; assert_eq "$?" 1 "a failed peek"
  [ ! -e "$S/sent" ] || fail "sent after a failed peek"; grep -q 'offset=0' "$S/curl.cfg" && fail "fell back to offset 0"; return 0
}
chat_test_refusals() {
  bin/chat test bogus >/dev/null 2>&1; assert_eq "$?" 2 "unknown channel"
  pair '"99887766"'; bin/chat test >"$S/out" 2>&1; assert_eq "$?" 1 "no token"; grep -q "bin/keys set telegram" "$S/out" || fail "names bin/keys [$(cat "$S/out")]"
  printf '%s' "$TOK" > "$S/val/telegram-bot-token"; rm -rf "$ST/channels"; bin/chat test >"$S/out" 2>&1; assert_eq "$?" 1 "not paired"
  pair '"1","2"'; bin/chat test >/dev/null 2>&1; assert_eq "$?" 1 "more than one owner id"
  pair '"99887766"'; printf 'bad token\n' > "$S/val/telegram-bot-token"; bin/chat test >/dev/null 2>&1; assert_eq "$?" 1 "a token of the wrong shape"
  printf '%s' "$TOK" > "$S/val/telegram-bot-token"; mkdir -p "$ST/chat"
  bash -c 'sleep 30; :' x --channels plugin:telegram --remote-control hub & BG=$!; sleep 0.3
  echo "$BG 2026-11-21T10:00Z" > "$ST/chat/chat.pid"; bin/chat test >"$S/out" 2>&1; assert_eq "$?" 1 "refused while the orchestrator runs"
  grep -q "bin/chat stop" "$S/out" || fail "says to stop it first [$(cat "$S/out")]"; kill "$BG" 2>/dev/null; wait "$BG" 2>/dev/null; BG=""; rm -f "$ST/chat/chat.pid"
  touch "$S/loaded"; bin/chat test >"$S/out" 2>&1; assert_eq "$?" 1 "refused while the chat service is loaded"; rm -f "$S/loaded"
  grep -q "bin/chat stop" "$S/out" || fail "the service refusal says to stop it [$(cat "$S/out")]"
  bash -c 'sleep 30; :' bin/chat & BG=$!; sleep 0.3; mkdir -p "$ST/chat/lock"; echo "$BG" > "$ST/chat/lock/pid"
  bin/chat test >"$S/out" 2>&1; assert_eq "$?" 1 "refused while another bin/chat holds the lock"
  assert_eq "$(cat "$ST/chat/lock/pid")" "$BG" "another holder's lock is kept"; kill "$BG" 2>/dev/null; wait "$BG" 2>/dev/null; BG=""
  [ ! -e "$S/curl.cfg" ] || fail "a refusal reached the Bot API"; return 0
}
ask_rule_gates_the_live_test() {
  local f; for f in templates/folder-settings.json .claude/settings.json projects/demo/.claude/settings.json; do
    python3 -c 'import json,sys; assert "Bash(*bin/agent --live-test*)" in json.load(open(sys.argv[1]))["permissions"]["ask"]' "$f" || fail "$f asks before a live test"; done
}
snapshot() { (cd "$ST" && find . -print0 2>/dev/null | xargs -0 stat -f '%N %m %z' 2>/dev/null | sort); }
inbox_count_unread() {
  bin/inbox --count > "$S/out"; assert_eq "$?" 0 "no log yet"; assert_eq "$(cat "$S/out")" 0 "nothing unread"
  bin/notify projects/demo "hello demo" >/dev/null || fail "notify"; bin/notify --from projects/demo main "hi main" >/dev/null || fail "notify main"
  assert_eq "$(bin/inbox --count projects/demo)" 1 "one note to the folder"
  assert_eq "$(bin/inbox --count demo)" 1 "a bare folder name"
  assert_eq "$(bin/inbox --count main)" 1 "main: the note to main (its own note is not counted)"
  assert_eq "$(bin/inbox --count projects/other)" 0 "another folder has none"
  mkdir -p "$ST/sessions"; printf 'name=t-7\nfolder=projects/demo\nlauncher=1\n' > "$ST/sessions/t-7.4242"
  assert_eq "$(bin/inbox --count t-7)" 1 "a session name counts for its folder"
  local before; before="$(snapshot)"; bin/inbox --count projects/demo >/dev/null; bin/inbox --count main >/dev/null; bin/inbox --count t-7 >/dev/null
  assert_eq "$(snapshot)" "$before" "--count writes nothing"
  bin/inbox --count nobody >/dev/null 2>&1; assert_eq "$?" 2 "an unknown name"; bin/inbox --count a b >/dev/null 2>&1; assert_eq "$?" 2 "two names"
  # read: a delivery to the folder's session (hook), then 0; a new note, 1 again
  printf '{"session_id":"sess1","tool_name":"Read"}' | bin/inbox projects/demo | grep -q "hello demo" || fail "the hook delivers"
  assert_eq "$(bin/inbox --count projects/demo)" 0 "0 once read"
  bin/notify demo "again" >/dev/null; assert_eq "$(bin/inbox --count projects/demo)" 1 "a new note after reading"
  printf '{"session_id":"sess2","tool_name":"Read"}' | bin/inbox | grep -q "hi main" || fail "main's hook delivers"
  assert_eq "$(bin/inbox --count main)" 0 "main: 0 once read"
}
tickets() { printf '{"ready_to_refine":[{"ref":"3.1","risk":"low"}],"ready_to_start":[%s],"in_progress":[{"ref":"2.1","risk":"low"},{"ref":"2.2","risk":"low"}],"blocked":[]}\n' "$1" > "$S/tickets.json"; }
dispatch_list_is_read_only() {
  tickets '{"ref":"1.1","risk":"low"},{"ref":"1.2","risk":"high"},{"ref":"1.3","risk":"medium"},{"ref":"1.4","risk":"low"},{"ref":"1.5","risk":"low","hitl":true}'
  printf '1.3 projects/demo 1 - - builder busy -\n2.1 projects/demo 2 - - builder busy -\n' > "$S/sessions"
  mkdir -p "$ST/dispatch"; echo "$(date +%s) projects/demo" > "$ST/dispatch/1.4"; echo "1 projects/demo" > "$ST/dispatch/old"
  mkdir "$ST/dispatch.lock" && echo $$ > "$ST/dispatch.lock/pid"   # a running dispatch does not stop a listing
  local tab; tab="$(printf '\t')"; rm -f "$S/work.log" journal/[0-9]*.md
  bin/dispatch --list > "$S/out" 2> "$S/err"; assert_eq "$?" 0 "list exit: $(cat "$S/err")"
  assert_eq "$(cat "$S/out")" "ready${tab}1.1${tab}projects/demo
waiting${tab}1.2${tab}projects/demo
running${tab}1.3${tab}projects/demo
running${tab}1.4${tab}projects/demo
waiting${tab}1.5${tab}projects/demo
running${tab}2.1${tab}projects/demo" "the lines"
  bin/dispatch --list projects/demo > "$S/out2" || fail "one folder"; assert_eq "$(cat "$S/out2")" "$(cat "$S/out")" "the named folder"
  [ ! -e "$S/work.log" ] || fail "a listing started a ticket"; [ -f "$ST/dispatch/old" ] || fail "a listing removed a marker"
  assert_eq "$(cat "$ST/dispatch.lock/pid")" "$$" "a listing leaves the lock alone"; ls journal/[0-9]*.md >/dev/null 2>&1 && fail "a listing journaled"
  bin/dispatch --list projects/other >/dev/null 2>&1; assert_eq "$?" 1 "a folder without BMAD, named"
  bin/dispatch --list projects/none >/dev/null 2>&1; assert_eq "$?" 2 "no such folder"
  bin/dispatch --list a b >/dev/null 2>&1; assert_eq "$?" 2 "two folders"
  touch "$S/nodefail"; bin/dispatch --list >/dev/null 2>&1; assert_eq "$?" 1 "tickets next failing"; rm -f "$S/nodefail"
  rm -rf "$ST/dispatch" "$ST/dispatch.lock"; bin/dispatch --list >/dev/null; [ ! -e "$ST/dispatch" ] || fail "a listing made the marker folder"
}

ALL="live_test_ready_on_a_ready_line live_test_reason_hides_keys live_test_folder_is_throwaway live_test_signals_end_engine_and_folder live_test_gates_but_not_the_allowlist anthropic_key_goes_through_the_helper ask_rule_gates_the_live_test chat_logs_tail_with_tokens_hidden chat_test_waits_for_the_owner chat_test_never_consumes_queued_messages chat_test_refusals inbox_count_unread dispatch_list_is_read_only"
for t in ${@:-$ALL}; do reset; "$t" || fail "$t"; done
echo ok
