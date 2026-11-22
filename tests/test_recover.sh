#!/bin/bash
# bin/recover (story R1): each crash scenario is simulated, bin/recover runs, the recovery and its journal line are
# checked. Fakes for claude, launchctl and the chat channel (AGENT_CHAT_SEND); the REAL BMAD runtime for tickets; no
# network. Every temp folder lives under one root, removed (and every helper process stopped) on exit.
TROOT="$(mktemp -d)"; export TMPDIR="$TROOT/"
BG=""; cleanup() { local p; exec 2>/dev/null; for p in $BG; do kill "$p"; wait "$p"; done; rm -rf "${TROOT:?}"; }; trap cleanup EXIT
. "$(dirname "$0")/helpers.sh"
make_hub; cd "$HUB"; stub_security; export AGENT_STATE="$(mktemp -d)"; ST="$AGENT_STATE"
FAKE="$(mktemp -d)"; mkdir -p "$FAKE/bin"; export FAKE
# the fake channel: one payload per call on stdin; fails for everyone (FAKE_SEND_FAIL=1), for one owner
# (FAKE_FAIL_FOR=<id>) or for a text that holds FAKE_FAIL_TEXT
cat > "$FAKE/bin/send" <<'STUB'
#!/bin/bash
p="$(cat)"; [ -z "${FAKE_SEND_FAIL:-}" ] || exit 1
[ -z "${FAKE_FAIL_FOR:-}" ] || case "$p" in *"\"chat_id\": \"$FAKE_FAIL_FOR\""*) exit 1 ;; esac
[ -z "${FAKE_FAIL_TEXT:-}" ] || case "$p" in *"$FAKE_FAIL_TEXT"*) exit 1 ;; esac
printf '%s\n' "$p" >> "$FAKE/sent"
STUB
printf '#!/bin/bash\necho "$*" >> "$FAKE/launchctl.log"\nexit 0\n' > "$FAKE/bin/launchctl"
cat > "$FAKE/bin/claude" <<'STUB'
#!/bin/bash
echo started >> "$FAKE/claude.log"; exit 0
STUB
printf '#!/bin/bash\nexit 0\n' > "$FAKE/bin/bun"
chmod +x "$FAKE"/bin/*; export PATH="$FAKE/bin:$PATH" AGENT_CHAT_SEND="$FAKE/bin/send" AGENT_LAUNCHAGENTS="$(mktemp -d)"
export AGENT_CHAT_FORWARD_EVERY=0
unset TELEGRAM_BOT_TOKEN TELEGRAM_STATE_DIR HUB_CHAT HUB_CHANNELS CLAUDE_CONFIG_DIR AGENT_CHAT_SERVICE
CH="$ST/channels/telegram"; mkdir -p "$CH"
owners() { printf '{"dmPolicy": "allowlist", "allowFrom": [%s], "groups": {}}\n' "$1" > "$CH/access.json"; }; owners '"99887766"'
printf '%s\n' "123456789:TEST-telegram-token-VALUE-abc" | bin/keys set telegram >/dev/null 2>&1
bin/new projects/demo >/dev/null
# the folder's checkout: a git repo with an upstream, and a real BMAD ticket store (the template's own runtime)
UP="$(mktemp -d)/up.git"; git init -q --bare "$UP"
CK="$(mktemp -d)/demo-code"; mkdir -p "$CK/_bmad/custom" "$CK/_bmad-output/initiative-x/epic-a"
git -C "$CK" init -q && git -C "$CK" config user.name t && git -C "$CK" config user.email t@t
cp "$REPO/_bmad/ade-runtime.mjs" "$CK/_bmad/"
printf '[core]\nproject_name = "x"\noutput_folder = "{project-root}/_bmad-output"\n' > "$CK/_bmad/config.toml"
printf '[core]\nactive_initiative = "initiative-x"\n' > "$CK/_bmad/custom/config.user.toml"
printf -- '---\ntype: initiative\ntitle: "X"\nparent: none\ncovers: []\nassignee: ""\nrisk: low\n---\n# X\n' > "$CK/_bmad-output/initiative-x/initiative-x.md"
printf '[[epic]]\nid = 1\nslug = "epic-a"\ntitle = "Epic A"\ncovers = []\n' > "$CK/_bmad-output/initiative-x/tickets.toml"
printf -- '---\ntype: epic\ntitle: "Epic A"\nparent: initiative-x\ncovers: []\nafter: []\nassignee: ""\nrisk: low\n---\n# Epic A\n' > "$CK/_bmad-output/initiative-x/epic-a/epic-a.md"
for i in 2 3 4; do printf '[[entry]]\nid = %s\ntype = "story"\ntitle = "Story %s"\ndescription = "x"\n\n' "$i" "$i"; done > "$CK/_bmad-output/initiative-x/epic-a/tickets.toml"
printf '_bmad/\n_bmad-output/\n' >> "$CK/.git/info/exclude"   # the ticket store's plans are not the agent's work
echo one > "$CK/a.txt"; git -C "$CK" add -A && git -C "$CK" commit -qm init && git -C "$CK" remote add origin "$UP" && git -C "$CK" push -q -u origin HEAD:main 2>/dev/null
RT() { node "$CK/_bmad/ade-runtime.mjs" tickets --project-root "$CK" "$@"; }
tstatus() { RT find "$1" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("status") or "-", d.get("blocked_reason") or "-")'; }
J() { cat journal/*.md 2>/dev/null; }
sent_texts() { python3 -c 'import json,sys
for l in open(sys.argv[1]):
    l=l.strip()
    if l: print(json.loads(l)["text"])' "$FAKE/sent" 2>/dev/null; }
sent_to() { python3 -c 'import json,sys
for l in open(sys.argv[1]):
    l=l.strip()
    if l: d=json.loads(l); print(d["chat_id"], d["text"])' "$FAKE/sent" 2>/dev/null; }
dead_pid() { sleep 0 & local p=$!; wait "$p" 2>/dev/null; echo "$p"; }
# a live stand-in for a bin/work launcher (its command holds "-work.", as bin/sessions checks)
live_launcher() { local f; f="$(mktemp -d)/agent-work.live"; printf '#!/bin/bash\nsleep 60\n' > "$f"; chmod +x "$f"; "$f" </dev/null >/dev/null 2>&1 & echo $!; }
pstart() { (. bin/lib.sh; proc_start "$1"); }
# entry <name> <folder> <launcher pid> <cwd> <role> [key=value...]
entry() { local n="$1" f="$2" l="$3" c="$4" r="$5"; shift 5; mkdir -p "$ST/sessions"
  { printf 'name=%s\nfolder=%s\nlauncher=%s\nparent=-\nstarted=2026-11-21T10:00:00Z\ncwd=%s\nrole=%s\n' "$n" "$f" "$l" "$c" "$r"
    for kv in "$@"; do printf '%s\n' "$kv"; done; } > "$ST/sessions/$n.$l"; }
note() { cat "$ST/recover/"*.md 2>/dev/null; }
reset() { rm -rf journal/*.md "$ST/recover" "$ST/sessions" "$ST/sessions-dead" "$ST/chat" "$ST/events.jsonl" "$ST/events-seen" \
  "$ST/dispatch.lock" "$AGENT_SYNC_LOCK"; : > "$FAKE/sent"; : > "$FAKE/launchctl.log"; : > "$FAKE/claude.log"; owners '"99887766"'
  RT mark 1.2 in-progress >/dev/null; RT mark 1.3 done >/dev/null; RT mark 1.4 ready-for-dev >/dev/null; }

orchestrator_died_restarts() {   # row 1
  reset; lp="$(live_launcher)"; BG="$BG $lp"; entry api projects/demo "$lp" "$CK" builder "start=$(pstart "$lp")"; mkdir -p "$ST/chat"
  echo "$(dead_pid) 2026-11-21T09:00Z" > "$ST/chat/chat.pid"
  mkdir -p "$ST/chat/asks"; echo "Deploy?" > "$ST/chat/asks/abcde"
  out="$(bin/recover 2>&1)" || fail "recover [$out]"
  [ -e "$ST/chat/chat.pid" ] && fail "the dead orchestrator's pid file was kept"
  J | grep -q "orchestrator died" || fail "journal line [$(J)]"
  sent_texts | grep -qx "restarted, 1 agent running, 1 waiting" || fail "the restart message [$(sent_texts)]"
  # a crash loop: the next restart within 10 minutes journals, but does not post "restarted" again
  echo "$(dead_pid) 2026-11-21T09:01Z" > "$ST/chat/chat.pid"; bin/recover >/dev/null 2>&1
  assert_eq "$(sent_texts | grep -c '^restarted')" "1" "one restarted message per loop"
  for s in "After a restart" "STATE.md" "bin/work --resume"; do assert_contains templates/hub/CLAUDE.md "$s" "hub rule: what to read after a restart"; done
}

reboot_runs_recover_first() {   # row 2
  reset; SCHEDULE_DRY=1 bin/schedule install >/dev/null 2>&1
  p="$AGENT_LAUNCHAGENTS/ai.agent-hub.hub.recover.plist"; [ -f "$p" ] || fail "no recover job at login"
  assert_contains "$p" "bin/recover" "the job runs bin/recover"; assert_contains "$p" "<key>RunAtLoad</key><true/>" "at login"
  mkdir -p "$ST/chat"; echo "$(dead_pid) 2026-11-21T09:00Z" > "$ST/chat/chat.pid"
  bin/chat start </dev/null >/dev/null 2>&1 || fail "chat start"
  J | grep -q "orchestrator died" || fail "chat start ran no recover first [$(J)]"
  [ -s "$FAKE/claude.log" ] || fail "the session started after recover"
}

agent_died_blocked_not_done() {   # row 3, with the real ticket runtime
  reset; head0="$(git -C "$CK" rev-parse HEAD)"
  # the session name is bin/dispatch's sanitised one; the entry's ticket= is the real ref, and only that is marked
  entry Story-2 projects/demo "$(dead_pid)" "$CK" builder "ticket=1.2"
  out="$(bin/recover 2>&1)" || fail "recover [$out]"
  J | grep -q "agent Story-2 died" || fail "journal line [$(J)]"
  assert_eq "$(tstatus 1.2)" "blocked agent died" "the in-progress ticket is marked blocked"
  assert_eq "$(git -C "$CK" rev-parse HEAD)" "$head0" "nothing committed on its behalf"
  grep -q '"from":"projects/demo","to":"main","kind":"note","text":"blocked: agent Story-2 died' "$ST/events.jsonl" || fail "main notified [$(cat "$ST/events.jsonl")]"
  ls "$ST/sessions/" "$ST/sessions-dead/" 2>/dev/null | grep -q Story-2 && fail "the dead entry is still kept"
  # a ready-for-dev ticket is blocked too; a done ticket is never touched
  reset; entry b4 projects/demo "$(dead_pid)" "$CK" builder "ticket=1.4"; entry b3 projects/demo "$(dead_pid)" "$CK" builder "ticket=1.3"
  bin/recover >/dev/null 2>&1
  assert_eq "$(tstatus 1.4)" "blocked agent died" "a ready-for-dev ticket is blocked"
  assert_eq "$(tstatus 1.3)" "done -" "a done ticket stays done"
  J | grep -q "ticket 1.3 left as done" || fail "the done ticket is named [$(J)]"
  # no ticket= (a session not started by bin/dispatch): no ticket is marked by its name
  reset; entry 1.2 projects/demo "$(dead_pid)" "$CK" builder; bin/recover >/dev/null 2>&1
  assert_eq "$(tstatus 1.2)" "in-progress -" "a name is never taken for a ticket ref"
  # bin/sessions keeps a dead entry for recover (it used to delete it)
  reset; entry web projects/demo "$(dead_pid)" "$CK" -; bin/sessions >/dev/null
  bin/recover >/dev/null 2>&1; J | grep -q "agent web died" || fail "an entry bin/sessions pruned is still recovered"
}

ticket_mark_retried() {   # review 6: no node, or a failing mark: the entry is kept and retried
  reset; entry b2 projects/demo "$(dead_pid)" "$CK" builder "ticket=1.2"
  NP="$(mktemp -d)"; for c in bash sh dirname basename sed grep awk tr cat python3 git ps date mkdir chmod rm wc id sleep stat mv cp df head tail env cut find sort uniq shasum mktemp ls touch; do
    ln -s "$(command -v "$c")" "$NP/$c" 2>/dev/null; done
  PATH="$NP" bin/recover >/dev/null 2>&1
  J | grep -q "ticket 1.2 could not be marked blocked (node not found)" || fail "the failure is journaled [$(J)]"
  assert_eq "$(tstatus 1.2)" "in-progress -" "not marked without node"
  ls "$ST/sessions-dead/" "$ST/sessions/" 2>/dev/null | grep -q '^b2\.' || fail "the entry is kept for a retry"
  bin/recover >/dev/null 2>&1
  assert_eq "$(tstatus 1.2)" "blocked agent died" "marked on the next run"
  assert_eq "$(J | grep -c 'agent b2 died')" "1" "the death is journaled once"
  ls "$ST/sessions-dead/" "$ST/sessions/" 2>/dev/null | grep -q '^b2\.' && fail "the entry is removed once marked"
  # an unknown ref: tickets find fails, the reason is journaled, the entry is kept
  reset; entry b9 projects/demo "$(dead_pid)" "$CK" builder "ticket=9.9"; bin/recover >/dev/null 2>&1
  J | grep -q "ticket 9.9 could not be marked blocked (tickets find failed" || fail "find failure journaled [$(J)]"
  ls "$ST/sessions-dead/" "$ST/sessions/" 2>/dev/null | grep -q '^b9\.' || fail "kept after a failed find"; true
}

restart_line() {   # review 2: the exact session, or a fresh start for a provider session
  reset; entry b2 projects/demo "$(dead_pid)" "$CK" builder "ticket=1.2" "session_id=sess-abc_1" "provider=anthropic" "model=opus" "config_dir=/cfg/x"
  bin/recover >/dev/null 2>&1
  note | grep -qF "restart: CLAUDE_CONFIG_DIR=/cfg/x bin/work --resume sess-abc_1 --role builder --ticket 1.2 --name b2 projects/demo" || fail "resume line [$(note)]"
  reset; entry p1 projects/demo "$(dead_pid)" "$CK" - "provider=deepseek" "model=sonnet" "session_id=s-9" "config_dir=/p"
  bin/recover >/dev/null 2>&1
  note | grep -qF "restart (fresh: a provider session never resumes): bin/work --provider deepseek --model sonnet --name p1 projects/demo" || fail "fresh line [$(note)]"
  note | grep -qE -- '--resume|--continue' && fail "a provider session is offered a resume"
  reset; entry n1 projects/demo "$(dead_pid)" "$CK" -; bin/recover >/dev/null 2>&1
  note | grep -qF "restart: bin/work --continue --name n1 projects/demo" || fail "no session id: --continue [$(note)]"
  # bin/work takes --resume <id> for Claude sessions only
  out="$(WORK_DRY=1 bin/work --resume sess-abc_1 --force --claude claude projects/demo 2>&1)"; echo "$out" | grep -q -- "--resume sess-abc_1" || fail "bin/work --resume [$out]"
  WORK_DRY=1 bin/work --resume 'bad id' --force projects/demo >/dev/null 2>&1; assert_eq "$?" "2" "a bad session id"
}

uncommitted_work_kept() {   # row 4 and review 9
  reset; echo changed >> "$CK/a.txt"; echo staged > "$CK/s.txt"; git -C "$CK" add s.txt; echo new > "$CK/b.txt"
  before="$(git -C "$CK" status --porcelain; git -C "$CK" diff HEAD)"
  echo c2 > "$CK/c.txt"; git -C "$CK" add c.txt; git -C "$CK" commit -qm "local only" -- c.txt; before="$(git -C "$CK" status --porcelain; git -C "$CK" diff HEAD)"
  entry T-1.3 projects/demo "$(dead_pid)" "$CK" builder; bin/recover >/dev/null 2>&1
  assert_eq "$(git -C "$CK" status --porcelain; git -C "$CK" diff HEAD)" "$before" "uncommitted work kept as-is"
  git -C "$CK" stash list | grep -q . && fail "work was stashed"
  note | grep -q "a.txt" && note | grep -q "s.txt" && note | grep -q "2 files changed" || fail "the note has the diff stat against HEAD, staged too [$(note)]"
  note | grep -q "?? b.txt" || fail "the note lists the untracked file"
  note | grep -q "local only" || fail "the note lists commits not pushed [$(note)]"
  J | grep -q "uncommitted work kept in $CK" || fail "journal line [$(J)]"
  git -C "$CK" reset -q --hard origin/main; rm -f "$CK/b.txt"
}

stale_locks_removed() {   # row 5
  reset; d="$(dead_pid)"; mkdir -p "$ST/chat/lock" "$ST/chat/forward.lock" "$ST/dispatch.lock" "$AGENT_SYNC_LOCK"
  for l in "$ST/chat/lock" "$ST/chat/forward.lock" "$ST/dispatch.lock" "$AGENT_SYNC_LOCK"; do echo "$d" > "$l/pid"; done
  sleep 60 </dev/null >/dev/null 2>&1 & live=$!; BG="$BG $live"
  bin/recover >"$FAKE/out" 2>&1
  for l in "$ST/chat/lock" "$ST/chat/forward.lock" "$ST/dispatch.lock" "$AGENT_SYNC_LOCK"; do
    [ -e "$l" ] && fail "stale lock kept: $l"; J | grep -q "removed stale lock $l" || fail "journaled: $l [$(J)] [$(cat "$FAKE/out")]"; done
  mkdir -p "$ST/dispatch.lock"; echo "$live" > "$ST/dispatch.lock/pid"; bin/recover >/dev/null 2>&1
  [ -d "$ST/dispatch.lock" ] || fail "a live owner's lock was removed"; rm -rf "$ST/dispatch.lock"
}

torn_log_and_cursor() {   # row 6 and review 4
  reset; H="$HUB" ST="$ST" python3 -I bin/events.py write --from main --to all --kind note --text "whole line" || fail "write"
  printf '{"time":"2026-11-21T10:00:00Z","from":"main","to":"all","ki' >> "$ST/events.jsonl"
  size="$(wc -c < "$ST/events.jsonl")"; ino="$(ls -i "$ST/events.jsonl" | awk '{print $1}')"
  mkdir -p "$ST/events-seen" "$ST/chat"; echo "$ino $((size + 500))" > "$ST/events-seen/sess1"; echo "$ino 999999" > "$ST/chat/forward.cursor"
  bin/recover >/dev/null 2>&1
  [ "$(tail -c 1 "$ST/events.jsonl" | od -An -c | tr -d ' ')" = '\n' ] || fail "the torn last line is still there"
  python3 -c 'import json,sys; [json.loads(l) for l in open(sys.argv[1])]' "$ST/events.jsonl" || fail "the log is not whole lines"
  grep -q "whole line" "$ST/events.jsonl" || fail "a whole line was lost"
  ns="$(wc -c < "$ST/events.jsonl" | tr -d ' ')"
  assert_eq "$(cat "$ST/events-seen/sess1")" "$ino $ns" "a cursor past the end is reset to the end"
  assert_eq "$(cat "$ST/chat/forward.cursor")" "$ino $ns" "the forward cursor too"
  J | grep -q "event log: dropped a torn last line" || fail "journal line [$(J)]"
  # 1000 lines and then 1 MiB without a line end: nothing before the last MiB is ever cut
  reset; python3 - "$ST/events.jsonl" <<'PY'
import json, sys
with open(sys.argv[1], "wb") as f:
    for i in range(1000): f.write((json.dumps({"time": "2026-11-21T10:00:00Z", "from": "main", "to": "all", "kind": "note", "text": "n%d" % i}) + "\n").encode())
    f.write(b"\0" * (1 << 20))
PY
  size="$(wc -c < "$ST/events.jsonl" | tr -d ' ')"
  out="$(bin/recover 2>&1)"; echo "$out" | grep -q "event log: not repaired" || fail "says it cannot repair [$out]"
  assert_eq "$(wc -c < "$ST/events.jsonl" | tr -d ' ')" "$size" "nothing truncated"
  assert_eq "$(grep -c '"text": "n' "$ST/events.jsonl")" "1000" "the 1000 lines are kept"
  # the next writer starts its line after a line end, so its event is whole
  H="$HUB" ST="$ST" python3 -I bin/events.py write --from main --to all --kind note --text "after the torn bytes" || fail "write after torn"
  tail -1 "$ST/events.jsonl" | python3 -c 'import json,sys; assert json.loads(sys.stdin.read())["text"]=="after the torn bytes"' || fail "the new event is not a whole line"
}

network_down_nothing_lost() {   # row 7 and review 7
  reset; mkdir -p "$ST/chat"; echo "$(dead_pid) 2026-11-21T09:00Z" > "$ST/chat/chat.pid"
  FAKE_SEND_FAIL=1 bin/recover >/dev/null 2>&1
  [ -s "$FAKE/sent" ] && fail "sent while the network is down"
  J | grep -q "chat unreachable: the message is kept" || fail "journal line [$(J)]"
  ls "$ST/chat/pending/" | grep -q '\.txt$' || fail "the message is kept to send later"
  bin/chat forward >/dev/null 2>&1 || fail "forward once the network is back"
  sent_texts | grep -q "^restarted, " || fail "the kept message was sent [$(sent_texts)]"
  ls "$ST/chat/pending/" | grep -q . && fail "a sent message was kept"
  : > "$FAKE/sent"; bin/chat forward >/dev/null 2>&1; [ -s "$FAKE/sent" ] && fail "sent twice"
  . bin/lib.sh; assert_eq "$(chat_backoff 15 1) $(chat_backoff 30 1) $(chat_backoff 120 1) $(chat_backoff 120 0)" "30 60 120 15" "backoff"
  # a pending message that keeps failing does not hold back the agents' events
  reset; mkdir -p "$ST/chat"; bin/chat say "STUCK message" >/dev/null 2>&1; : > "$FAKE/sent"
  FAKE_SEND_FAIL=1 bin/chat say "STUCK message" >/dev/null 2>&1
  H="$HUB" ST="$ST" python3 -I bin/events.py write --auto --from projects/demo --to main --kind idle --text "event behind" || fail "event"
  FAKE_FAIL_TEXT=STUCK bin/chat forward >/dev/null 2>&1
  sent_texts | grep -q "event behind" || fail "the outbox was held back by a failing pending message [$(sent_texts)]"
  # each message has a try limit: after 10 failed tries it is dropped and journaled
  for i in 1 2 3 4 5 6 7 8 9 10; do FAKE_FAIL_TEXT=STUCK bin/chat forward >/dev/null 2>&1; done
  ls "$ST/chat/pending/" | grep -q '\.txt$' && fail "a message is retried for ever"
  J | grep -q "chat: dropped a message after 10 tries" || fail "the drop is journaled [$(J)]"
  # two owners, one unreachable: the one that got it is never sent it again
  reset; owners '"111", "222"'; mkdir -p "$ST/chat"
  FAKE_FAIL_FOR=222 bin/chat say "to both" >/dev/null 2>&1
  FAKE_FAIL_FOR=222 bin/chat forward >/dev/null 2>&1; bin/chat forward >/dev/null 2>&1
  assert_eq "$(sent_to | grep -c '^111 to both')" "1" "the owner that got it once is not resent"
  assert_eq "$(sent_to | grep -c '^222 to both')" "1" "the other owner gets it once it is reachable"
}

disk_full_one_alert() {   # row 8
  reset; AGENT_DISK_MIN_MB=999999999 bin/recover >"$FAKE/out" 2>&1 || fail "recover, disk full"
  grep -q "disk full" "$FAKE/out" || fail "reported [$(cat "$FAKE/out")]"
  J | grep -q "disk full" || fail "journal line"
  assert_eq "$(sent_texts | grep -c 'disk full')" "1" "one alert to the channel"
  AGENT_DISK_MIN_MB=999999999 bin/recover >/dev/null 2>&1; assert_eq "$(sent_texts | grep -c 'disk full')" "1" "still one alert"
  AGENT_DISK_MIN_MB=999999999 DOCTOR_OFFLINE=1 bin/doctor | grep -q "disk full" || fail "doctor shows it"
  bin/recover >/dev/null 2>&1; [ -e "$ST/recover/disk-alert" ] && fail "the alert marker outlived the full disk"; true
}

agents_survive_ui_close() {   # row 9 and review 10
  reset; lp="$(live_launcher)"; BG="$BG $lp"; entry api projects/demo "$lp" "$CK" builder "start=$(pstart "$lp")"
  out="$(bin/recover 2>&1)"; kill -0 "$lp" 2>/dev/null || fail "recover stopped a running agent"
  [ -f "$ST/sessions/api.$lp" ] || fail "a running agent's entry was touched"
  J | grep -q "died" && fail "a running agent was reported dead"
  bin/sessions | grep -q "^api " || fail "the agent is still listed"
  # the same pid with another start time: the launcher died and another one reused its pid
  reset; entry ghost projects/demo "$lp" "$CK" - "start=Mon Jan  1 00:00:00 2001"
  bin/recover >/dev/null 2>&1; J | grep -q "agent ghost died" || fail "a start-time mismatch counts as dead [$(J)]"; true
}

monitor_runs_agent_check() {   # review 5
  reset; entry m1 projects/demo "$(dead_pid)" "$CK" builder "ticket=1.2"; MONITOR_QUIET=1 bin/monitor >/dev/null 2>&1
  J | grep -q "agent m1 died" || fail "bin/monitor ran the agent check [$(J)]"
  assert_eq "$(tstatus 1.2)" "blocked agent died" "and the ticket is blocked"
}

login_expired_stops_retrying() {   # row 10 and review 3
  reset; export AGENT_CHAT_SERVICE=1
  # a session that lived long does not count as a quick restart
  bin/chat start </dev/null >/dev/null 2>&1 || fail "service start"; s1="$(tail -1 "$ST/chat/service-starts")"; echo "$s1 $(( ${s1%.*} + 600 ))" > "$ST/chat/alive"
  for i in 1 2 3; do bin/chat start </dev/null >/dev/null 2>&1 || fail "service start after a long session ($i)"; done
  assert_eq "$(grep -c started "$FAKE/claude.log")" "4" "a long-lived session resets the count"
  out="$(bin/chat start </dev/null 2>&1)"; assert_eq "$?" "1" "the start after 3 quick sessions gives up [$out]"
  assert_eq "$(grep -c started "$FAKE/claude.log")" "4" "no launch after giving up"
  grep -q "disable gui/.*ai.agent-hub.hub.chat" "$FAKE/launchctl.log" || fail "the job is disabled so launchd stops [$(cat "$FAKE/launchctl.log")]"
  sent_texts | grep -q 'login expired: run `claude` once' || fail "the channel is told [$(sent_texts)]"
  J | grep -q "login expired" || fail "journal line"
  assert_eq "$(sent_texts | grep -c '^restarted')" "1" "the crash loop posts restarted once"
  # bin/schedule install (chat enabled again) clears the count and the stop
  echo 'HUB_CHAT=telegram' > hub.conf; SCHEDULE_DRY=1 bin/schedule install >/dev/null 2>&1; rm -f hub.conf
  { [ -e "$ST/chat/gave-up" ] || [ -e "$ST/chat/service-starts" ]; } && fail "schedule install left the stop in place"
  bin/chat start </dev/null >/dev/null 2>&1 || fail "a service start after schedule install"
  unset AGENT_CHAT_SERVICE
}

hub_name_clash() {   # review 8
  reset; H1="$HUB"; make_hub; H2="$HUB"; mkdir -p "$H2/projects"
  echo "$H1" > "$ST/hub-path"
  out="$(cd "$H2" && HUB="$H2" bin/recover 2>&1)"; assert_eq "$?" "2" "recover stops for a clashing hub [$out]"
  echo "$out" | grep -q "already used by the hub at $H1" || fail "says why [$out]"
  (cd "$H2" && HUB="$H2" DOCTOR_OFFLINE=1 bin/recover --check) | grep -q "^WARN .*recover hub name" || fail "--check warns"
  rm -f "$AGENT_LAUNCHAGENTS"/*.plist; (cd "$H2" && HUB="$H2" SCHEDULE_DRY=1 bin/schedule install >/dev/null 2>&1)
  ls "$AGENT_LAUNCHAGENTS" | grep -q recover && fail "a recover job for a clashing hub"
  mkdir -p "$ST/chat"; echo "$(dead_pid) x" > "$ST/chat/chat.pid"
  (cd "$H2" && HUB="$H2" bin/chat start </dev/null >/dev/null 2>&1)
  [ -e "$ST/chat/chat.pid" ] || fail "a clashing hub's chat start ran recover (it removed the other hub's pid file)"
  HUB="$H1"; cd "$H1"; (cd "$H1" && pwd -P) > "$ST/hub-path"
}

idempotent() {   # AC 11
  reset; mkdir -p "$ST/chat"; echo "$(dead_pid) x" > "$ST/chat/chat.pid"; entry T-9 projects/demo "$(dead_pid)" "$CK" builder "ticket=1.2"
  bin/recover >/dev/null 2>&1; j1="$(J)"; n1="$(ls "$ST/recover" | wc -l)"
  out="$(bin/recover 2>&1)" || fail "second run"; assert_eq "$out" "nothing to recover" "a second run"
  assert_eq "$(J)" "$j1" "a second run journals nothing"; assert_eq "$(ls "$ST/recover" | wc -l)" "$n1" "no second note"
}

doctor_read_only() {   # AC 12
  reset; mkdir -p "$ST/chat" "$ST/dispatch.lock"; echo "$(dead_pid) x" > "$ST/chat/chat.pid"; echo "$(dead_pid)" > "$ST/dispatch.lock/pid"
  entry T-8 projects/demo "$(dead_pid)" "$CK" builder "ticket=1.2"
  printf '{"a":1}\n{"tor' > "$ST/events.jsonl"
  snap() { (cd "$ST" && find . -print | sort; find . -type f -exec cat {} + 2>/dev/null) | shasum; }
  s0="$(snap)"; j0="$(J)"
  out="$(DOCTOR_OFFLINE=1 bin/doctor)"
  for c in "orchestrator" "agent T-8" "lock" "event log" "disk"; do echo "$out" | grep "^[A-Z]* *recover" | grep -q "$c" || fail "doctor lists [$c] [$out]"; done
  assert_eq "$(snap)" "$s0" "doctor changed the state"; assert_eq "$(J)" "$j0" "doctor journaled"
  assert_eq "$(tstatus 1.2)" "in-progress -" "doctor marked no ticket"
}

checks="orchestrator_died_restarts reboot_runs_recover_first agent_died_blocked_not_done ticket_mark_retried restart_line
  uncommitted_work_kept stale_locks_removed torn_log_and_cursor network_down_nothing_lost disk_full_one_alert
  agents_survive_ui_close monitor_runs_agent_check login_expired_stops_retrying hub_name_clash idempotent doctor_read_only"
if [ $# -gt 0 ]; then "$1"; echo ok; exit 0; fi
for c in $checks; do "$c"; done
echo ok
