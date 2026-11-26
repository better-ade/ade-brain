#!/bin/bash
# story I1: a hub runs from any path on any machine; what is per machine is written on that machine, never committed
# (.ade/context/per-machine.md). Two scratch HOMEs, the hub made in A and cloned in B at another path.
. "$(dirname "$0")/helpers.sh"
make_hub; T="$HUB"; W="$(mktemp -d)"
HOMEA="$W/a/home"; HOMEB="$W/b/people/home"; mkdir -p "$HOMEA" "$HOMEB"
HA="$HOMEA/hubs/acme-hub"; HB="$HOMEB/work/elsewhere/acme"; CHA="$HOMEA/.claude"; CHB="$HOMEB/.claude"
# in A|B <cmd...>: run in that machine's hub, as that machine's person
inA() { (cd "$HA" && HOME="$HOMEA" HUB="$HA" CLAUDE_HOME="$CHA" "$@"); }
inB() { (cd "$HB" && HOME="$HOMEB" HUB="$HB" CLAUDE_HOME="$CHB" "$@"); }
gitq() { git -c user.name=t -c user.email=t@t "$@"; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t   # bin/setup commits its migration
real() { python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$1"; }
# no_machine_paths <hub> <home> <label>: no tracked file names the hub's path or the person's home, as given or as its
# real path (macOS: /var is /private/var) (AC 1)
no_machine_paths() { local h="$1" hm="$2" out
  out=$(cd "$h" && git add -A && git grep -n -F -e "$h" -e "$hm" -e "$(real "$h")" -e "$(real "$hm")" --cached 2>/dev/null)
  [ -z "$out" ] || fail "$3: a tracked file holds a machine path: $(echo "$out" | head -5)"; }
# hooks_ok <hub> <folder> <label>: the folder's six hub hooks and its browser server run scripts under <hub>, with
# $CLAUDE_PROJECT_DIR the folder (a session started there), and its settings.local.json excludes <hub>'s CLAUDE.md
hooks_ok() { python3 - "$1" "$2" "$3" <<'PY' || exit 1
import json, os, re, shlex, sys
hub, f, label = sys.argv[1:]
fd = os.path.join(hub, f); rh = os.path.realpath(hub)
def run_path(c):
    exe = shlex.split(c.replace('"$CLAUDE_PROJECT_DIR"', shlex.quote(fd)))[0]
    return os.path.realpath(exe)
def ok(exe): return exe.startswith(rh + "/bin/") and os.access(exe, os.X_OK)
cmds = [h["command"] for gs in json.load(open(os.path.join(fd, ".claude", "settings.json"))).get("hooks", {}).values()
        for g in gs for h in g.get("hooks", [])]
hub_cmds = [c for c in cmds if re.search(r"/bin/(context|journal|changes|inbox|stop-check|session-end) ", c)]
if len(hub_cmds) != 6: sys.exit("FAIL: %s: %d hub hooks in %s/.claude/settings.json, want 6: %s" % (label, len(hub_cmds), f, cmds))
for c in hub_cmds:
    if not c.startswith('"$CLAUDE_PROJECT_DIR"/../../bin/') or not ok(run_path(c)): sys.exit("FAIL: %s: hook %s does not run a script under %s" % (label, c, hub))
pw = json.load(open(os.path.join(fd, ".mcp.json")))["mcpServers"]["playwright"]
if pw["command"] != "bash" or '"$CLAUDE_PROJECT_DIR"/../../bin/browser' not in pw["args"][1] or pw["args"][3] != f \
   or not ok(os.path.realpath(os.path.join(fd, "../../bin/browser"))): sys.exit("FAIL: %s: .mcp.json runs %s" % (label, pw))
loc = json.load(open(os.path.join(fd, ".claude", "settings.local.json")))
if os.path.join(hub, "CLAUDE.md") not in loc.get("claudeMdExcludes", []): sys.exit("FAIL: %s: %s's settings.local.json does not exclude %s/CLAUDE.md" % (label, f, hub))
PY
}
# a checkout under each HOME (AC 4) and one fake claude
for d in "$HOMEA/code/lib" "$HOMEB/code/lib" "$HOMEA/code/app" "$HOMEB/code/app"; do mkdir -p "$d"; git -C "$d" init -q; done

# --- AC 1: a hub made by bin/init + bin/new holds no absolute path of the machine in a tracked file ---
(cd "$T" && HOME="$HOMEA" CLAUDE_HOME="$CHA" env -u HUB bin/init --persona staff-software-engineer --client "Acme" --owner "Sam" \
  --dest "$HA" --repo acme/app="$HOMEA/code/app" --remote-key "$HOMEA/.ssh/box" --brain-path "$HOMEA/notes" >/dev/null) || fail "init failed"
inA bin/new projects/extra --repo "$HOMEA/code/lib" >/dev/null || fail "bin/new failed"
inA bin/setup >/dev/null || fail "setup in A failed"
no_machine_paths "$HA" "$HOMEA" "AC1 init + new"
grep -qF "| (no remote) | ~/code/lib |" "$HA/projects/extra/ACCESS.md" || fail "AC4: the checkout under HOME is not stored as ~/: $(grep code/lib "$HA/projects/extra/ACCESS.md")"
grep -qF "| acme/app | ~/code/app |" "$HA/projects/app/ACCESS.md" || fail "AC4: bin/init stored the checkout under HOME with its full path"
grep -q '^output_folder = "_bmad-output"$' "$HA/_bmad/config.toml" || fail "AC1: output_folder is not relative"
for k in HUB_CLAUDE HUB_CLAUDE_CONFIG_DIR HUB_REMOTE_KEY HUB_BRAIN_PATHS; do
  grep -q "^$k=" "$HA/hub.conf" && fail "AC1: $k is in the committed hub.conf"
  grep -q "^$k=" "$HA/.local/hub.conf" || fail "AC1: $k is not in .local/hub.conf"; done
assert_eq "$(inA bash -c '. bin/lib.sh; echo "$HUB_CLAUDE_CONFIG_DIR|$(remote_key)|$HUB_BRAIN_PATHS"')" "$CHA|$HOMEA/.ssh/box|$HOMEA/notes" "AC1: machine keys read from .local/hub.conf"
hooks_ok "$HA" projects/extra "AC1 A"
gitq -C "$HA" commit -qm "hub" || fail "commit in A"

# --- AC 2: cloned to another path and HOME, one bin/setup there and it works ---
git clone -q "$HA" "$HB" || fail "clone"
[ -f "$HB/projects/extra/.mcp.json" ] || fail "AC2: .mcp.json (portable) is not in the clone"
[ -e "$HB/projects/extra/.claude/settings.local.json" ] && fail "AC2: settings.local.json was committed"
inB bin/setup >/dev/null || fail "setup in B failed"
hooks_ok "$HB" projects/extra "AC2 B"; hooks_ok "$HB" projects/app "AC2 B"
grep -qF "\"$HB/CLAUDE.md\"" "$HB/projects/extra/.claude/settings.local.json" || fail "AC2: B's settings do not exclude B's hub CLAUDE.md"
out=$(inB env DOCTOR_OFFLINE=1 bin/doctor); assert_eq "$?" "0" "AC2: doctor in B exits 0"
echo "$out" | grep -qE "^OK +hub memory link" || fail "AC2: doctor in B: [$out]"
echo "$out" | grep -E "^(WARN|MISSING) +(settings|hub.conf|hub memory)" && fail "AC2: doctor in B flags the hub"
[ -f "$HB/.local/hub.conf" ] || fail "AC2: setup wrote no .local/hub.conf in B"
grep -q "^HUB_CLAUDE_CONFIG_DIR=.*$HOMEA" "$HB/.local/hub.conf" && fail "AC2: A's config dir reached B"

# --- AC 3: bin/work in both clones leaves git status clean (no churn) ---
for side in inA inB; do
  o=$($side env WORK_NO_OPEN=1 bin/work --no-remote projects/extra 2>/dev/null) || fail "AC3: $side bin/work failed"
  rm -f "$(echo "$o" | sed -n "s/^launcher: //p")"
  o=$($side env WORK_NO_OPEN=1 bin/work --no-remote projects/app 2>/dev/null) || fail "AC3: $side bin/work (no repo) failed"
  rm -f "$(echo "$o" | sed -n "s/^launcher: //p")"
  st=$($side git status --porcelain); [ -z "$st" ] || fail "AC3: $side: bin/work left changes: $st"
done

# --- AC 4: ~/ checkouts resolve on both machines ---
assert_eq "$(inA bash -c '. bin/lib.sh; repos_of projects/extra')" "$HOMEA/code/lib" "AC4: repos_of in A"
assert_eq "$(inB bash -c '. bin/lib.sh; repos_of projects/extra')" "$HOMEB/code/lib" "AC4: repos_of in B"
inA env WORK_DRY=1 bin/work projects/extra | grep -qF "cd '$HOMEA/code/lib'" || fail "AC4: bin/work in A opens A's checkout"
inB env WORK_DRY=1 bin/work projects/extra | grep -qF "cd '$HOMEB/code/lib'" || fail "AC4: bin/work in B opens B's checkout"
o=$(inB bin/dispatch projects/extra 2>&1); echo "$o" | grep -qF "no BMAD in $HOMEB/code/lib" || fail "AC4: bin/dispatch in B: $o"
# a session started in the checkout (outside the folder) still gets the folder's hooks (with the hub's own path, since
# $CLAUDE_PROJECT_DIR is the checkout there) and its permissions
o=$(inB env WORK_NO_OPEN=1 bin/work --no-remote projects/extra 2>/dev/null); L=$(echo "$o" | sed -n "s/^launcher: //p")
MSF=$(sed -n "s/.* --settings '\([^']*\)'.*/\1/p" "$L" | head -1); [ -f "$MSF" ] || fail "AC4: no settings file in the launcher: $(cat "$L")"
python3 - "$MSF" "$HB" <<'PY' || fail "AC4: the session's settings lack the folder's hooks or permissions"
import json, sys
s, hub = json.load(open(sys.argv[1])), sys.argv[2]
cmds = [h["command"] for gs in s["hooks"].values() for g in gs for h in g["hooks"]]
assert len(cmds) == 7 and all(c.startswith('"%s"/bin/' % hub) for c in cmds), cmds
ask = s["permissions"]["ask"]
assert "Edit(//**/hub.conf)" in ask and "Write(//**/memory/users/**)" in ask and "Bash(*bin/dispatch --approve*)" in ask, ask
assert s["permissions"]["deny"] and s["enabledMcpjsonServers"] == ["playwright"] and "%s/CLAUDE.md" % hub in s["claudeMdExcludes"]
PY
rm -f "$L" "$MSF"
# a session started in the folder keeps "$CLAUDE_PROJECT_DIR"/../.. (the folder there), which runs the hub's scripts
inB bin/new projects/plain >/dev/null || fail "bin/new projects/plain in B"
o=$(inB env WORK_NO_OPEN=1 bin/work --no-remote projects/plain 2>/dev/null); L=$(echo "$o" | sed -n "s/^launcher: //p")
grep -qF "cd '$HB/projects/plain'" "$L" || fail "AC4: the plain folder's session does not start in it: $(cat "$L")"
MSF=$(sed -n "s/.* --settings '\([^']*\)'.*/\1/p" "$L" | head -1)
python3 - "$MSF" "$HB" <<'PY' || fail "AC4: the in-folder session's hooks are not the portable ones"
import json, sys
s, hub = json.load(open(sys.argv[1])), sys.argv[2]
cmds = [h["command"] for gs in s["hooks"].values() for g in gs for h in g["hooks"]]
assert len(cmds) == 7 and all(c.startswith('"$CLAUDE_PROJECT_DIR"/../../bin/') for c in cmds), cmds
assert "%s/CLAUDE.md" % hub in s["claudeMdExcludes"], s["claudeMdExcludes"]
PY
rm -f "$L" "$MSF"
# a checkout bin/work clones under $HOME is recorded as ~/... (gh stubbed: a local bare repo)
BARE="$W/newrepo.git"; git init -q --bare "$BARE"; GS="$W/ghstub"; mkdir -p "$GS"
printf '#!/bin/bash\n[ "$1 $2" = "repo clone" ] && exec git clone -q "%s" "$4"\nexit 1\n' "$BARE" > "$GS/gh"; chmod +x "$GS/gh"
awk '{print} /^\|---/ && !d {print "| acme/newrepo | /nonexistent/newrepo | main | Owner | none |"; d=1}' "$HB/projects/extra/ACCESS.md" > "$W/a.tmp" && mv "$W/a.tmp" "$HB/projects/extra/ACCESS.md"
o=$(inB env PATH="$GS:$PATH" AGENT_CODE_DIR="$HOMEB/Project" WORK_DRY=1 bin/work projects/extra acme/newrepo 2>&1 >/dev/null) || fail "the clone run failed: $o"
[ -d "$HOMEB/Project/newrepo/.git" ] || fail "the stub did not clone"
grep -qF "| acme/newrepo | ~/Project/newrepo |" "$HB/projects/extra/ACCESS.md" || fail "the cloned checkout is not recorded as ~/: $(grep newrepo "$HB/projects/extra/ACCESS.md")"
gitq -C "$HB" checkout -q -- projects/extra/ACCESS.md

# --- AC 5: .local/hub.conf wins over hub.conf; HUB_USER in the committed hub.conf is flagged ---
printf 'HUB_MODEL=opus\nHUB_EFFORT=low\n' >> "$HB/hub.conf"; printf 'HUB_EFFORT=high\n' >> "$HB/.local/hub.conf"
assert_eq "$(inB bash -c '. bin/lib.sh; echo "$HUB_MODEL $HUB_EFFORT"')" "opus high" "AC5: the local key wins, the rest is kept"
inB env DOCTOR_OFFLINE=1 bin/doctor | grep -q "HUB_USER" && fail "AC5: flagged with no HUB_USER"
echo "HUB_USER=sam" >> "$HB/hub.conf"
inB env DOCTOR_OFFLINE=1 bin/doctor | grep -qE "^WARN +hub.conf +.*HUB_USER.*\.local/hub.conf" || fail "AC5: HUB_USER in hub.conf not flagged"
sed -i.b '/^HUB_USER=/d' "$HB/hub.conf"; rm -f "$HB/hub.conf.b"; echo "HUB_USER=sam" >> "$HB/.local/hub.conf"
inB env DOCTOR_OFFLINE=1 bin/doctor | grep -q "HUB_USER" && fail "AC5: HUB_USER in .local/hub.conf flagged"
assert_eq "$(inB bash -c '. bin/lib.sh; hub_user')" "sam" "AC5: HUB_USER from .local/hub.conf"
# shared policy (provider choice, ownership, roles) stays the committed hub.conf's alone
printf 'HUB_PROVIDERS_ALLOWED=deepseek\nHUB_OWNED_BY_OWNER=1\n' >> "$HB/.local/hub.conf"
assert_eq "$(inB bash -c '. bin/lib.sh; echo "[${HUB_PROVIDERS_ALLOWED:-}${HUB_OWNED_BY_OWNER:-}]"')" "[]" "AC5: policy keys are never read from .local/hub.conf"
gitq -C "$HB" checkout -q -- hub.conf

# --- AC 6: an existing hub (the pre-I1 layout) is migrated by bin/setup, once, keeping what the person added ---
# the pre-I1 templates (tests/fixtures/pre-i1: templates/folder-*.json at 4bfc229, the commit before I1; checked against
# git when that commit is here, a shallow clone may not have it)
FX="$REPO/tests/fixtures/pre-i1"
for n in folder-settings.json folder-mcp.json; do
  if git -C "$REPO" cat-file -e "4bfc229:templates/$n" 2>/dev/null; then
    assert_eq "$(cat "$FX/$n")" "$(git -C "$REPO" show "4bfc229:templates/$n")" "the fixture is the pre-I1 $n"; fi; done
O="$W/old/hub"; git clone -q "$HA" "$O"; inO() { (cd "$O" && HOME="$HOMEA" HUB="$O" CLAUDE_HOME="$CHA" "$@"); }
# old_layout <hub> <home> <A's .local/hub.conf>: the tracked files as bin/new, bin/init and focus_hub_sync wrote them
# before I1 (the hub's path in settings.json and .mcp.json, the machine keys in hub.conf, a checkout under HOME in full),
# plus what a person added: an exclude of their own, a hook of their own, a server of their own; settings.local.json
# not ignored, .gitignore with no final newline
old_layout() { python3 - "$1" "$2" "$3" "$FX" <<'PY'
import glob, json, os, re, sys
hub, home, alocal, fx = sys.argv[1:]
def render(n, f): return json.loads(open(os.path.join(fx, n)).read().replace("{{HUB}}", hub).replace("{{FOLDER}}", f))
for d in glob.glob(os.path.join(hub, "*", "*", ".claude")):
    f = os.path.relpath(os.path.dirname(d), hub)
    s = render("folder-settings.json", f)
    s["claudeMdExcludes"] += ["/opt/team/CLAUDE.md", os.path.realpath(hub) + "/CLAUDE.md"]
    s["hooks"].setdefault("PostToolUse", []).append({"matcher": "Bash", "hooks": [{"type": "command", "command": "echo mine"}]})
    json.dump(s, open(os.path.join(d, "settings.json"), "w"), indent=2)
    l = os.path.join(d, "settings.local.json")
    if os.path.exists(l): os.unlink(l)
    m = render("folder-mcp.json", f); m["mcpServers"]["mine"] = {"command": "npx", "args": ["mine-server"]}
    json.dump(m, open(os.path.join(hub, f, ".mcp.json"), "w"), indent=2)
gi = os.path.join(hub, ".gitignore")
g = "".join(x for x in open(gi) if "settings.local.json" not in x and ".bak" not in x and ".tmp" not in x).rstrip("\n"); open(gi, "w").write(g)
local = open(alocal).read()
open(os.path.join(hub, "hub.conf"), "a").write("".join(x for x in local.splitlines(True) if re.match(r"HUB_[A-Z_]+=", x)))
c = os.path.join(hub, "_bmad", "config.toml"); s = open(c).read()
open(c, "w").write(s.replace('output_folder = "_bmad-output"', 'output_folder = "%s/_bmad-output"' % hub))
a = os.path.join(hub, "projects", "extra", "ACCESS.md"); s = open(a).read()
open(a, "w").write(s.replace("| ~/code/lib |", "| %s/code/lib |" % home))
PY
}
old_layout "$O" "$HOMEA" "$HA/.local/hub.conf" || fail "could not make the old layout"
(cd "$O" && git add -A && git commit -qm "old layout") || fail "commit the old layout"
git -C "$O" grep -qF "$O" || fail "the old layout holds no machine path (test setup)"
lastgi=$(tail -n 1 "$O/.gitignore")
# a second machine's clone of the old layout, before the first machine migrates
O2="$W/b/people/home/hubs/acme"; git clone -q "$O" "$O2"
inO2() { (cd "$O2" && HOME="$HOMEB" HUB="$O2" CLAUDE_HOME="$CHB" "$@"); }
head0=$(git -C "$O" rev-parse HEAD)
out=$(inO bin/setup 2>&1) || fail "AC6: migration failed: $out"
no_machine_paths "$O" "$HOMEA" "AC6 after the migration"
hooks_ok "$O" projects/extra "AC6"; hooks_ok "$O" projects/app "AC6"
# the person's own entries are kept where they were; the hub's own are the template's portable ones
python3 - "$O" <<'PY' || fail "AC6: the migration lost or changed the person's own entries"
import json, os, sys
hub = sys.argv[1]
for f in ("projects/extra", "projects/app"):
    s = json.load(open(os.path.join(hub, f, ".claude", "settings.json")))
    assert s["claudeMdExcludes"] == ["/opt/team/CLAUDE.md"], s["claudeMdExcludes"]
    assert {"type": "command", "command": "echo mine"} in [h for g in s["hooks"]["PostToolUse"] for h in g["hooks"]], s["hooks"]["PostToolUse"]
    ask = s["permissions"]["ask"]
    for a in ("Edit(//**/hub.conf)", "Edit(//**/memory/users/**)", "Write(//**/memory/users/**)", "Bash(*bin/dispatch --approve*)"):
        assert ask.count(a) == 1, (a, ask)
    m = json.load(open(os.path.join(hub, f, ".mcp.json")))["mcpServers"]
    assert m["mine"] == {"command": "npx", "args": ["mine-server"]}, m
PY
grep -q "^HUB_CLAUDE_CONFIG_DIR=" "$O/.local/hub.conf" || fail "AC6: this machine's keys did not move to .local/hub.conf"
git -C "$O" ls-files --error-unmatch projects/extra/.mcp.json >/dev/null 2>&1 || fail "AC6: .mcp.json is no longer tracked"
grep -qF "| ~/code/lib |" "$O/projects/extra/ACCESS.md" || fail "AC6: checkout not stored as ~/"
# .gitignore had no final newline: its last line is kept whole and the new lines follow
[ -n "$lastgi" ] && grep -qxF -- "$lastgi" "$O/.gitignore" || fail "AC6: .gitignore's last line was joined: $(tail -3 "$O/.gitignore")"
grep -qxF "projects/*/.claude/settings.local.json" "$O/.gitignore" || fail "AC6: .gitignore lacks settings.local.json"
# the migration is one commit of its own, and the tree is clean after it
assert_eq "$(git -C "$O" rev-list --count "$head0..HEAD")" "1" "AC6: one migration commit"
assert_eq "$(git -C "$O" status --porcelain)" "" "AC6: nothing left uncommitted"
echo "$out" | grep -q "^committed the migration" || fail "AC6: setup does not say it committed: $out"
snap() { (cd "$O" && git rev-parse HEAD; git status --porcelain; find . -path ./.git -prune -o -type f -print | LC_ALL=C sort | xargs cksum); }
s1=$(snap); out2=$(inO bin/setup 2>&1) || fail "AC6: second run failed"; s2=$(snap)
assert_eq "$s2" "$s1" "AC6: a second bin/setup changes nothing"
echo "$out2" | grep -qiE "migrat|commit" && fail "AC6: the second run migrated again: $out2"
# something already staged: no commit, the command is printed
O3="$W/old/third"; git clone -q "$O" "$O3"; git -C "$O3" reset -q --hard "$head0"
echo note > "$O3/NOTE.md"; git -C "$O3" add NOTE.md
out=$( (cd "$O3" && HOME="$HOMEA" HUB="$O3" CLAUDE_HOME="$CHA" bin/setup 2>&1) ) || fail "AC6: setup with a staged file failed: $out"
assert_eq "$(git -C "$O3" rev-parse HEAD)" "$head0" "AC6: nothing committed over a staged file"
echo "$out" | grep -q "^commit the migration .*git -C .* commit -m" || fail "AC6: no command printed: $out"
# the second machine: before pulling, A's paths are never copied (printed to set by hand); after pulling, nothing of A's
# (on one disk, A's home is moved away while B runs: on B's machine it does not exist)
mv "$W/a" "$W/a.away"; out=$(inO2 bin/setup 2>&1); rc=$?; mv "$W/a.away" "$W/a"
[ "$rc" = 0 ] || fail "AC6: setup on the second machine failed: $out"
grep -qF "$HOMEA" "$O2/.local/hub.conf" && fail "AC6: A's paths reached B's .local/hub.conf: $(cat "$O2/.local/hub.conf")"
echo "$out" | grep -q "^set by hand: HUB_CLAUDE_CONFIG_DIR=" || fail "AC6: A's config dir is not printed to set by hand: $out"
no_machine_paths "$O2" "$HOMEB" "AC6 second machine"   # (A's checkout cell stays A's until A's migration is pulled)
hooks_ok "$O2" projects/extra "AC6 second machine"
git -C "$O2" reset -q --hard "$head0" && git -C "$O2" pull -q --no-rebase "$O" HEAD >/dev/null 2>&1 || fail "AC6: B could not pull A's migration"
mv "$W/a" "$W/a.away"; out=$(inO2 bin/setup 2>&1); rc=$?; mv "$W/a.away" "$W/a"
[ "$rc" = 0 ] || fail "AC6: setup after the pull failed: $out"
grep -qF "$HOMEA" "$O2/.local/hub.conf" && fail "AC6: A's paths reached B after the pull"
no_machine_paths "$O2" "$HOMEB" "AC6 after the pull"; no_machine_paths "$O2" "$HOMEA" "AC6 after the pull (A's paths)"
hooks_ok "$O2" projects/extra "AC6 after the pull"; hooks_ok "$O2" projects/app "AC6 after the pull"
grep -qF "\"$O\"" "$O2/projects/extra/.claude/settings.local.json" && fail "AC6: A's hub path is in B's settings.local.json"
assert_eq "$(git -C "$O2" status --porcelain)" "" "AC6: B is clean after the pull and bin/setup"
echo ok
