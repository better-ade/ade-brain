#!/bin/bash
# bin/session-end run without Claude Code's hook: bounded stdin, --since, the sync lock, the session-end log.
. "$(dirname "$0")/helpers.sh"
export AGENT_LOCK_WAIT=3 AGENT_HOOK_LOCK_WAIT=3
KIDS=""; trap 'for k in $KIDS; do kill "$k" 2>/dev/null; done' EXIT
f() { fail "$CHECK: $*"; }
# a fresh hub per check: projects/demo with one code checkout, everything committed
setup() {
  make_hub; cd "$HUB"; unset AGENT_SYNC_CMD
  export AGENT_STATE="$(mktemp -d)" AGENT_SESSION_END_LOG="$(mktemp -d)/session-end.log"
  K="$AGENT_SYNC_LOCK"; J="journal/$(date -u +%Y-%m-%d).md"; NOW=$(date +%s)
  bin/new projects/demo >/dev/null
  R="$(mktemp -d)/demo-code"; mkdir -p "$R" && git -C "$R" init -q && git -C "$R" config user.email t@t && git -C "$R" config user.name t
  printf '| demo-code | %s | main | Owner | none |\n' "$R" >> projects/demo/ACCESS.md
  git add -A >/dev/null 2>&1; git commit -q --no-verify -m base >/dev/null 2>&1
}
# code_commit <message> <epoch>: a commit in the demo checkout dated <epoch>
code_commit() { echo "$1" >> "$R/f"; git -C "$R" add f; GIT_AUTHOR_DATE="$2 +0000" GIT_COMMITTER_DATE="$2 +0000" git -C "$R" commit -qm "$1"; }
iso() { python3 -c 'import sys, time; print(time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(int(sys.argv[1]))))' "$1"; }
# run_held <secs> <cmd...>: cmd's stdin is a pipe whose writer never closes; killed after <secs>. RC = its status, 124 = killed.
run_held() {
  local s="$1" p w i=0 wp; shift; wp="$(mktemp -d)/writer"   # a real pipe: script(1) refuses a fifo as stdin
  { sleep 60 2>/dev/null & echo $! > "$wp"; wait; } | "$@" > "$AGENT_STATE/out" 2> "$AGENT_STATE/err" & p=$!
  while [ ! -s "$wp" ]; do sleep 0.1; done; w=$(cat "$wp"); KIDS="$KIDS $w"
  while kill -0 "$p" 2>/dev/null && [ $i -lt $((s * 5)) ]; do sleep 0.2; i=$((i + 1)); done
  RC=; kill -0 "$p" 2>/dev/null && { pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; RC=124; }
  kill "$w" 2>/dev/null   # bash waits for the whole pipeline, so the writer goes first
  wait "$p" 2>/dev/null; i=$?; [ -n "$RC" ] || RC=$i
}
# hold_lock: the sync lock held by a live process (pid in $SP)
hold_lock() { mkdir "$K"; sleep 30 & SP=$!; KIDS="$KIDS $SP"; echo "$SP" > "$K/pid"; }
committed() { git log -1 --pretty=%s | grep -q "^session projects/demo "; }
hook() { echo '{"transcript_path":""}' | bin/session-end "$@"; }
# stubs <brain-secs> <brain-exit> <sync-secs> <sync-exit>: bin/brain and the sync command (AGENT_SYNC_CMD, auto sync
# on) sleep, then write their markers ($M/brain.mark, $M/sync.mark: a date +%s); the sync stub notes whether the brain
# marker was already there ($M/order), the brain stub its session id ($M/sid; ps -o sess is
# always 0 on macOS, so python os.getsid) and that session leader's command ($M/leader)
stubs() {
  M="$AGENT_STATE"
  cat > bin/brain <<STUB
#!/bin/bash
python3 -c 'import os; print(os.getsid(0))' > "$M/sid.t"; ps -o command= -p "\$(cat "$M/sid.t")" > "$M/leader"; mv "$M/sid.t" "$M/sid"
sleep $1
date +%s > "$M/brain.mark"
exit $2
STUB
  printf '#!/bin/bash\nsleep %s\n[ -e "%s/brain.mark" ] && echo after > "%s/order"\ndate +%%s > "%s/sync.mark"\nexit %s\n' "$3" "$M" "$M" "$M" "$4" > "$M/sync-stub"
  chmod +x bin/brain "$M/sync-stub"; export AGENT_AUTO_SYNC=1 AGENT_SYNC_CMD="$M/sync-stub"
}
# poll <test>: true once <test> holds, polled for up to 30 s
poll() { local i=0; while [ $i -lt 150 ]; do eval "$1" && return 0; sleep 0.2; i=$((i + 1)); done; return 1; }
st() { bash -c '. "$1"; proc_start "$2"' _ "$HUB/bin/lib.sh" "$1"; }   # proc_start of a pid, from bin/lib.sh

CHECK=held_pipe_under_script_finishes; setup
echo more >> projects/demo/STATE.md
run_held 20 in_pty "$HUB/bin/session-end" projects/demo
[ "$RC" != 124 ] || f "still running after 20 s (stdin read never returned)"
committed || f "folder not committed"

CHECK=never_closing_pipe_finishes; setup
echo more >> projects/demo/STATE.md
run_held 20 bin/session-end projects/demo
[ "$RC" != 124 ] || f "still running after 20 s"
assert_eq "$RC" 0 "$CHECK: exit"
committed || f "folder not committed"
assert_eq "$(cat "$AGENT_STATE/out")" "" "$CHECK: the hook path prints nothing"

CHECK=hook_start_from_transcript; setup
code_commit oldfix $((NOW - 3*3600)); code_commit newfix $((NOW - 600))
printf '{"timestamp":"%s"}\n' "$(iso $((NOW - 3600)))" > "$AGENT_STATE/t.jsonl"
echo "{\"transcript_path\":\"$AGENT_STATE/t.jsonl\"}" | bin/session-end projects/demo
grep -q newfix "$J" 2>/dev/null || f "commit after the transcript start not journaled"
grep -q oldfix "$J" && f "commit before the transcript start journaled"

CHECK=since_sets_exact_start; setup
code_commit oldfix $((NOW - 3*3600)); code_commit newfix $((NOW - 600))
printf '{"timestamp":"%s"}\n' "$(iso $((NOW - 4*3600)))" > "$AGENT_STATE/t.jsonl"   # earlier than --since: --since wins
echo "{\"transcript_path\":\"$AGENT_STATE/t.jsonl\"}" | bin/session-end projects/demo --since $((NOW - 3600)); assert_eq "$?" 0 "$CHECK: exit"
grep -q newfix "$J" 2>/dev/null || f "commit after --since not journaled"
grep -q oldfix "$J" && f "commit before --since journaled"

CHECK=since_rejects_non_epoch; setup
echo more >> projects/demo/STATE.md; h=$(git rev-parse HEAD)
bin/session-end projects/demo --since abc < /dev/null 2> "$AGENT_STATE/err"; assert_eq "$?" 2 "$CHECK: exit"
[ -s "$AGENT_STATE/err" ] || f "no message on stderr"
assert_eq "$(git rev-parse HEAD)" "$h" "$CHECK: committed anyway"
bin/session-end projects/demo --since < /dev/null 2>/dev/null; assert_eq "$?" 2 "$CHECK: --since without a value"

CHECK=unknown_argument_refused; setup
echo more >> projects/demo/STATE.md; h=$(git rev-parse HEAD)
for a in "--launch x" "--bogus" "projects/demo extra"; do
  bin/session-end projects/demo $a < /dev/null 2> "$AGENT_STATE/err"; assert_eq "$?" 2 "$CHECK: [$a] exit"
  grep -q "unknown argument" "$AGENT_STATE/err" || f "[$a]: no 'unknown argument' on stderr"
done
bin/session-end projects/demo --launch x < /dev/null 2>&1 | grep -q -- "--launch" || f "message does not name --launch"
assert_eq "$(git rev-parse HEAD)" "$h" "$CHECK: committed anyway"

CHECK=waits_for_lock_then_commits; setup
echo more >> projects/demo/STATE.md; hold_lock; (sleep 1; date +%s > "$AGENT_STATE/released"; rm -rf "$K") & r=$!
AGENT_HOOK_LOCK_WAIT=5 hook projects/demo; rc=$?; wait $r
assert_eq "$rc" 0 "$CHECK: exit"; committed || f "folder not committed"
[ "$(git log -1 --format=%ct)" -ge "$(cat "$AGENT_STATE/released")" ] || f "committed before the lock was released"
[ -d "$K" ] && f "lock left behind"

CHECK=busy_lock_skips_and_journals; setup
code_commit newfix $((NOW - 600)); echo more >> projects/demo/STATE.md; h=$(git rev-parse HEAD); hold_lock
AGENT_HOOK_LOCK_WAIT=3 hook projects/demo; assert_eq "$?" 0 "$CHECK: exit"
assert_eq "$(git rev-parse HEAD)" "$h" "$CHECK: committed under a busy lock"
git status --porcelain | grep -q "projects/demo/STATE.md" || f "hub file not left uncommitted"
assert_eq "$(grep -c "sync lock busy" "$J" 2>/dev/null)" 1 "$CHECK: journal lines about the busy lock"
grep "sync lock busy" "$J" | grep -q newfix || f "skip line does not list the commits"
grep -q "hub commit skipped: sync lock busy" "$J" || f "skip line does not say the hub commit was skipped: $(grep "sync lock busy" "$J")"
[ -d "$K" ] || f "other process's lock removed"; assert_eq "$(cat "$K/pid")" "$SP" "$CHECK: lock owner"

CHECK=stale_lock_removed; setup
echo more >> projects/demo/STATE.md; mkdir "$K"; sh -c 'echo $$ > '"$K"'/pid'   # owner gone
hook projects/demo; committed || f "dead owner: not committed"; [ -d "$K" ] && f "dead owner's lock kept"
echo more >> projects/demo/STATE.md; h=$(git rev-parse HEAD)
mkdir "$K"; : > "$K/pid"; touch -t 202001010000 "$K"                          # empty pid file, older than the grace
hook projects/demo; [ "$(git rev-parse HEAD)" != "$h" ] || f "old pid-less lock: not committed"; [ -d "$K" ] && f "old pid-less lock kept"
assert_eq "$(grep -c "removed stale lock" "$AGENT_SESSION_END_LOG" 2>/dev/null)" 2 "$CHECK: stale locks logged"

CHECK=release_before_auto_sync; setup
S="$(mktemp -d)"; printf '#!/bin/bash\nexit 0\n' > "$S/gitleaks"; chmod +x "$S/gitleaks"
git config core.hooksPath .githooks; echo more >> projects/demo/STATE.md; echo m >> memory/MEMORY.md
printf '#!/bin/bash\nif [ -d "%s" ]; then echo held; else echo free; fi > "%s"\n' "$K" "$AGENT_STATE/at-brain" > bin/brain
PATH="$S:$PATH" AGENT_AUTO_SYNC=1 hook projects/demo; assert_eq "$?" 0 "$CHECK: exit"
# both steps run detached: wait for the brain marker and the sync's log line
poll '[ -s "$AGENT_STATE/at-brain" ] && grep -qE "synced:|skipped:|failed:|refused:" "$AGENT_SYNC_LOG" 2>/dev/null'
grep -q "skipped: another sync is running" "$AGENT_SYNC_LOG" 2>/dev/null && f "the follow-on sync found the lock held"
grep -q "synced:" "$AGENT_SYNC_LOG" 2>/dev/null || f "the follow-on sync did not sync: $(cat "$AGENT_SYNC_LOG" 2>/dev/null)"
assert_eq "$(cat "$AGENT_STATE/at-brain" 2>/dev/null)" free "$CHECK: lock state when the step before auto_sync ran"

CHECK=since_writes_session_end_log; setup
S0=$((NOW - 3600)); L="$AGENT_SESSION_END_LOG"; printf '#!/bin/bash\nexit 0\n' > bin/brain   # no bg step failed line
echo more >> projects/demo/STATE.md; bin/session-end projects/demo --since $S0 < /dev/null
bin/session-end projects/demo --since $S0 < /dev/null
hold_lock; echo more >> projects/demo/STATE.md; bin/session-end projects/demo --since $S0 < /dev/null; kill $SP; rm -rf "$K"
bin/session-end projects/demo --since 12x < /dev/null 2>/dev/null
assert_eq "$(wc -l < "$L" | tr -d ' ')" 4 "$CHECK: one line per run"
sed -n 1p "$L" | grep -q "projects/demo.*$S0.* committed$" || f "line 1: $(sed -n 1p "$L")"
sed -n 2p "$L" | grep -q "projects/demo.*$S0.* nothing to commit$" || f "line 2: $(sed -n 2p "$L")"
sed -n 3p "$L" | grep -q "projects/demo.*$S0.* skipped: sync lock busy$" || f "line 3: $(sed -n 3p "$L")"
sed -n 4p "$L" | grep -q "projects/demo.* refused: " || f "line 4: $(sed -n 4p "$L")"
sed -n 1p "$L" | grep -qE "^20[0-9]{2}-[01][0-9]-[0-3][0-9]T[0-9:]+Z " || f "no UTC timestamp: $(sed -n 1p "$L")"
before=$(wc -l < "$L"); hook projects/demo; assert_eq "$(wc -l < "$L")" "$before" "$CHECK: hook path wrote an outcome line"
unset AGENT_SESSION_END_LOG; bin/session-end projects/demo --since $S0 < /dev/null
grep -q "nothing to commit" "$AGENT_STATE/logs/session-end.log" 2>/dev/null || f "default log path not used"

CHECK=lock_wait_default_is_30; setup
assert_eq "$(env -u AGENT_LOCK_WAIT bash -c '. bin/lib.sh; sync_lock_wait')" 30 "$CHECK: default"
assert_eq "$(AGENT_LOCK_WAIT=7 bash -c '. bin/lib.sh; sync_lock_wait')" 7 "$CHECK: AGENT_LOCK_WAIT"

CHECK=hook_path_always_exits_zero; setup
echo more >> projects/demo/STATE.md; hold_lock
out=$(hook projects/demo); assert_eq "$?" 0 "$CHECK: busy"; assert_eq "$out" "" "$CHECK: busy is quiet"
kill $SP; wait $SP 2>/dev/null                                                   # now stale: owner gone
out=$(hook projects/demo); assert_eq "$?" 0 "$CHECK: stale"; assert_eq "$out" "" "$CHECK: stale is quiet"
out=$(hook projects/demo); assert_eq "$?" 0 "$CHECK: nothing to commit"; assert_eq "$out" "" "$CHECK: nothing to commit is quiet"
CHECK=only_owner_releases_lock; setup
# while session-end holds the lock, another live process's pid lands in the pid file (from the pre-commit hook):
# the lock is no longer session-end's, so it must leave it
sleep 30 & OP=$!; KIDS="$KIDS $OP"; D="$(mktemp -d)"
printf '#!/bin/bash\necho %s > "%s/pid"\n' "$OP" "$K" > "$D/pre-commit"; chmod +x "$D/pre-commit"; git config core.hooksPath "$D"
echo more >> projects/demo/STATE.md; hook projects/demo
committed || f "folder not committed"
[ -d "$K" ] || f "lock removed although its pid file named another live process"
assert_eq "$(cat "$K/pid" 2>/dev/null)" "$OP" "$CHECK: lock owner"

CHECK=stale_takeover_one_holder; setup
# several takers on one dead-pid lock at once: each round exactly one of them holds it, and nobody loses it mid-hold
B="$(mktemp -d)"; bad=""
for it in $(seq 1 40); do
  k="$B/lock$it"; o="$B/o$it"; mkdir "$k"; sh -c 'echo $$ > '"$k"'/pid'; : > "$o"
  for t in 1 2 3 4; do
    bash -c '. "$1"; while [ ! -e "$2.go" ]; do :; done; sleep 0.00$((RANDOM % 10))
      if sync_lock_take "$2" 0; then echo won >> "$3"; sleep 0.3
        [ "$(cat "$2/pid" 2>/dev/null)" = "$$" ] || echo lost >> "$3"; sync_lock_release "$2"; fi' _ "$HUB/bin/lib.sh" "$k" "$o" 2>/dev/null &
  done
  sleep 0.1; touch "$k.go"; wait
  [ "$(grep -c won "$o")" = 1 ] && ! grep -q lost "$o" || bad="$bad $it($(grep -c won "$o") won, $(grep -c lost "$o") lost)"
done
[ -z "$bad" ] || f "rounds without exactly one holder:$bad"
mkdir "$B/g"; sh -c 'echo $$ > '"$B/g"'/pid'; mkdir "$B/g.gc"; touch -t 202001010000 "$B/g.gc"   # a guard left by a killed run
bash -c '. "$1"; sync_lock_take "$2" 0' _ "$HUB/bin/lib.sh" "$B/g" || f "an expired takeover guard blocks the lock for good"

CHECK=lock_wait_is_at_least_w; setup
# a whole-second clock that is about to tick (x.9 s) must not shorten the wait: a busy lock is waited on >= W seconds
hold_lock
el=$(bash -c '. "$1"; ms() { python3 -c "import time; print(int(time.time() * 1000))"; }; b=$(ms)
  date() { if [ "$1" = +%s ]; then echo $(( (1000900 + $(ms) - b) / 1000 )); else command date "$@"; fi; }
  b=$(ms); s=$b; sync_lock_take "$2" 2 && echo took; echo $(( $(ms) - s ))' _ "$HUB/bin/lib.sh" "$K")
case "$el" in took*) f "took a live lock";; esac
[ "$el" -ge 2000 ] || f "busy lock waited on for ${el} ms, want >= 2000"

CHECK=since_digit_count; setup
echo more >> projects/demo/STATE.md; h=$(git rev-parse HEAD)
for v in 12345678 123456789012; do
  bin/session-end projects/demo --since $v < /dev/null 2>/dev/null; assert_eq "$?" 2 "$CHECK: [$v] exit"
done
assert_eq "$(git rev-parse HEAD)" "$h" "$CHECK: committed anyway"
bin/session-end projects/demo --since 123456789 < /dev/null; assert_eq "$?" 0 "$CHECK: 9 digits accepted"

CHECK=since_not_echoed_into_log; setup
L="$AGENT_SESSION_END_LOG"
bin/session-end projects/demo --since 'evil' < /dev/null 2>/dev/null
bin/session-end projects/demo --since "$(printf '12\nforged line')" < /dev/null 2>/dev/null
assert_eq "$(wc -l < "$L" | tr -d ' ')" 2 "$CHECK: one line per run"
grep -q -e evil -e forged "$L" && f "raw --since value in the log: $(cat "$L")"
grep -c " refused: " "$L" | grep -qx 2 || f "refusals not logged: $(cat "$L")"

CHECK=refused_commit_logged; setup
D="$(mktemp -d)"; printf '#!/bin/bash\nexit 1\n' > "$D/pre-commit"; chmod +x "$D/pre-commit"; git config core.hooksPath "$D"
echo more >> projects/demo/STATE.md; h=$(git rev-parse HEAD)
bin/session-end projects/demo --since $((NOW - 3600)) < /dev/null; assert_eq "$?" 0 "$CHECK: exit"
assert_eq "$(git rev-parse HEAD)" "$h" "$CHECK: committed through a refusing hook"
tail -1 "$AGENT_SESSION_END_LOG" | grep -q " failed: commit refused$" || f "log: $(tail -1 "$AGENT_SESSION_END_LOG")"
hook projects/demo; assert_eq "$?" 0 "$CHECK: hook path exit"

CHECK=stdin_read_capped; setup
# a writer that floods stdin: only about 1 MB is read, so the run is not slowed by the flood
echo more >> projects/demo/STATE.md; s=$(date +%s)
yes 2>/dev/null | bin/session-end projects/demo; el=$(( $(date +%s) - s ))
committed || f "folder not committed"
[ "$el" -le 5 ] || f "took ${el} s with a flooding stdin"
CHECK=live_old_lock_kept; setup
echo more >> projects/demo/STATE.md; h=$(git rev-parse HEAD); hold_lock; touch -t 202001010000 "$K"   # pid only, old
hook projects/demo; assert_eq "$?" 0 "$CHECK: exit"
assert_eq "$(git rev-parse HEAD)" "$h" "$CHECK: committed under a live owner's old lock"
git status --porcelain | grep -q "projects/demo/STATE.md" || f "hub file not left uncommitted"
grep -q "hub commit skipped: sync lock busy" "$J" 2>/dev/null || f "no busy-lock journal line"
[ -d "$K" ] || f "live owner's old lock removed"; assert_eq "$(cat "$K/pid" 2>/dev/null)" "$SP" "$CHECK: lock owner"

CHECK=fresh_pidless_lock_kept; setup
echo more >> projects/demo/STATE.md; h=$(git rev-parse HEAD); mkdir "$K"   # no pid file yet, created just now
hook projects/demo; assert_eq "$?" 0 "$CHECK: exit"
assert_eq "$(git rev-parse HEAD)" "$h" "$CHECK: committed under a fresh pid-less lock"
[ -d "$K" ] || f "fresh pid-less lock removed"

CHECK=lock_grace_is_10; setup
assert_eq "$(bash -c '. bin/lib.sh; sync_lock_grace' 2>/dev/null)" 10 "$CHECK: grace"

CHECK=hook_returns_within_bound; setup; stubs 8 0 8 0
echo more >> projects/demo/STATE.md; s=$(date +%s)
out=$(echo '{"transcript_path":""}' | bin/session-end projects/demo 2>&1 | cat); el=$(( $(date +%s) - s ))
[ -d "$K" ] && f "lock still there when the hook returned"
[ "$el" -lt 5 ] || f "hook took $el s"
assert_eq "$out" "" "$CHECK: the hook prints nothing"
committed || f "folder not committed"

CHECK=background_runs_to_completion
poll '[ -s "$M/brain.mark" ]' || f "brain marker never appeared"
poll '[ -s "$M/sync.mark" ]' || f "sync marker never appeared"
assert_eq "$(cat "$M/order" 2>/dev/null)" after "$CHECK: sync ran before the brain index finished"

CHECK=background_failure_logged; setup; stubs 0 3 0 1
out=$(hook projects/demo 2>&1); rc=$?; assert_eq "$rc" 0 "$CHECK: exit"; assert_eq "$out" "" "$CHECK: hook output"
L="$AGENT_SESSION_END_LOG"
poll '[ "$(grep -c "bg step failed: sync exit 1" "$L" 2>/dev/null)" = 1 ]' || f "no sync failure line: $(cat "$L" 2>/dev/null)"
assert_eq "$(grep -c "bg step failed: brain index exit 3$" "$L")" 1 "$CHECK: brain failure lines"
assert_eq "$(grep -c "bg step failed: sync exit 1$" "$L")" 1 "$CHECK: sync failure lines"

CHECK=since_runs_foreground; setup; stubs 1 0 1 0
echo more >> projects/demo/STATE.md; bin/session-end projects/demo --since $((NOW - 3600)) < /dev/null
[ -s "$M/brain.mark" ] || f "brain step not done when session-end returned"
[ -s "$M/sync.mark" ] || f "sync step not done when session-end returned"
grep -q "projects/demo since=$((NOW - 3600)) committed$" "$AGENT_SESSION_END_LOG" || f "outcome line: $(cat "$AGENT_SESSION_END_LOG")"
grep -q "bg step failed" "$AGENT_SESSION_END_LOG" && f "steps that succeeded logged a failure"
[ -d "$K" ] && f "lock left behind"

CHECK=hook_logs_nothing_on_success; setup; stubs 0 0 0 0
echo more >> projects/demo/STATE.md; hook projects/demo
poll '[ -s "$M/sync.mark" ]' || f "sync marker never appeared"; sleep 0.5
[ -s "$AGENT_SESSION_END_LOG" ] && f "log written: $(cat "$AGENT_SESSION_END_LOG")"

CHECK=background_own_session; setup; stubs 0 0 0 0
hook projects/demo; poll '[ -s "$M/sid" ]' || f "brain stub never ran"
[ "$(cat "$M/sid")" != "$(python3 -c 'import os, sys; print(os.getsid(int(sys.argv[1])))' $$)" ] || f "brain step ran in the test shell's session"
grep -q "session-end" "$M/leader" || f "the brain step's session is not led by the detached session-end: $(cat "$M/leader")"

CHECK=start_record_tz_independent; setup
# the taker and the judge may run under different TZ (a tool exporting TZ=UTC, launchd): the owner is still the owner
echo more >> projects/demo/STATE.md; h=$(git rev-parse HEAD); hold_lock
echo "$SP $(TZ=America/Toronto st "$SP")" > "$K/start"
TZ=UTC hook projects/demo; assert_eq "$?" 0 "$CHECK: exit"
assert_eq "$(git rev-parse HEAD)" "$h" "$CHECK: committed under the owner's lock"
assert_eq "$(cat "$K/pid" 2>/dev/null)" "$SP" "$CHECK: lock owner"

CHECK=lock_records_start; setup
B="$(mktemp -d)"
out=$(bash -c '. "$1"; sync_lock_take "$2/l" 0 || exit 1; echo "$$"; cat "$2/l/start"; cat "$2/l/pid"; proc_start $$' _ "$HUB/bin/lib.sh" "$B" 2>/dev/null)
p=$(echo "$out" | sed -n 1p); rec=$(echo "$out" | sed -n 2p)
assert_eq "${rec%% *}" "$p" "$CHECK: start record pid"
assert_eq "$(echo "$out" | sed -n 3p)" "$p" "$CHECK: pid file"
[ -n "$(echo "$out" | sed -n 4p)" ] || f "proc_start printed nothing"
assert_eq "${rec#* }" "$(echo "$out" | sed -n 4p)" "$CHECK: start record start"
bash -c '. "$1"; proc_start() { :; }; sync_lock_take "$2/m" 0' _ "$HUB/bin/lib.sh" "$B" || f "lock not taken without a start time"
[ -e "$B/m/start" ] && f "start record written without a start time"
[ -s "$B/m/pid" ] || f "no pid file without a start time"

CHECK=pid_reused_lock_removed; setup
echo more >> projects/demo/STATE.md; hold_lock; echo "$SP Mon Jan  1 00:00:00 2001" > "$K/start"
hook projects/demo; assert_eq "$?" 0 "$CHECK: exit"
committed || f "folder not committed"
assert_eq "$(grep -c "removed stale lock" "$AGENT_SESSION_END_LOG" 2>/dev/null)" 1 "$CHECK: removal logged"

CHECK=same_pid_same_start_kept; setup
echo more >> projects/demo/STATE.md; h=$(git rev-parse HEAD); hold_lock; echo "$SP $(st "$SP")" > "$K/start"
hook projects/demo; assert_eq "$?" 0 "$CHECK: exit"
assert_eq "$(git rev-parse HEAD)" "$h" "$CHECK: committed under the owner's lock"
grep -q "hub commit skipped: sync lock busy" "$J" 2>/dev/null || f "no busy-lock journal line"
assert_eq "$(cat "$K/pid" 2>/dev/null)" "$SP" "$CHECK: lock owner"

CHECK=old_format_judged_by_pid; setup
echo more >> projects/demo/STATE.md; h=$(git rev-parse HEAD); hold_lock; touch -t 202001010000 "$K"
hook projects/demo; assert_eq "$(git rev-parse HEAD)" "$h" "$CHECK: live pid: committed"
assert_eq "$(cat "$K/pid" 2>/dev/null)" "$SP" "$CHECK: live pid: lock owner"
rm -rf "$K"; mkdir "$K"; sh -c 'echo $$ > '"$K"'/pid'
hook projects/demo; committed || f "dead pid: not committed"; [ -d "$K" ] && f "dead pid: lock kept"

CHECK=rewritten_pid_judged_alone; setup
sleep 30 & A=$!; KIDS="$KIDS $A"; sleep 1.1; sleep 30 & SB=$!; KIDS="$KIDS $SB"
echo more >> projects/demo/STATE.md; h=$(git rev-parse HEAD)
mkdir "$K"; echo "$A $(st "$A")" > "$K/start"; echo "$SB" > "$K/pid"
hook projects/demo; assert_eq "$?" 0 "$CHECK: exit"
assert_eq "$(git rev-parse HEAD)" "$h" "$CHECK: committed under B's lock"
assert_eq "$(cat "$K/pid" 2>/dev/null)" "$SB" "$CHECK: lock owner"

CHECK=pidless_grace_still_applies; setup
echo more >> projects/demo/STATE.md; h=$(git rev-parse HEAD)
mkdir "$K"; echo abc > "$K/pid"; echo "$$ Mon Jan  1 00:00:00 2001" > "$K/start"
hook projects/demo; assert_eq "$?" 0 "$CHECK: fresh: exit"
assert_eq "$(git rev-parse HEAD)" "$h" "$CHECK: fresh: committed"; [ -d "$K" ] || f "fresh unusable-pid lock removed"
touch -t 202001010000 "$K"; hook projects/demo
committed || f "old unusable-pid lock: not committed"; [ -d "$K" ] && f "old unusable-pid lock kept"

CHECK=hook_lock_gives_up_5s; setup
echo more >> projects/demo/STATE.md; h=$(git rev-parse HEAD); hold_lock; s=$(date +%s)
echo '{"transcript_path":""}' | env -u AGENT_HOOK_LOCK_WAIT bin/session-end projects/demo; rc=$?; el=$(( $(date +%s) - s ))
assert_eq "$rc" 0 "$CHECK: exit"
[ "$el" -ge 4 ] && [ "$el" -le 9 ] || f "hook took $el s, want 4 to 9"
assert_eq "$(git rev-parse HEAD)" "$h" "$CHECK: committed under a busy lock"
grep -q "hub commit skipped: sync lock busy" "$J" 2>/dev/null || f "no busy-lock journal line"
assert_eq "$(cat "$K/pid" 2>/dev/null)" "$SP" "$CHECK: lock owner"

CHECK=since_waits_full_window; setup
echo more >> projects/demo/STATE.md; hold_lock; (sleep 8; rm -rf "$K") & r=$!; s=$(date +%s)
env -u AGENT_HOOK_LOCK_WAIT AGENT_LOCK_WAIT=12 bin/session-end projects/demo --since $((NOW - 3600)) < /dev/null; rc=$?
el=$(( $(date +%s) - s )); wait $r
assert_eq "$rc" 0 "$CHECK: exit"; committed || f "folder not committed"
grep -q "since=$((NOW - 3600)) committed$" "$AGENT_SESSION_END_LOG" || f "outcome: $(cat "$AGENT_SESSION_END_LOG")"
[ "$el" -ge 7 ] || f "took $el s, want >= 7"

CHECK=hook_lock_wait_default_is_5; setup
assert_eq "$(env -u AGENT_HOOK_LOCK_WAIT bash -c '. bin/lib.sh; sync_hook_lock_wait' 2>/dev/null)" 5 "$CHECK: default"
assert_eq "$(AGENT_HOOK_LOCK_WAIT=7 bash -c '. bin/lib.sh; sync_hook_lock_wait' 2>/dev/null)" 7 "$CHECK: AGENT_HOOK_LOCK_WAIT"
echo ok
