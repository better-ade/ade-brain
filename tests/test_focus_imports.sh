#!/bin/bash
# A focus session starts without Claude Code's external-imports question (.ade/context/focus-folders.md): the hub
# root's CLAUDE.md is excluded for the folder, and the folder's CLAUDE.md imports copies kept inside the folder
# (<folder>/.claude/hub/), which bin/work refreshes on every start. A start that nobody watches and that does not get
# going is reported to the main session.
. "$(dirname "$0")/helpers.sh"
make_hub; cd "$HUB"; . bin/lib.sh
unset ADE_HOOK_BIN ADE_HOOK_PORT ADE_HOOK_TOKEN ADE_PTY_ID CLAUDE_PID   # never the real ADE; no session of the tester's
ST="$(mktemp -d)"; export AGENT_STATE="$ST"
# a hub root as bin/init leaves it: the rendered rules, with their three imports
cp templates/hub/CLAUDE.md CLAUDE.md; mkdir -p memory .ade
printf '# Access\n- the hub access rules, v1\n' > ACCESS.md
printf '# Memory\n- [one](one.md): a hub memory\n' > memory/MEMORY.md
[ -f .ade/rules.md ] || printf '# The ADE method\n' > .ade/rules.md
S="$(mktemp -d)"; printf '#!/bin/bash\nexec sleep 30\n' > "$S/claude-stub"; chmod +x "$S/claude-stub"
start() { WORK_NO_OPEN=1 bin/work --force --claude claude-stub "$@"; }   # prints "launcher: <path>"; opens nothing
wait_for() { for _ in $(seq 1 "${2:-50}"); do eval "$1" && return 0; sleep 0.1; done; return 1; }
# every @import of a file (code spans and fenced blocks skipped, as Claude Code does), followed through the files it
# reaches, that resolves outside <dir>: one "<file>: <import>" line each. A CLAUDE.md the settings exclude is not loaded.
outside() {  # <dir> <file>...
  python3 - "$@" <<'PY'
import os, re, sys
root = os.path.realpath(sys.argv[1]); seen = set(); todo = [os.path.realpath(p) for p in sys.argv[2:]]
def imports(path):
    fence = False
    for line in open(path, encoding="utf-8", errors="replace").read().splitlines():
        if re.match(r"\s*(```|~~~)", line): fence = not fence; continue
        if fence: continue
        for m in re.finditer(r"(?:^|(?<=\s))@((?:\\ |[^\s\\])+)", re.sub(r"`[^`]*`", "", line)):
            p = os.path.expanduser(m.group(1).replace("\\ ", " "))
            yield m.group(1), os.path.realpath(p if os.path.isabs(p) else os.path.join(os.path.dirname(path), p))
while todo:
    f = todo.pop()
    if f in seen or not os.path.isfile(f): continue
    seen.add(f)
    for raw, p in imports(f):
        if not os.path.isfile(p): continue   # a mention, not a file
        if p != root and not p.startswith(root + os.sep): print("%s: @%s" % (f, raw))
        else: todo.append(p)
PY
}
# the ancestor CLAUDE.md files a session in <dir> loads, minus the ones its folder settings exclude (per machine, story I1: settings.local.json)
ancestors() {  # <dir> <settings.local.json>
  python3 - "$@" <<'PY'
import fnmatch, json, os, sys
d = os.path.realpath(sys.argv[1]); ex = json.load(open(sys.argv[2])).get("claudeMdExcludes", [])
while True:
    d = os.path.dirname(d); c = os.path.join(d, "CLAUDE.md")
    if os.path.isfile(c) and not any(fnmatch.fnmatch(c, p) or fnmatch.fnmatch(os.path.realpath(c), p) for p in ex): print(c)
    if d == os.path.dirname(d): break
PY
}
D="$HUB/projects/demo"; M="$D/.claude/hub"

new_folder_has_no_outside_import() {
  bin/new projects/demo >/dev/null
  # the fixture is real: the hub root's own CLAUDE.md, loaded from the folder, has the three outside imports
  n=$(outside "$D" "$HUB/CLAUDE.md" | wc -l | tr -d ' '); assert_eq "$n" "3" "the hub root CLAUDE.md imports three hub files (outside a folder)"
  [ -z "$(ancestors "$D" "$D/.claude/settings.local.json")" ] || fail "the folder's settings exclude the hub root CLAUDE.md: $(ancestors "$D" "$D/.claude/settings.local.json")"
  grep -qF '@.claude/hub/CLAUDE.md' "$D/CLAUDE.md" || fail "the folder's CLAUDE.md imports the hub's rules from inside the folder"
  out=$(start projects/demo 2>&1) || fail "work starts: $out"
  echo "$out" | grep -q "now imports" && fail "a new folder is not migrated: $out"
  [ -f "$M/CLAUDE.md" ] || fail "the copies are written"
  o=$(outside "$D" "$D/CLAUDE.md"); [ -z "$o" ] || fail "an import outside the folder: $o"
  # ...and the check does see one when it is there
  printf '\n@../../ACCESS.md\n' >> "$D/CLAUDE.md"; [ -n "$(outside "$D" "$D/CLAUDE.md")" ] || fail "the check finds an outside import"
  start projects/demo >/dev/null 2>&1; o=$(outside "$D" "$D/CLAUDE.md"); [ -z "$o" ] || fail "an outside import of a hub file is rewritten: $o"
}
copies_match_and_refresh() {
  for f in CLAUDE.md ACCESS.md memory/MEMORY.md .ade/rules.md; do
    cmp -s "$HUB/$f" "$M/$f" || fail "copy of $f is byte for byte"; done
  grep -q '^\*$' "$M/.gitignore" && grep -qi 'generated' "$M/.gitignore" || fail "the copies' folder is marked generated and ignores itself"
  git -C "$HUB" add -A >/dev/null 2>&1
  git -C "$HUB" ls-files | grep -q '^projects/demo/.claude/hub/' && fail "the copies are not tracked by the hub repo"
  # a change in the hub reaches the next start; a file the hub no longer imports goes
  printf '# Access\n- the hub access rules, v2\n' > ACCESS.md; printf 'old\n' > "$M/gone.md"
  cmp -s ACCESS.md "$M/ACCESS.md" && fail "fixture: the copy is stale before the start"
  start projects/demo >/dev/null 2>&1
  cmp -s ACCESS.md "$M/ACCESS.md" || fail "the copy is refreshed on the next start"
  [ ! -e "$M/gone.md" ] || fail "a copy the hub no longer has is removed"
  [ -z "$(find "$M" -name '.tmp-*')" ] || fail "no temp file is left: $(find "$M" -name '.tmp-*')"
  # a dry run writes nothing
  printf '# Access\n- v3\n' > ACCESS.md; WORK_DRY=1 bin/work --claude claude-stub projects/demo >/dev/null 2>&1
  cmp -s ACCESS.md "$M/ACCESS.md" && fail "a dry run does not refresh"
  return 0
}
symlink_not_followed() {
  V="$(mktemp -d)"; printf 'victim\n' > "$V/file"; mkdir "$V/dir"; printf 'keep\n' > "$V/dir/MEMORY.md"
  rm -f "$M/ACCESS.md"; ln -s "$V/file" "$M/ACCESS.md"          # a link where a copy goes
  rm -rf "$M/memory"; ln -s "$V/dir" "$M/memory"                # a link where a copy's folder goes
  start projects/demo >/dev/null 2>&1
  assert_eq "$(cat "$V/file")" "victim" "a symlink at a copy's path is not written through"
  assert_eq "$(cat "$V/dir/MEMORY.md")" "keep" "a symlinked folder is not written into"
  [ ! -L "$M/ACCESS.md" ] && [ ! -L "$M/memory" ] || fail "the links are replaced by real files"
  cmp -s ACCESS.md "$M/ACCESS.md" && cmp -s memory/MEMORY.md "$M/memory/MEMORY.md" || fail "the copies are right after a planted link"
  # the copies' own folder as a link
  rm -rf "$M"; mkdir "$V/hub"; ln -s "$V/hub" "$M"
  start projects/demo >/dev/null 2>&1
  [ ! -L "$M" ] && [ -f "$M/CLAUDE.md" ] || fail "a symlinked .claude/hub is replaced"
  [ -z "$(ls -A "$V/hub")" ] || fail "nothing is written through a symlinked .claude/hub: $(ls -A "$V/hub")"
}
old_folder_migrated_once() {
  # a folder from before: no exclusion, no copies, the hub's files imported from outside, and lines of its own
  bin/new projects/old >/dev/null; O="$HUB/projects/old"; rm -rf "$O/.claude/hub"
  python3 - "$O/.claude/settings.local.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1])); s.pop("claudeMdExcludes", None); json.dump(s, open(sys.argv[1], "w"), indent=2)
PY
  printf '# old\n\nMy own line, kept.\nMention `@../../ACCESS.md` in code, kept.\n\n@../../ACCESS.md\n@%s/memory/MEMORY.md\n@../../.ade/rules.md\n@ACCESS.md\n@memory/MEMORY.md\n@STATE.md\n' "$HUB" > "$O/CLAUDE.md"
  [ -n "$(ancestors "$O" "$O/.claude/settings.local.json")" ] && [ -n "$(outside "$O" "$O/CLAUDE.md")" ] || fail "fixture: the old folder has outside imports"
  out=$(start projects/old 2>&1) || fail "work starts on an old folder: $out"
  n=$(echo "$out" | grep -c "work: projects/old: .*now imports"); assert_eq "$n" "1" "the migration is said in one line: $out"
  o=$(outside "$O" "$O/CLAUDE.md"); [ -z "$o" ] || fail "no outside import after the migration: $o"
  [ -z "$(ancestors "$O" "$O/.claude/settings.local.json")" ] || fail "the migration excludes the hub root CLAUDE.md"
  for l in '# old' 'My own line, kept.' 'Mention `@../../ACCESS.md` in code, kept.' '@.claude/hub/ACCESS.md' '@.claude/hub/memory/MEMORY.md' \
    '@.claude/hub/.ade/rules.md' '@.claude/hub/CLAUDE.md' '@ACCESS.md' '@memory/MEMORY.md' '@STATE.md'; do
    grep -qxF -- "$l" "$O/CLAUDE.md" || fail "after the migration CLAUDE.md has the line [$l]: $(cat "$O/CLAUDE.md")"; done
  grep -qF '/bin/changes projects/old' "$O/.claude/settings.json" || fail "the folder's hooks are kept"
  # once: the next start changes nothing and says nothing
  before="$(cat "$O/CLAUDE.md" "$O/.claude/settings.local.json")"
  out=$(start projects/old 2>&1); echo "$out" | grep -q "now imports" && fail "migrated once: $out"
  assert_eq "$(cat "$O/CLAUDE.md" "$O/.claude/settings.local.json")" "$before" "a second start leaves the folder as it is"
}
stuck_start_reported() {
  export HUB_WORK_START_WAIT=1
  notes() { grep -c '"kind": *"note"' "$ST/events.jsonl" 2>/dev/null || true; }
  # started by the orchestrator (a Claude session), a first message given, and the session never takes it: one note
  f=$(CLAUDE_PID=777 start --prompt "do it" projects/demo 2>/dev/null | sed -n 's/^launcher: //p'); [ -x "$f" ] || fail "launcher written"
  PATH="$S:$PATH" bash "$f" >/dev/null 2>&1 & lp=$!
  wait_for '[ "$(notes)" = 1 ]' 80 || fail "a start that does not get going is reported: $(cat "$ST/events.jsonl" 2>/dev/null)"
  l=$(grep '"kind": *"note"' "$ST/events.jsonl")
  echo "$l" | grep -q '"from": *"projects/demo"' && echo "$l" | grep -q '"to": *"main"' || fail "the note goes from the folder to main: $l"
  echo "$l" | grep -q 'projects/demo' && echo "$l" | grep -q 'waiting at its terminal' || fail "the note names the folder and says it waits: $l"
  assert_eq "$(pgrep -P "$lp" | wc -l | tr -d ' ')" "1" "the check is not a child of the launcher (bin/sessions reads its one child as the engine)"
  sleep 1.5; assert_eq "$(notes)" "1" "reported once"
  kill "$(pgrep -P "$lp" | head -1)" 2>/dev/null; wait "$lp" 2>/dev/null
  # a session that takes its first message (the prompt hook ran) is not reported. Deterministic, not timed (story F):
  # the check's wait starts only once the hook has run (a gated sleep), and the assertion waits for the check to exit
  printf '#!/bin/bash\n"$HUB/bin/changes" projects/demo </dev/null >/dev/null 2>&1; touch "$AGENT_STATE/p1"\nexec sleep 30\n' > "$S/claude-ok"; chmod +x "$S/claude-ok"
  G="$(mktemp -d)"; printf '#!/bin/bash\nwhile [ ! -e "$AGENT_STATE/p1" ]; do /bin/sleep 0.05; done; exec /bin/sleep "$@"\n' > "$G/sleep"; chmod +x "$G/sleep"
  f=$(CLAUDE_PID=777 WORK_NO_OPEN=1 bin/work --force --claude claude-ok --prompt "do it" projects/demo 2>/dev/null | sed -n 's/^launcher: //p')
  PATH="$G:$S:$PATH" bash "$f" >/dev/null 2>&1 & lp=$!
  wait_for '[ -e "$ST/p1" ]' 100 || fail "the prompt hook ran"
  # the check is a forked copy of the launcher (same command line) that may become bin/notify (a subshell can exec its
  # last command); it is done when only the launcher is left and no bin/notify of this hub runs
  wait_for '[ -z "$(pgrep -f "$f" | grep -vx "$lp")" ] && ! pgrep -f "$HUB/bin/notify" >/dev/null' 100 || fail "the start check finished"
  assert_eq "$(notes)" "1" "a session that is running is not reported"
  kill "$(pgrep -P "$lp" | head -1)" 2>/dev/null; wait "$lp" 2>/dev/null
  # started by a person at a terminal (no Claude session, chat off): nobody is told
  f=$(start --prompt "do it" projects/demo 2>/dev/null | sed -n 's/^launcher: //p')
  PATH="$S:$PATH" bash "$f" >/dev/null 2>&1 & lp=$!; sleep 2.5
  assert_eq "$(notes)" "1" "a start a person watches is not reported"
  kill "$(pgrep -P "$lp" | head -1)" 2>/dev/null; wait "$lp" 2>/dev/null
  # ...but with the hub's chat on (a live chat.pid) it is
  mkdir -p "$ST/chat"; sleep 60 & cpid=$!; echo "$cpid 2026-01-01T00:00:00Z" > "$ST/chat/chat.pid"
  f=$(start --prompt "do it" projects/demo 2>/dev/null | sed -n 's/^launcher: //p')
  PATH="$S:$PATH" bash "$f" >/dev/null 2>&1 & lp=$!
  wait_for '[ "$(notes)" = 2 ]' 80 || fail "with chat on, a start that does not get going is reported"
  kill "$(pgrep -P "$lp" | head -1)" "$cpid" 2>/dev/null; wait "$lp" 2>/dev/null; rm -f "$ST/chat/chat.pid"
  # a session that ended before the wait is over is not reported (its entry is gone)
  printf '#!/bin/bash\nexit 0\n' > "$S/claude-gone"; chmod +x "$S/claude-gone"
  f=$(CLAUDE_PID=777 WORK_NO_OPEN=1 bin/work --force --claude claude-gone --prompt "do it" projects/demo 2>/dev/null | sed -n 's/^launcher: //p')
  PATH="$S:$PATH" bash "$f" >/dev/null 2>&1; sleep 2.5
  assert_eq "$(notes)" "2" "a session that already ended is not reported"
  # the orchestrator's instructions say what to do with the line
  grep -q 'waiting at its terminal' "$HUB/templates/hub/CLAUDE.md" || fail "the hub rules tell the orchestrator to pass a stuck start on"
  unset HUB_WORK_START_WAIT
}
for t in new_folder_has_no_outside_import copies_match_and_refresh symlink_not_followed old_folder_migrated_once stuck_start_reported; do "$t"; done
echo ok
