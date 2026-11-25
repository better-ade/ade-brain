#!/bin/bash
# story I2, AC 6, end to end and offline: a hub made in scratch HOME A (a learned fact, a journal) is pushed to a bare
# remote; in HOME B each bin/adopt mode runs on its own clone, then bin/setup and bin/doctor pass and bin/work starts a
# folder session (a fake claude that runs the folder's hooks) whose rules name the new owner.
. "$(dirname "$0")/helpers.sh"
make_hub; T="$HUB"; W="$(mktemp -d)"
for v in CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_SESSION_ID CLAUDE_PID CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_BRIDGE_SESSION_ID \
  CLAUDE_CODE_EXECPATH CLAUDE_CODE_MESSAGING_SOCKET CLAUDE_CODE_MESSAGING_TOKEN CLAUDE_CODE_SESSION_ATTENDED; do unset "$v"; done
HOMEA="$W/a/home"; HOMEB="$W/b/home"; mkdir -p "$HOMEA" "$HOMEB"
HA="$HOMEA/hubs/team"; R="$W/remote/hub.git"
# a stub gitleaks (bin/learn and bin/sync refuse without one) and a fake claude: it runs the SessionStart hooks of the
# settings it is given and logs each one's exit code, then the line of the hub's rules (its copy in the folder) that
# names the owner
S="$W/stubs"; mkdir -p "$S"
printf '#!/bin/bash\nexit 0\n' > "$S/gitleaks"
cat > "$S/claude" <<'FAKE'
#!/bin/bash
[ "${1:-}" = --version ] && { echo "2.1.0 (Claude Code)"; exit 0; }
SET=.claude/settings.json; while [ $# -gt 0 ]; do [ "$1" = --settings ] && SET="$2"; shift; done
export CLAUDE_PROJECT_DIR="$PWD"
python3 - "$SET" <<'PY' | while IFS= read -r c; do echo '{}' | bash -c "$c" >/dev/null 2>&1; echo "hook $?" >> "$FAKE_LOG"; done
import json, sys
s = json.load(open(sys.argv[1]))
for g in s.get("hooks", {}).get("SessionStart", []):
    for h in g["hooks"]: print(h["command"])
PY
echo "rules: $(grep -o 'working for [A-Za-z ]*' .claude/hub/CLAUDE.md | head -1)" >> "$FAKE_LOG"
FAKE
chmod +x "$S/gitleaks" "$S/claude"; export PATH="$S:$PATH" AGENT_CLAUDE="$S/claude"
unset HUB_AUTO_SYNC
inA() { (cd "$HA" && HOME="$HOMEA" HUB="$HA" CLAUDE_HOME="$HOMEA/.claude" AGENT_STATE="$HOMEA/.agent-hub/team" AGENT_USER="Kim Old" "$@"); }
# inB <mode> <cmd...>: in that mode's clone, as the person in HOME B
inB() { local m="$1"; shift; (cd "$HOMEB/$m/hub" && HOME="$HOMEB" HUB="$HOMEB/$m/hub" CLAUDE_HOME="$HOMEB/.claude" \
  AGENT_STATE="$HOMEB/state/$m" AGENT_USER="Lee New" FAKE_LOG="$W/$m.log" "$@"); }

# A makes the hub, learns a fact, pushes it
(cd "$T" && HOME="$HOMEA" CLAUDE_HOME="$HOMEA/.claude" env -u HUB bin/init --persona tech-lead --client "Team" \
  --owner "Kim Old" --name team --dest "$HA" >/dev/null) || fail "init in A"
inA bin/setup >/dev/null || fail "setup in A"
inA bin/learn profile "Prefers short answers" >/dev/null || fail "learn in A"
[ -f "$HA/memory/users/kim-old/profile.md" ] || fail "A's learned fact is not in memory/users/kim-old"
ls "$HA"/journal/[0-9]*.md >/dev/null 2>&1 || fail "A has no journal"
git init -q --bare "$R"; inA git config user.name a; inA git config user.email a@a
(inA git add -A && inA git commit -qm hub && inA git remote add origin "$R" && inA git push -q -u origin main) || fail "push from A"
FOLDER="$(cd "$HA" && ls -d projects/* ops/* 2>/dev/null | head -1)"

for m in share handover clone; do
  git clone -q "$R" "$HOMEB/$m/hub" || fail "$m: clone"; inB $m git config user.name b; inB $m git config user.email b@b
  inB $m bin/setup >/dev/null || fail "$m: setup before adopt"
  case $m in
    share) inB $m bin/adopt --share >/dev/null || fail "share: adopt"; who="Kim Old" ;;
    handover) inB $m bin/adopt --handover --owner "Lee New" >/dev/null || fail "handover: adopt"; who="Lee New" ;;
    clone) inB $m bin/adopt --clone --owner "Lee New" --name team2 >/dev/null || fail "clone: adopt"; who="Lee New" ;;
  esac
  inB $m bin/setup >/dev/null || fail "$m: setup after adopt"
  out=$(inB $m env DOCTOR_OFFLINE=1 bin/doctor); assert_eq "$?" 0 "$m: doctor exits 0"
  echo "$out" | grep -qE "^OK +hub memory link" || fail "$m: doctor: [$out]"
  echo "$out" | grep -E "^(WARN|MISSING) +(settings|hub.conf|hub memory)" && fail "$m: doctor flags the hub"
  o=$(inB $m env WORK_NO_OPEN=1 bin/work --no-remote "$FOLDER" 2>/dev/null) || fail "$m: bin/work $FOLDER"
  l=$(echo "$o" | sed -n 's/^launcher: //p'); [ -x "$l" ] || fail "$m: no launcher: $o"
  inB $m bash "$l" </dev/null >/dev/null 2>&1 || fail "$m: the session failed"
  grep -q "^hook 0" "$W/$m.log" || fail "$m: no hook ran: $(cat "$W/$m.log")"
  grep "^hook " "$W/$m.log" | grep -qv "^hook 0" && fail "$m: a hook failed: $(cat "$W/$m.log")"
  assert_eq "$(grep '^rules: ' "$W/$m.log")" "rules: working for $who" "$m: the session's owner"
  st=$(inB $m git status --porcelain); [ -z "$st" ] || fail "$m: not clean at the end: $st"
done
[ -f "$HOMEB/share/hub/memory/users/kim-old/profile.md" ] || fail "share: A's fact left the tree"
[ -e "$HOMEB/handover/hub/memory/users/kim-old" ] && fail "handover: the old owner's facts are still in the tree"
[ -e "$HOMEB/clone/hub/memory/users" ] && fail "clone: memory/users is left"
assert_eq "$(inB clone git rev-list --count HEAD)" 1 "clone: one commit"
echo ok
