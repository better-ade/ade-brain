#!/bin/bash
# Story S1: a focus session is nudged to check in (STATE.md, then a note to main) every HUB_CHECKIN_MINUTES of work;
# bin/checkin --missed (run by bin/monitor) tells main about a session that missed its check-in or went quiet.
. "$(dirname "$0")/helpers.sh"
make_hub; cd "$HUB"
unset HUB_CHECKIN_MINUTES
ST="$(mktemp -d)"; export AGENT_STATE="$ST"
bin/new projects/demo >/dev/null 2>&1 || fail "bin/new projects/demo"
K="$ST/checkin/projects-demo"; SM="$HUB/projects/demo/STATE.md"; LOG="$ST/events.jsonl"
echo "- wiring the login form" >> "$SM"
printf '{"session_id":"main-1"}' | bin/inbox >/dev/null   # the main session's baseline: the empty log
# a python3 that records every call (AC2: the cheap path starts none), then runs the real one
P="$(mktemp -d)"; REAL_PY="$(command -v python3)"
printf '#!/bin/bash\necho "$*" >> "%s/py.log"\nexec "%s" "$@"\n' "$P" "$REAL_PY" > "$P/python3"; chmod +x "$P/python3"
hook() { printf '{"session_id":"sess-1","tool_name":"Bash","tool_input":{"command":"%s"}}' "${2:-ls}" | PATH="$P:$PATH" bin/inbox ${1+"$1"}; }
now() { date +%s; }
# setk <name> <epoch>: one state file, its mtime set long ago (a STATE.md touched now is newer than it)
setk() { mkdir -p "$ST/checkin"; printf '%s\n' "$2" > "$K.$1"; touch -t 202001010000 "$K.$1"; }
old_state() { touch -t 202001010000 "$SM"; }
due() { rm -f "$K".*; setk start $(( $(now) - 31 * 60 )); setk seen $(( $(now) - 60 )); old_state; }
events() { [ -f "$LOG" ] && cat "$LOG"; }
wait_for() { for _ in $(seq 1 100); do eval "$1" && return 0; sleep 0.1; done; return 1; }

# --- checkin_due_nudges ---
rm -f "$P/py.log"; out=$(hook projects/demo); assert_eq "$out" "" "checkin_due_nudges: the first call starts the clock, no nudge"
[ -f "$K.start" ] && [ -f "$K.seen" ] || fail "checkin_due_nudges: period start and last call recorded"
due; out=$(hook projects/demo)
[ -n "$out" ] || fail "checkin_due_nudges: no nudge after 31 min of work"
printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin)["hookSpecificOutput"]; assert d["hookEventName"]=="PostToolUse"; t=d["additionalContext"]; print(t)' > "$P/ctx" \
  || fail "checkin_due_nudges: the nudge is PostToolUse additionalContext JSON: $out"
assert_contains "$P/ctx" "$HUB/projects/demo/STATE.md" "checkin_due_nudges: names the folder's STATE.md"
assert_contains "$P/ctx" "$HUB/bin/notify main \"<progress, next step, blocker if any>\"" "checkin_due_nudges: the note to main"
grep -qi "commit" "$P/ctx" || fail "checkin_due_nudges: says not to commit the hub"
[ -f "$K.nudged" ] || fail "checkin_due_nudges: the nudge is recorded"
# a call that mentions a push goes to python for its event, never nudged; the next call is
due; out=$(hook projects/demo "git push origin main"); printf '%s' "$out" | grep -q "STATE.md" && fail "checkin_due_nudges: a push call is not nudged"
out=$(hook projects/demo); printf '%s' "$out" | grep -q "STATE.md" || fail "checkin_due_nudges: nudged on the call after a push"
# a hub path with a quote is escaped for JSON
QH="$(mktemp -d)/a\"b"; mkdir -p "$QH"; (cd "$HUB" && tar cf - bin) | (cd "$QH" && tar xf -); mkdir -p "$QH/projects/demo"; echo x > "$QH/projects/demo/STATE.md"
touch -t 202001010000 "$QH/projects/demo/STATE.md"; due
out=$(printf '{"session_id":"sess-1"}' | HUB="$QH" "$QH/bin/inbox" projects/demo)
printf '%s' "$out" | python3 -c 'import json,sys; t=json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"]; assert sys.argv[1]+"/projects/demo/STATE.md" in t' "$QH" \
  || fail "checkin_due_nudges: a hub path with a quote stays valid JSON: $out"

# --- checkin_not_early ---
rm -f "$K".*; setk start $(( $(now) - 29 * 60 )); setk seen $(( $(now) - 60 )); old_state; rm -f "$P/py.log"
out=$(hook projects/demo); assert_eq "$out" "" "checkin_not_early: 29 min of work, no nudge"
[ -e "$P/py.log" ] && fail "checkin_not_early: the cheap path started python: $(cat "$P/py.log")"
due; hook projects/demo >/dev/null; rm -f "$P/py.log"
out=$(hook projects/demo); assert_eq "$out" "" "checkin_not_early: nudged once per period, not twice"
out=$(hook projects/demo); assert_eq "$out" "" "checkin_not_early: still not twice"
[ -e "$P/py.log" ] && fail "checkin_not_early: a repeat call started python: $(cat "$P/py.log")"
# an idle gap (no call for N minutes) is not work: the clock restarts
rm -f "$K".*; setk start $(( $(now) - 120 * 60 )); setk seen $(( $(now) - 40 * 60 )); old_state
out=$(hook projects/demo); assert_eq "$out" "" "checkin_not_early: after an idle gap the clock restarts"
read -r s < "$K.start"; [ $(( $(now) - s )) -lt 5 ] || fail "checkin_not_early: period start reset after the idle gap"

# --- checkin_resets ---
# a STATE.md change is a checkpoint
due; touch "$SM"; out=$(hook projects/demo); assert_eq "$out" "" "checkin_resets: STATE.md changed, no nudge"
read -r s < "$K.start"; [ $(( $(now) - s )) -lt 5 ] || fail "checkin_resets: a STATE.md change restarts the clock"
# a note to main from inside the folder's focus session is a checkpoint (recorded with checkin: true)
S="$(mktemp -d)"
printf '#!/bin/bash\n"$HUB/bin/notify" main "login form wired; next: tests" >/dev/null 2>&1; touch "$AGENT_STATE/sent"\nexec sleep 30\n' > "$S/claude-note"; chmod +x "$S/claude-note"
due; f=$(WORK_NO_OPEN=1 bin/work --force --claude claude-note projects/demo 2>/dev/null | sed -n 's/^launcher: //p'); [ -x "$f" ] || fail "checkin_resets: launcher written"
PATH="$S:$PATH" bash "$f" & lp=$!
wait_for '[ -e "$ST/sent" ]' || fail "checkin_resets: the session sent its note"
read -r s < "$K.start"; [ $(( $(now) - s )) -lt 10 ] || fail "checkin_resets: a note to main from the session restarts the clock"
out=$(hook projects/demo); assert_eq "$out" "" "checkin_resets: no nudge right after the note"
kill "$(pgrep -P "$lp" | head -1)" 2>/dev/null; wait "$lp" 2>/dev/null
# a note sent from outside a session (bin/monitor, bin/work) is not a checkpoint
due; bin/notify --from projects/demo main "monitor alert" >/dev/null || fail "checkin_resets: outside note written"
read -r s < "$K.start"; [ $(( $(now) - s )) -ge 1800 ] || fail "checkin_resets: a note from outside the session does not reset"

# --- checkin_event_contract ---
python3 - "$LOG" <<'PY' || fail "checkin_event_contract: checkin field on notes"
import json, sys
ev = [json.loads(l) for l in open(sys.argv[1])]
inside = [e for e in ev if e["kind"] == "note" and e["text"].startswith("login form wired")]
outside = [e for e in ev if e["kind"] == "note" and e["text"] == "monitor alert"]
assert inside and inside[-1]["from"] == "projects/demo" and inside[-1].get("checkin") is True, inside
assert outside and "checkin" not in outside[-1], outside
PY
ST="$ST" H="$HUB" python3 -I bin/events.py write --auto --from projects/demo --to main --kind idle --text x --checkin
tail -1 "$LOG" | grep -q checkin && fail "checkin_event_contract: checkin only on notes"
ST="$ST" H="$HUB" python3 -I bin/events.py write --auto --from projects/demo --to main --kind quiet --text "quiet 40 min: test" || fail "checkin_event_contract: quiet is a kind"
C=.ade/context/events.md
grep -q '`quiet`' "$C" || fail "checkin_event_contract: quiet in events.md"
grep -q 'checkin: true' "$C" || fail "checkin_event_contract: checkin: true in events.md"
grep -q 'HUB_CHECKIN_MINUTES' "$C" || fail "checkin_event_contract: the config key in events.md"
# the main session receives a quiet event
out=$(printf '{"session_id":"main-1"}' | bin/inbox); printf '%s' "$out" | grep -q "quiet 40 min" || fail "checkin_event_contract: main receives quiet: $out"
# and the chat forwarder sends it on
out=$(ST="$ST" H="$HUB" python3 -I bin/events.py outbox); printf '%s' "$out" | grep -q "\] quiet: .*quiet 40 min" || fail "checkin_event_contract: quiet is forwarded to the chat: $out"

# --- checkin_missed_reported ---
quiets() { grep -c '"kind": *"quiet"' "$LOG"; }
printf '#!/bin/bash\n"$HUB/bin/changes" projects/demo </dev/null >/dev/null 2>&1; touch "$AGENT_STATE/busy"\nexec sleep 60\n' > "$S/claude-busy"; chmod +x "$S/claude-busy"
rm -f "$ST/busy"; f=$(WORK_NO_OPEN=1 bin/work --force --claude claude-busy projects/demo 2>/dev/null | sed -n 's/^launcher: //p')
PATH="$S:$PATH" bash "$f" & lp=$!
wait_for '[ -e "$ST/busy" ]' || fail "checkin_missed_reported: the session is busy"
E="$ST/sessions/demo.$lp"; grep -q '^status=busy' "$E" || fail "checkin_missed_reported: entry busy: $(cat "$E")"
q0=$(quiets)
# the turn (last=, set when the status turns busy) began 40 minutes ago
setlast() { sed -i.bak "s/^last=.*/last=$(date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ)/" "$E"; rm -f "$E.bak"; }
setlast $(( $(now) - 40 * 60 ))
# nudged 5 minutes ago: not yet
rm -f "$K".*; setk start $(( $(now) - 35 * 60 )); setk nudged $(( $(now) - 5 * 60 )); setk seen $(( $(now) - 60 )); old_state
bin/checkin --missed; assert_eq "$?" "0" "checkin_missed_reported: exit 0"; assert_eq "$(quiets)" "$q0" "checkin_missed_reported: 5 min after the nudge is not missed"
# nudged 11 minutes ago, STATE.md touched since: a checkpoint, not missed
setk nudged $(( $(now) - 11 * 60 )); touch "$SM"
bin/checkin --missed; assert_eq "$(quiets)" "$q0" "checkin_missed_reported: STATE.md written after the nudge"
# nudged 11 minutes ago, nothing since: one quiet event to main
old_state; bin/checkin --missed; assert_eq "$(quiets)" "$((q0 + 1))" "checkin_missed_reported: missed check-in reported"
tail -1 "$LOG" | python3 -c 'import json,sys; e=json.load(sys.stdin); assert e["kind"]=="quiet" and e["from"]=="projects/demo" and e["to"]=="main", e; assert e["text"].startswith("quiet 35 min:") and "nudge" in e["text"] and "last STATE: wiring the login form" in e["text"], e' \
  || fail "checkin_missed_reported: quiet event fields: $(tail -1 "$LOG")"
bin/checkin --missed; assert_eq "$(quiets)" "$((q0 + 1))" "checkin_missed_reported: not repeated for the same nudge"
# a nudge from an earlier turn: a new turn began since, so not missed
setk quiet 0; setlast $(( $(now) - 60 ))
bin/checkin --missed; assert_eq "$(quiets)" "$((q0 + 1))" "checkin_missed_reported: a nudge before this turn is not missed"
# stuck at a prompt: no hook call and no status change for N minutes
rm -f "$K".*; setk start $(( $(now) - 40 * 60 )); setk seen $(( $(now) - 31 * 60 )); setk quiet $(( $(now) - 60 * 60 ))
setlast $(( $(now) - 31 * 60 ))
bin/checkin --missed; assert_eq "$(quiets)" "$((q0 + 2))" "checkin_missed_reported: a stuck session reported"
tail -1 "$LOG" | grep -q 'quiet 31 min: no hook activity' || fail "checkin_missed_reported: stuck reason: $(tail -1 "$LOG")"
bin/checkin --missed; assert_eq "$(quiets)" "$((q0 + 2))" "checkin_missed_reported: stuck not repeated until activity resumes"
# recent hook activity: not stuck
setk seen $(( $(now) - 60 )); setk quiet 0; bin/checkin --missed; assert_eq "$(quiets)" "$((q0 + 2))" "checkin_missed_reported: an active session is not stuck"
# the 30-minute monitor job runs the check (nothing new scheduled)
setk seen $(( $(now) - 31 * 60 )); setk quiet 0
MONITOR_QUIET=1 bin/monitor >/dev/null 2>&1; assert_eq "$(quiets)" "$((q0 + 3))" "checkin_missed_reported: bin/monitor runs the check"
grep -rq "checkin" launchd/ bin/schedule 2>/dev/null && fail "checkin_missed_reported: nothing new is scheduled"
# an idle session is never reported
sed -i.bak 's/^status=.*/status=idle/' "$E"; rm -f "$E.bak"; setk quiet 0
bin/checkin --missed; assert_eq "$(quiets)" "$((q0 + 3))" "checkin_missed_reported: an idle session is not reported"
kill "$(pgrep -P "$lp" | head -1)" 2>/dev/null; wait "$lp" 2>/dev/null
bin/checkin 2>/dev/null; assert_eq "$?" "2" "checkin_missed_reported: usage error exit 2"

# --- checkin_root_exempt ---
rm -rf "$ST/checkin"; out=$(hook); printf '%s' "$out" | grep -q "hub check-in" && fail "checkin_root_exempt: the hub root is not nudged: $out"
[ -e "$ST/checkin" ] && fail "checkin_root_exempt: no check-in state for the hub root"
due; out=$(HUB_CHECKIN_MINUTES=0 hook projects/demo); assert_eq "$out" "" "checkin_root_exempt: 0 turns the nudge off"
assert_eq "$(. bin/lib.sh; checkin_minutes)" "30" "checkin_root_exempt: default 30"
assert_eq "$(HUB_CHECKIN_MINUTES=abc bash -c '. bin/lib.sh; checkin_minutes')" "30" "checkin_root_exempt: an invalid value counts as 30"
assert_eq "$(HUB_CHECKIN_MINUTES=045 bash -c '. bin/lib.sh; checkin_minutes')" "45" "checkin_root_exempt: base 10"
q1=$(quiets); HUB_CHECKIN_MINUTES=0 bin/checkin --missed; assert_eq "$(quiets)" "$q1" "checkin_root_exempt: 0 reports nothing"
out=$(PATH=/usr/bin:/bin DOCTOR_OFFLINE=1 bin/doctor 2>/dev/null); echo "$out" | grep -qE "^OK +check-in +every 30 min \(HUB_CHECKIN_MINUTES\)" || fail "checkin_root_exempt: doctor shows the value: $out"
out=$(HUB_CHECKIN_MINUTES=0 PATH=/usr/bin:/bin DOCTOR_OFFLINE=1 bin/doctor 2>/dev/null); echo "$out" | grep -qE "^OK +check-in +off \(HUB_CHECKIN_MINUTES=0\)" || fail "checkin_root_exempt: doctor shows off"
out=$(HUB_CHECKIN_MINUTES=x9 PATH=/usr/bin:/bin DOCTOR_OFFLINE=1 bin/doctor 2>/dev/null); echo "$out" | grep -qE "^WARN +check-in .*30" || fail "checkin_root_exempt: doctor warns on a non-number"
D="$(mktemp -d)/h"; bin/init --persona devops-sre --client X --owner Y --dest "$D" >/dev/null 2>&1 || fail "checkin_root_exempt: bin/init"
assert_contains "$D/hub.conf" "HUB_CHECKIN_MINUTES=30" "checkin_root_exempt: hub.conf carries the key"

# --- checkin_sync_follows ---
git config core.hooksPath .githooks; git add -A >/dev/null 2>&1; git commit -q --no-verify -m base >/dev/null 2>&1
G="$(mktemp -d)"; printf '#!/bin/bash\nexit 0\n' > "$G/gitleaks"; chmod +x "$G/gitleaks"
B="$(mktemp -d)/hub.git"; git init -q --bare "$B"; git remote add origin "$B" 2>/dev/null || git remote set-url origin "$B"
git push -q -u origin HEAD 2>/dev/null || fail "checkin_sync_follows: seed push"
h=$(git rev-parse HEAD); n=$(git rev-list --count HEAD)
printf '#!/bin/bash\necho "- checkpoint: tests green" >> "$HUB/projects/demo/STATE.md"\n"$HUB/bin/notify" main "tests green; next: review" >/dev/null 2>&1; touch "$AGENT_STATE/cp"\nexec sleep 30\n' > "$S/claude-cp"; chmod +x "$S/claude-cp"
rm -f "$ST/cp"; f=$(WORK_NO_OPEN=1 bin/work --force --claude claude-cp projects/demo 2>/dev/null | sed -n 's/^launcher: //p')
PATH="$S:$PATH" bash "$f" & lp=$!
wait_for '[ -e "$ST/cp" ]' || fail "checkin_sync_follows: the checkpoint ran"
hook projects/demo >/dev/null; bin/checkin --missed
assert_eq "$(git rev-parse HEAD)" "$h" "checkin_sync_follows: no commit from the session, the hook or the check"
PATH="$G:$PATH" bin/sync --auto; assert_eq "$?" "0" "checkin_sync_follows: bin/sync --auto"
assert_eq "$(git rev-list --count HEAD)" "$((n + 1))" "checkin_sync_follows: one sync commit, no extra"
git show --name-only --pretty=format: HEAD | grep -qx projects/demo/STATE.md || fail "checkin_sync_follows: the checkpoint's STATE.md synced"
assert_eq "$(git --git-dir="$B" rev-parse HEAD)" "$(git rev-parse HEAD)" "checkin_sync_follows: pushed"
kill "$(pgrep -P "$lp" | head -1)" 2>/dev/null; wait "$lp" 2>/dev/null
echo ok
