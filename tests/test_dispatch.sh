#!/bin/bash
# bin/dispatch (story C3): starts focus builders for ready BMAD tickets; fake `tickets next` (node), fake bin/work and bin/sessions
. "$(dirname "$0")/helpers.sh"
make_hub; cd "$HUB"
bin/new projects/demo >/dev/null
CK="$(mktemp -d)/demo-code"; mkdir -p "$CK/_bmad" && : > "$CK/_bmad/ade-runtime.mjs"   # the folder's checkout, with BMAD
printf '| demo-code | %s | main | Owner | none |\n' "$CK" >> projects/demo/ACCESS.md
S="$(mktemp -d)"; export S
ST="$(mktemp -d)"; export AGENT_STATE="$ST"   # dispatch lock and start markers live here, never in the real state dir
# fake node: logs its argv, prints $S/tickets.json, or fails like the real tool when $S/fail exists
cat > "$S/node" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$S/node.argv"
[ -e "$S/fail" ] && { echo "tickets: error: no ticket store here"; exit 2; }
case " $* " in *" find "*) for a in "$@"; do r="$a"; done
  [ -f "$S/find/$r.json" ] || { echo "tickets: error: no ticket $r"; exit 2; }; cat "$S/find/$r.json"; exit 0 ;; esac
cat "$S/tickets.json"
SH
# fake bin/work: one line per call, each argument in brackets; fake bin/sessions prints $S/sessions
printf '#!/bin/bash\nfor a in "$@"; do printf "[%%s]" "$a"; done >> "$S/work.log"; echo >> "$S/work.log"\n' > bin/work
printf '#!/bin/bash\necho "NAME FOLDER PID PARENT STARTED ROLE STATUS LAST"\ncat "$S/sessions" 2>/dev/null; exit 0\n' > bin/sessions
chmod +x "$S/node" bin/work bin/sessions
export PATH="$S:$PATH"
J="journal/$(date -u +%Y-%m-%d).md"
FAKE_WORK="$(cat bin/work)"
reset() { rm -f "$S/work.log" "$S/node.argv" "$S/sessions" "$S/fail" "$J"; rm -rf "$S/find" "$ST/dispatch" "$ST/dispatch.lock"; mkdir -p "$S/find"
  : > "$S/work.log"; unset HUB_DISPATCH_MAX; printf '%s\n' "$FAKE_WORK" > bin/work; }
# approve_tty <ref> <typed>: --approve in a pseudo-terminal (script), the owner typing <typed> at the prompt
approve_tty() { { sleep 1; printf '%s\n' "$2"; sleep 1; } | script -q /dev/null bin/dispatch --approve "$1" projects/demo | tr -d '\r'; }
row() { printf '{"ref":"%s","state":"todo","risk":"%s"%s}' "$1" "$2" "${3:-}"; }
tickets() {  # tickets <ready rows> [refine rows] [in-progress rows] [blocked rows]
  printf '{"store":"repo","folder":"demo","ready_to_refine":[%s],"ready_to_start":[%s],"in_progress":[%s],"blocked":[%s]}\n' \
    "${2:-}" "$1" "${3:-}" "${4:-}" > "$S/tickets.json"
}
calls() { grep -c . "$S/work.log"; }
journal_lines() { cat "$J" 2>/dev/null | grep -c '^dispatch'; }

starts_one_by_default() {
  reset; tickets "$(row 1.1 medium),$(row 1.2 low)"
  out=$(bin/dispatch projects/demo) || fail "dispatch exits 0: $out"
  assert_eq "$(calls)" 1 "one start by default"
  assert_eq "$(cat "$S/work.log")" "[--role][builder][--name][1.1][--ticket][1.1][--prompt][bmad-build 1.1][projects/demo]" "bin/work call"
  assert_eq "$(cat "$S/node.argv")" "$CK/_bmad/ade-runtime.mjs tickets --project-root $CK next" "the checkout's tickets next"
  # a ref with characters bin/work does not take in a name is sanitised for --name, kept in the prompt
  reset; tickets "$(row 'demo/01-a b.md' low)"
  bin/dispatch projects/demo >/dev/null 2>&1
  assert_eq "$(calls)" 0 "a ref with a space is refused, never started"
  # a ref that would be a flag (option injection), or one with a trailing newline, is skipped and never started
  reset; tickets "$(row '--x' low),$(row '-1.1' low)"
  HUB_DISPATCH_MAX=2 bin/dispatch projects/demo >/dev/null 2>&1
  assert_eq "$(calls)" 0 "a ref starting with - is never started"
  reset; tickets "$(row '1.1\n' low)"
  bin/dispatch projects/demo >/dev/null 2>&1
  assert_eq "$(calls)" 0 "a ref with a trailing newline is never started"
  reset; tickets "$(row 'demo/01-a.md' low)"
  bin/dispatch projects/demo >/dev/null || fail "dispatch a file ref"
  assert_eq "$(cat "$S/work.log")" "[--role][builder][--name][demo-01-a.md][--ticket][demo/01-a.md][--prompt][bmad-build demo/01-a.md][projects/demo]" "sanitised name"
}

max_capped_at_two() {
  reset; tickets "$(row 1.1 low),$(row 1.2 low),$(row 1.3 low)"
  HUB_DISPATCH_MAX=2 bin/dispatch projects/demo >/dev/null || fail "dispatch max 2"
  assert_eq "$(calls)" 2 "HUB_DISPATCH_MAX=2 starts two"
  reset; tickets "$(row 1.1 low),$(row 1.2 low),$(row 1.3 low)"
  HUB_DISPATCH_MAX=9 bin/dispatch projects/demo >/dev/null || fail "dispatch max 9"
  assert_eq "$(calls)" 2 "HUB_DISPATCH_MAX above 2 is capped at 2"
  reset; tickets "$(row 1.1 low)"
  HUB_DISPATCH_MAX=two bin/dispatch projects/demo >/dev/null 2>&1; assert_eq "$?" 2 "a bad HUB_DISPATCH_MAX is refused"
  assert_eq "$(calls)" 0 "nothing started on a bad HUB_DISPATCH_MAX"
}

running_ticket_not_restarted() {
  reset; tickets "$(row 1.1 low),$(row 1.2 low)"
  echo "1.1 projects/demo 123 - 2026-11-21T00:00:00Z builder busy -" > "$S/sessions"
  HUB_DISPATCH_MAX=2 bin/dispatch projects/demo >/dev/null || fail "dispatch with one running"
  assert_eq "$(cat "$S/work.log")" "[--role][builder][--name][1.2][--ticket][1.2][--prompt][bmad-build 1.2][projects/demo]" "running 1.1 not restarted, 1.2 started"
  reset; tickets "$(row 1.1 low),$(row 1.2 low)"
  echo "1.1 projects/demo 123 - 2026-11-21T00:00:00Z builder busy -" > "$S/sessions"
  bin/dispatch projects/demo >/dev/null || fail "dispatch with the one slot taken"
  assert_eq "$(calls)" 0 "the running ticket takes the only slot"
  # a running ticket session of another role still takes the slot
  reset; tickets "$(row 1.1 low),$(row 1.2 low)"
  echo "1.1 projects/demo 123 - 2026-11-21T00:00:00Z - idle -" > "$S/sessions"
  bin/dispatch projects/demo >/dev/null || fail "dispatch with a non-builder ticket session"
  assert_eq "$(calls)" 0 "a running non-builder ticket session uses the slot"
  # the same name in another folder is another ticket (NAME and FOLDER match), but its builder takes a slot hub-wide
  reset; tickets "$(row 1.1 low),$(row 1.2 low)"
  echo "1.1 projects/other 123 - 2026-11-21T00:00:00Z builder busy -" > "$S/sessions"
  HUB_DISPATCH_MAX=2 bin/dispatch projects/demo >/dev/null || fail "dispatch with a same-name session elsewhere"
  assert_eq "$(cat "$S/work.log")" "[--role][builder][--name][1.1][--ticket][1.1][--prompt][bmad-build 1.1][projects/demo]" "name and folder match; slots hub-wide"
  # a second run right after a start (its session not registered yet) starts nothing: the start marker counts
  reset; tickets "$(row 1.1 low),$(row 1.2 low)"
  bin/dispatch projects/demo >/dev/null || fail "first run"
  bin/dispatch projects/demo >/dev/null || fail "second run"
  assert_eq "$(calls)" 1 "a second run right after a start starts nothing"
  HUB_DISPATCH_MAX=2 bin/dispatch projects/demo >/dev/null || fail "third run with two slots"
  assert_eq "$(sed -n 2p "$S/work.log")" "[--role][builder][--name][1.2][--ticket][1.2][--prompt][bmad-build 1.2][projects/demo]" "a marked start is not started again"
  # a marker older than 120 s no longer counts
  reset; tickets "$(row 1.1 low)"; mkdir -p "$ST/dispatch"; echo "$(( $(date +%s) - 200 )) projects/demo" > "$ST/dispatch/1.1"
  bin/dispatch projects/demo >/dev/null || fail "dispatch with an old marker"
  assert_eq "$(calls)" 1 "an old start marker is ignored"
  # another dispatch run holding the lock: refused, nothing started; a lock whose pid is gone is taken over
  reset; tickets "$(row 1.1 low)"; mkdir -p "$ST/dispatch.lock"; echo $$ > "$ST/dispatch.lock/pid"
  bin/dispatch projects/demo >/dev/null 2>&1; assert_eq "$?" 1 "a held lock refuses the run"
  assert_eq "$(calls)" 0 "nothing started while another run holds the lock"
  [ -d "$ST/dispatch.lock" ] || fail "another run's lock is left alone"
  sh -c 'echo $$ > "$1/dispatch.lock/pid"' _ "$ST"
  bin/dispatch projects/demo >/dev/null || fail "a stale lock is taken over"
  assert_eq "$(calls)" 1 "started after a stale lock"; [ ! -e "$ST/dispatch.lock" ] || fail "the run removes its lock"
  # a broken session list starts nothing
  reset; tickets "$(row 1.1 low)"; printf '#!/bin/bash\nexit 1\n' > "$S/sessions-bad"; cp bin/sessions "$S/sessions-ok"
  cp "$S/sessions-bad" bin/sessions; bin/dispatch projects/demo >/dev/null 2>&1; rc=$?; cp "$S/sessions-ok" bin/sessions
  assert_eq "$rc" 1 "bin/sessions failing exits 1"; assert_eq "$(calls)" 0 "nothing started without a session list"
}

high_risk_waits() {
  reset; tickets "$(row 2.1 high),$(row 2.2 low ',"hitl":true'),$(row 2.3 '')"
  out=$(HUB_DISPATCH_MAX=2 bin/dispatch projects/demo) || fail "dispatch with waiting tickets: $out"
  assert_eq "$(calls)" 0 "high-risk, hitl and unknown-risk tickets are not started"
  for r in 2.1 2.2 2.3; do echo "$out" | grep -q "^waiting for the owner: $r " || fail "$r printed as waiting: $out"; done
  assert_eq "$(journal_lines)" 1 "one journal line"
  for r in 2.1 2.2 2.3; do assert_eq "$(grep -o "waiting for the owner:[^;]*" "$J" | tr ' ,' '\n\n' | grep -cx "$r")" 1 "$r journaled once"; done
  reset; tickets "$(row 2.4 low ',"drift":{"hitl":{"file":false,"entry":true}}')"
  out=$(bin/dispatch projects/demo) || fail "dispatch with a hitl drift"
  assert_eq "$(calls)" 0 "a hitl drift waits"; echo "$out" | grep -q "^waiting for the owner: 2.4 " || fail "drift printed as waiting: $out"
  # a leaf file cannot lower its entry's risk: the higher of the two counts; a risk that cannot be checked waits
  E="$(mktemp -d)"; printf '[[entry]]\nid = 1\ntype = "story"\nrisk = "high"\n\n[[entry]]\nid = 2\ntype = "story"\nrisk = "low"\n' > "$E/tickets.toml"
  reset; tickets "$(row 4.1 low ',"id":1,"file":"01-a.md"')"; printf '{"story_file":"%s/01-a.md"}' "$E" > "$S/find/4.1.json"
  out=$(bin/dispatch projects/demo) || fail "dispatch with a lowered file risk"
  assert_eq "$(calls)" 0 "file risk low under an entry risk high waits"; echo "$out" | grep -q "^waiting for the owner: 4.1 " || fail "4.1 waits: $out"
  reset; tickets "$(row 4.2 low ',"id":2,"file":"02-b.md"')"; printf '{"story_file":"%s/02-b.md"}' "$E" > "$S/find/4.2.json"
  bin/dispatch projects/demo >/dev/null || fail "dispatch with agreeing risks"
  assert_eq "$(calls)" 1 "file and entry both low starts"
  reset; tickets "$(row 4.3 low ',"id":3,"file":"03-c.md"')"
  out=$(bin/dispatch projects/demo) || fail "dispatch when find fails"
  assert_eq "$(calls)" 0 "a risk that cannot be checked waits"; echo "$out" | grep -q "^waiting for the owner: 4.3 " || fail "4.3 waits: $out"
}

approve_starts_one() {
  reset; tickets "$(row 2.1 high),$(row 2.2 low)"
  bin/dispatch --approve 2.1 projects/demo </dev/null >/dev/null 2>&1; assert_eq "$?" 1 "--approve without a terminal exits 1"
  assert_eq "$(calls)" 0 "--approve without a terminal starts nothing"
  out=$(approve_tty 2.1 2.2); assert_eq "$(calls)" 0 "--approve with the wrong ref typed back starts nothing: $out"
  out=$(approve_tty 2.1 2.1); echo "$out" | grep -q "^started: 2.1" || fail "approve at the terminal: $out"
  assert_eq "$(cat "$S/work.log")" "[--role][builder][--name][2.1][--ticket][2.1][--prompt][bmad-build 2.1][projects/demo]" "approve starts only 2.1"
  grep -q '^dispatch: started 2.1 (approved at the terminal)$' "$J" || fail "the --approve journal line: $(cat "$J" 2>/dev/null)"
  reset; tickets "$(row 2.1 high)" "" "" "$(row 2.9 high)"
  bin/dispatch --approve 2.9 projects/demo >/dev/null 2>&1; assert_eq "$?" 1 "approving a ticket that is not ready exits 1"
  assert_eq "$(calls)" 0 "a blocked ticket is never started by --approve"
  bin/dispatch --approve 2.7 projects/demo >/dev/null 2>&1; assert_eq "$?" 1 "approving an unknown ticket exits 1"
  echo "2.1 projects/demo 123 - 2026-11-21T00:00:00Z builder busy -" > "$S/sessions"
  bin/dispatch --approve 2.1 projects/demo >/dev/null 2>&1; assert_eq "$?" 1 "approving a running ticket exits 1"
  assert_eq "$(calls)" 0 "a running ticket is not started again by --approve"
}

only_ready_started() {
  reset; tickets "" "$(row 3.1 low)" "$(row 3.2 low)" "$(row 3.3 low)"
  HUB_DISPATCH_MAX=2 bin/dispatch projects/demo >/dev/null || fail "dispatch with nothing ready"
  assert_eq "$(calls)" 0 "to-refine, in-progress and blocked tickets are never started"
}

bad_tree_starts_nothing() {
  reset; tickets "$(row 1.1 low)"; touch "$S/fail"
  out=$(bin/dispatch projects/demo 2>&1); assert_eq "$?" 1 "tickets next failing exits 1"
  echo "$out" | grep -q "no ticket store here" || fail "its message is shown: $out"
  assert_eq "$(calls)" 0 "nothing started on a bad tree"
  reset; echo 'not json' > "$S/tickets.json"
  bin/dispatch projects/demo >/dev/null 2>&1; assert_eq "$?" 1 "unreadable tickets output exits 1"
  reset; tickets "$(row 1.1 low)"; mv "$CK/_bmad" "$CK/_nobmad"
  out=$(bin/dispatch projects/demo 2>&1); rc=$?; mv "$CK/_nobmad" "$CK/_bmad"
  assert_eq "$rc" 1 "no BMAD in the checkout exits 1"; assert_eq "$(calls)" 0 "nothing started without BMAD"
  bin/dispatch projects/nope >/dev/null 2>&1; assert_eq "$?" 2 "an unknown folder is refused"
  reset; tickets "$(row 1.1 low)"; bin/new projects/two >/dev/null; C2="$(mktemp -d)"; mkdir -p "$C2/a/_bmad" "$C2/b"
  : > "$C2/a/_bmad/ade-runtime.mjs"; printf '| a | %s | main | Owner | none |\n| b | %s | main | Owner | none |\n' "$C2/a" "$C2/b" >> projects/two/ACCESS.md
  bin/dispatch projects/two >/dev/null 2>&1; assert_eq "$?" 1 "a second Code row refuses"; assert_eq "$(calls)" 0 "nothing started with two Code rows"
  # bin/work failing (exit 3, already running): one call, exit 1, no more starts, journaled
  reset; tickets "$(row 1.1 low),$(row 1.2 low)"
  printf '#!/bin/bash\necho "[$*]" >> "$S/work.log"; exit 3\n' > bin/work
  HUB_DISPATCH_MAX=2 bin/dispatch projects/demo >/dev/null 2>&1; assert_eq "$?" 1 "a bin/work failure exits 1"
  assert_eq "$(calls)" 1 "no more starts after a bin/work failure"
  grep '^dispatch' "$J" | tail -1 | grep -q '; bin/work failed for 1.1$' || fail "the failure is journaled: $(cat "$J" 2>/dev/null)"
}

run_journaled() {
  reset; tickets "$(row 1.1 low),$(row 2.1 high)"
  bin/dispatch projects/demo >/dev/null || fail "dispatch for the journal"
  assert_eq "$(journal_lines)" 1 "one journal line per run"
  grep -q '^dispatch: started 1.1; waiting for the owner: 2.1$' "$J" || fail "journal lists started and waiting: $(cat "$J")"
  reset; tickets ""
  bin/dispatch projects/demo >/dev/null || fail "dispatch with nothing"
  grep -q '^dispatch: started none; waiting for the owner: none$' "$J" || fail "an empty run is journaled: $(cat "$J" 2>/dev/null)"
  # an unchanged run (nothing started, same waiting list as the folder's last dispatch line today) is not journaled again
  reset; tickets "$(row 2.1 high)"
  bin/dispatch projects/demo >/dev/null; bin/dispatch projects/demo >/dev/null
  assert_eq "$(journal_lines)" 1 "an unchanged run writes no second line"
  tickets "$(row 2.1 high),$(row 2.2 high)"; bin/dispatch projects/demo >/dev/null
  assert_eq "$(journal_lines)" 2 "a changed waiting list is journaled"
}

# the Claude Code permission prompt gates --approve (and a fake pty) in every folder session and the hub root
for f in templates/folder-settings.json .claude/settings.json projects/demo/.claude/settings.json; do
  python3 -c 'import json,sys; a=json.load(open(sys.argv[1]))["permissions"]["ask"]
for r in ("Bash(*bin/dispatch --approve*)", "Bash(*ade dispatch --approve*)", "Bash(script *)"): assert r in a, r' "$f" ||
    fail "$f asks before --approve and script"
done
starts_one_by_default; max_capped_at_two; running_ticket_not_restarted; high_risk_waits
approve_starts_one; only_ready_started; bad_tree_starts_nothing; run_journaled
echo ok
