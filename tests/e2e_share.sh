#!/bin/bash
# story I1, AC 7, end to end and offline: two people share one hub through a bare remote. The hub is made in A, cloned
# in B at another path under another HOME; both run bin/setup, bin/new, bin/work (a fake claude that runs the folder's
# hooks) and bin/sync --auto. Both end with the same tree, a clean status and a doctor with nothing to flag.
. "$(dirname "$0")/helpers.sh"
make_hub; T="$HUB"; W="$(mktemp -d)"
HOMEA="$W/a/home"; HOMEB="$W/b/someone/home"; mkdir -p "$HOMEA" "$HOMEB"
HA="$HOMEA/hubs/team-hub"; HB="$HOMEB/src/shared/team"; R="$W/remote/hub.git"
# a stub gitleaks (bin/sync --auto refuses without one) and a fake claude: it runs the SessionStart and PreCompact hooks
# of the settings it is given (--settings, else the folder's .claude/settings.json: a session started there by hand), as
# Claude Code would at the start and at a compaction, with $CLAUDE_PROJECT_DIR its working directory, and logs each
# one's exit code and the real path of the script it ran
S="$W/stubs"; mkdir -p "$S"
printf '#!/bin/bash\nexit 0\n' > "$S/gitleaks"
cat > "$S/claude" <<'FAKE'
#!/bin/bash
SET=.claude/settings.json; while [ $# -gt 0 ]; do [ "$1" = --settings ] && SET="$2"; shift; done
export CLAUDE_PROJECT_DIR="$PWD"
python3 - "$SET" <<'PY' | while IFS=$'\t' read -r c x; do echo '{}' | bash -c "$c" >/dev/null 2>&1; echo "$? $x" >> "$FAKE_LOG"; done
import json, os, shlex, sys
s = json.load(open(sys.argv[1]))
for e in ("SessionStart", "PreCompact"):
    for g in s.get("hooks", {}).get(e, []):
        for h in g["hooks"]:
            c = h["command"]; exe = shlex.split(c.replace('"$CLAUDE_PROJECT_DIR"', shlex.quote(os.environ["CLAUDE_PROJECT_DIR"])))[0]
            print("%s\t%s" % (c, os.path.realpath(exe)))
PY
FAKE
chmod +x "$S/gitleaks" "$S/claude"; export PATH="$S:$PATH" AGENT_CLAUDE="$S/claude"
unset HUB_AUTO_SYNC
inA() { (cd "$HA" && HOME="$HOMEA" HUB="$HA" CLAUDE_HOME="$HOMEA/.claude" AGENT_STATE="$HOMEA/.agent-hub" FAKE_LOG="$W/a.log" "$@"); }
inB() { (cd "$HB" && HOME="$HOMEB" HUB="$HB" CLAUDE_HOME="$HOMEB/.claude" AGENT_STATE="$HOMEB/.agent-hub" FAKE_LOG="$W/b.log" "$@"); }
# session <side> <folder>: bin/work writes the launcher (nothing opened); the launcher runs the fake claude
session() { local o l; o=$($1 env WORK_NO_OPEN=1 bin/work --no-remote "$2" 2>/dev/null) || fail "$1: bin/work $2 failed"
  l=$(echo "$o" | sed -n 's/^launcher: //p'); [ -x "$l" ] || fail "$1: no launcher for $2: $o"
  $1 bash "$l" </dev/null >/dev/null 2>&1 || fail "$1: the session in $2 failed"; }
clean() { local st; st=$($1 git status --porcelain); [ -z "$st" ] || fail "$2: $1 is not clean: $st"; }

# A makes the hub and pushes it
(cd "$T" && HOME="$HOMEA" CLAUDE_HOME="$HOMEA/.claude" env -u HUB bin/init --persona tech-lead --client "Team" --owner "Kim" --dest "$HA" >/dev/null) || fail "init in A"
git init -q --bare "$R"
inA git config user.name a; inA git config user.email a@a
(inA git add -A && inA git commit -qm "hub" && inA git remote add origin "$R" && inA git push -q -u origin main) || fail "first push from A"
# B clones it to another path
git clone -q "$R" "$HB" || fail "clone in B"; inB git config user.name b; inB git config user.email b@b

# each: setup, a new folder, a session, an unattended sync
inA bin/setup >/dev/null || fail "setup in A"
inA bin/new projects/alpha >/dev/null || fail "bin/new in A"
session inA projects/alpha
inA bin/sync --auto || fail "sync in A: $(tail -1 "$AGENT_SYNC_LOG")"
clean inA "after A's sync"
inB bin/setup >/dev/null || fail "setup in B"
inB bin/new projects/beta >/dev/null || fail "bin/new in B"
session inB projects/beta
inB bin/sync --auto || fail "sync in B: $(tail -1 "$AGENT_SYNC_LOG")"
clean inB "after B's sync"
# A takes B's work; each runs bin/setup again (B's new folder gets A's hooks) and a session in the other's folder
inA git pull -q --rebase || fail "pull in A"
inA bin/setup >/dev/null || fail "second setup in A"; inB bin/setup >/dev/null || fail "second setup in B"
session inA projects/beta; session inB projects/alpha
# a session started in the folder by hand (no bin/work) runs the same hooks from the committed settings.json
(cd "$HA/projects/beta" && HOME="$HOMEA" FAKE_LOG="$W/a.log" claude </dev/null >/dev/null 2>&1) || fail "A: the hand-started session failed"
(cd "$HB/projects/alpha" && HOME="$HOMEB" FAKE_LOG="$W/b.log" claude </dev/null >/dev/null 2>&1) || fail "B: the hand-started session failed"
inA bin/sync --auto || fail "second sync in A"; inB bin/sync --auto || fail "second sync in B"
inA git pull -q --rebase || fail "last pull in A"; inB git pull -q --rebase || fail "last pull in B"

# the same tree everywhere, nothing left over, every hook ran from its own machine's hub
assert_eq "$(inA git rev-parse HEAD^{tree})" "$(git --git-dir="$R" rev-parse main^{tree})" "A has the remote's tree"
assert_eq "$(inB git rev-parse HEAD^{tree})" "$(inA git rev-parse HEAD^{tree})" "A and B have the same tree"
clean inA "at the end"; clean inB "at the end"
real() { python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$1"; }
for side in A B; do log="$W/$(echo $side | tr AB ab).log"; h=$(real "$([ $side = A ] && echo "$HA" || echo "$HB")")
  [ "$(grep -c . "$log")" -ge 6 ] || fail "$side: the sessions ran too few hooks: $(cat "$log")"
  grep -v "^0 $h/bin/" "$log" && fail "$side: a hook failed or ran another path's script"
done
for side in inA inB; do out=$($side env DOCTOR_OFFLINE=1 bin/doctor); assert_eq "$?" "0" "$side: doctor exits 0"
  echo "$out" | grep -qE "^OK +hub memory link" || fail "$side: doctor: [$out]"
  echo "$out" | grep -E "^(WARN|MISSING) +(settings|hub.conf|hub memory)" && fail "$side: doctor flags the hub"
done
# no machine path in what they share
for p in "$HA" "$HB" "$HOMEA" "$HOMEB"; do inA git grep -qF "$p" HEAD && fail "a committed file holds $p"; done
echo ok
