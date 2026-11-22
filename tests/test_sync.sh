#!/bin/bash
. "$(dirname "$0")/helpers.sh"
make_hub; cd "$HUB"; git config core.hooksPath .githooks; git add -A >/dev/null 2>&1; git commit -q --no-verify -m base >/dev/null 2>&1
echo "x" >> memory/MEMORY.md; mkdir -p repos/y && echo c > repos/y/z.py
bin/sync | grep -q "memory/MEMORY.md" || fail "review lists the change"
[ -z "$(git diff --cached --name-only)" ] || fail "review mode left things staged"
bin/sync --yes >/dev/null || fail "sync --yes failed"
git log -1 --name-only --pretty=format: | grep -q "^repos/" && fail "repos/ committed"
git log -1 --pretty=%s | grep -q "^sync " || fail "commit message"
# review mode lists untracked paths under .claude/ so they are not swept in unseen
mkdir -p .claude/skills/zz && echo s > .claude/skills/zz/SKILL.md; echo q >> memory/MEMORY.md
out=$(bin/sync); echo "$out" | tail -1 | grep -q "untracked under .claude/.*skills/zz" || fail "review does not note untracked .claude paths"
bin/sync --yes >/dev/null || fail "sync --yes failed"
# files staged by someone else outside the hub paths: never committed, never unstaged
echo "y" >> memory/MEMORY.md; echo s > scratch.txt; echo more >> other.txt; git add scratch.txt other.txt
bin/sync | grep -q "memory/MEMORY.md" || fail "review lists the pending hub change while others are staged"
git diff --cached --name-only | grep -qx scratch.txt || fail "review altered the index"
bin/sync --yes >/dev/null || fail "sync --yes with other staged files failed"
git show --name-only --pretty=format: HEAD | grep -qx memory/MEMORY.md || fail "hub change not committed"
git show --name-only --pretty=format: HEAD | grep -qE "^(scratch|other)\.txt$" && fail "non-hub staged file committed"
git diff --cached --name-only | grep -qx scratch.txt || fail "scratch.txt lost its staging"
git diff --cached --name-only | grep -qx other.txt || fail "other.txt lost its staging"
# a user's local Claude settings stay on this Mac (the hub's own .gitignore, not this Mac's global one)
git config core.excludesFile /dev/null
echo '{"permissions":{}}' > .claude/settings.local.json; echo w >> memory/MEMORY.md
bin/sync --yes >/dev/null 2>&1
git ls-files --error-unmatch .claude/settings.local.json >/dev/null 2>&1 && fail "settings.local.json committed"
# agents' worktrees under .claude/ (whole copies of the hub) and rendered BMAD workflows are never synced
mkdir -p .claude/worktrees/w1/bin _bmad/render/x; echo copy > .claude/worktrees/w1/bin/work; echo r > _bmad/render/x/workflow.md
echo v >> memory/MEMORY.md; bin/sync --yes >/dev/null 2>&1
git ls-files | grep -q '^\.claude/worktrees/' && fail "a worktree under .claude/worktrees was committed"
git ls-files | grep -q '^_bmad/render/' && fail "_bmad/render was committed"
bin/sync 2>/dev/null | grep -q 'worktrees' && fail "the review lists .claude/worktrees as something --yes would include"
# unreachable remote: the commit stays, the failure is reported with exit 1
echo "z" >> memory/MEMORY.md; git remote add origin /nonexistent; git config push.default current
out=$(bin/sync --yes 2>&1); rc=$?
[ "$rc" = 1 ] || fail "unreachable remote: want exit 1, got $rc"
echo "$out" | grep -q "push failed" || fail "push failure not reported"
echo "$out" | grep -q "does not appear to be a git repository" || fail "push did not fail on the unreachable remote"
echo "$out" | grep -q "synced:" && fail "reported synced after a failed push"
git log -1 --pretty=%s | grep -q "^sync " || fail "commit missing after push failure"
# --auto: unattended sync for the 30-minute job and focus session ends
S="$(mktemp -d)"; printf '#!/bin/bash\n[ "$1" = detect ] && exit ${DETECT_RC:-0}\nexit 0\n' > "$S/gitleaks"; chmod +x "$S/gitleaks"; P0="$PATH"; export PATH="$S:/usr/bin:/bin"
B="$(mktemp -d)/hub.git"; git init -q --bare "$B"; git remote set-url origin "$B"; git push -q -u origin HEAD 2>/dev/null || fail "seed push"
L="$AGENT_SYNC_LOG"; K="$AGENT_SYNC_LOCK"
echo a1 >> memory/MEMORY.md; bin/sync --auto; assert_eq "$?" "0" "auto sync exit 0"
assert_eq "$(git rev-parse HEAD)" "$(git --git-dir="$B" rev-parse HEAD)" "auto sync pushed"
git log -1 --pretty=%s | grep -q "^sync " || fail "auto commit message"
grep -q "synced: .*(1 file(s))" "$L" || fail "auto sync logged"
git diff --cached --name-only | grep -qx scratch.txt || fail "auto sync unstaged someone else's file"
h=$(git rev-parse HEAD); out=$(bin/sync --auto); assert_eq "$?" "0" "nothing to sync exit 0"
assert_eq "$out" "" "auto mode is quiet"; assert_eq "$(git rev-parse HEAD)" "$h" "nothing to sync, no commit"
assert_eq "$(tail -1 "$L" | cut -d' ' -f2-)" "nothing to sync" "an idle run still logs a line"
# hooks not wired (bin/setup never ran): refused, nothing committed
git config --unset core.hooksPath; echo h1 >> memory/MEMORY.md; bin/sync --auto; assert_eq "$?" "1" "no hooksPath: exit 1"
assert_eq "$(git rev-parse HEAD)" "$h" "no hooksPath: no commit"; grep -q "refused: core.hooksPath" "$L" || fail "hooksPath refusal logged"
git config core.hooksPath .githooks; bin/sync --auto >/dev/null
# a commit made but not pushed earlier (push failed) goes out on the next run
echo a2 >> memory/MEMORY.md; git commit -q --no-verify -m local -- memory/MEMORY.md; bin/sync --auto
assert_eq "$(git --git-dir="$B" rev-parse HEAD)" "$(git rev-parse HEAD)" "earlier unpushed commit pushed"
# lock held by another run: skipped, nothing committed
# an earlier commit with a secret (made with --no-verify) is scanned before the push and never pushed
echo s1 >> memory/MEMORY.md; git commit -q --no-verify -m leak -- memory/MEMORY.md; r=$(git --git-dir="$B" rev-parse HEAD)
DETECT_RC=1 bin/sync --auto; assert_eq "$?" "1" "secret in commits to push: exit 1"
assert_eq "$(git --git-dir="$B" rev-parse HEAD)" "$r" "secret commit not pushed"; grep -q "refused: gitleaks found a secret in the commits to push" "$L" || fail "push scan refusal logged"
bin/sync --auto >/dev/null
mkdir "$K"; echo a3 >> memory/MEMORY.md; h=$(git rev-parse HEAD); bin/sync --auto; assert_eq "$?" "0" "locked: exit 0"
assert_eq "$(git rev-parse HEAD)" "$h" "locked: no commit"; grep -q "skipped: another sync is running" "$L" || fail "lock skip logged"
[ -d "$K" ] || fail "skipped run removed someone else's lock"
# stale lock (no pid file, older than the 10 s grace: a run killed before it wrote one) is removed and the run goes on
touch -t 202001010000 "$K"; bin/sync --auto; [ -d "$K" ] && fail "lock left behind"
grep -q "removed stale lock" "$L" || fail "stale lock not logged"; assert_eq "$(git --git-dir="$B" rev-parse HEAD)" "$(git rev-parse HEAD)" "synced after stale lock"
# lock whose owner is gone (dead pid) is removed; a live owner's lock is kept
mkdir "$K"; sh -c 'echo $$ > '"$K"'/pid'; echo a4 >> memory/MEMORY.md; bin/sync --auto; [ -d "$K" ] && fail "dead owner's lock kept"
mkdir "$K"; sleep 30 & sp=$!; echo $sp > "$K/pid"; echo a5 >> memory/MEMORY.md; h=$(git rev-parse HEAD); bin/sync --auto
assert_eq "$(git rev-parse HEAD)" "$h" "live owner: skipped"; [ -d "$K" ] || fail "live owner's lock removed"; kill $sp; wait $sp 2>/dev/null; rm -rf "$K"
# git busy: index.lock, rebase, merge -> skipped
for busy in index.lock rebase-merge MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD; do
  case $busy in rebase-merge) mkdir .git/$busy ;; *) touch .git/$busy ;; esac
  echo "b $busy" >> memory/MEMORY.md; h=$(git rev-parse HEAD); bin/sync --auto; assert_eq "$?" "0" "busy $busy: exit 0"
  assert_eq "$(git rev-parse HEAD)" "$h" "busy $busy: no commit"; rm -rf .git/$busy
done
grep -q "skipped: git is busy" "$L" || fail "busy skip logged"
bin/sync --auto >/dev/null
# no gitleaks: refused, nothing committed, exit 1
rm "$S/gitleaks"; echo c1 >> memory/MEMORY.md; h=$(git rev-parse HEAD); bin/sync --auto; assert_eq "$?" "1" "no gitleaks: exit 1"
assert_eq "$(git rev-parse HEAD)" "$h" "no gitleaks: no commit"; grep -q "refused: gitleaks not installed" "$L" || fail "gitleaks refusal logged"
# gitleaks finds a secret (pre-commit refuses): exit 1, nothing committed, the files are not left staged
printf '#!/bin/bash\nexit 1\n' > "$S/gitleaks"; chmod +x "$S/gitleaks"; bin/sync --auto; assert_eq "$?" "1" "secret found: exit 1"
assert_eq "$(git rev-parse HEAD)" "$h" "secret found: no commit"; grep -q "failed: commit refused" "$L" || fail "refused commit logged"
git diff --cached --name-only | grep -qx memory/MEMORY.md && fail "refused files left staged"
printf '#!/bin/bash\nexit 0\n' > "$S/gitleaks"; bin/sync --auto >/dev/null
# the remote moved on: rebased once and pushed, both commits on the remote, never forced
C="$(mktemp -d)/c"; git clone -q "$B" "$C"; git -C "$C" config user.name t; git -C "$C" config user.email t@t
echo other > "$C/docs/from-elsewhere.md"; git -C "$C" add docs/from-elsewhere.md; git -C "$C" commit -qm elsewhere; git -C "$C" push -q
# behind with other files staged: no rebase (autostash would unstage them), staging kept, commit kept, exit 1
echo d0 >> memory/MEMORY.md; bin/sync --auto; assert_eq "$?" "1" "behind + other staged: exit 1"
grep -q "other files are staged, so no rebase" "$L" || fail "staged-files rebase skip logged"
git diff --cached --name-only | grep -qx other.txt || fail "other.txt lost its staging"
git --git-dir="$B" log --pretty=%s | grep -qx elsewhere || fail "remote commit lost"
git reset -q -- scratch.txt other.txt
echo d1 >> memory/MEMORY.md; bin/sync --auto; assert_eq "$?" "0" "behind: exit 0"
git --git-dir="$B" log --pretty=%s | grep -qx elsewhere || fail "remote commit lost"
assert_eq "$(git --git-dir="$B" rev-parse HEAD)" "$(git rev-parse HEAD)" "behind: pushed after rebase"
[ -f docs/from-elsewhere.md ] || fail "remote change not pulled"; grep -q "synced after rebase" "$L" || fail "rebase logged"
# unreachable remote: exit 1, commit kept, logged
git remote set-url origin /nonexistent; echo e1 >> memory/MEMORY.md; bin/sync --auto; assert_eq "$?" "1" "unreachable: exit 1"
git log -1 --pretty=%s | grep -q "^sync " || fail "unreachable: commit not kept"; grep -q "failed: push failed" "$L" || fail "push failure logged"
[ -d .git/rebase-merge ] || [ -d .git/rebase-apply ] && fail "rebase left in progress"
[ -d "$K" ] && fail "lock left after a failed run"
# HUB_AUTO_SYNC=0 in hub.conf: an installed job (or a session end) does nothing, exit 0
echo HUB_AUTO_SYNC=0 > hub.conf; echo f1 >> memory/MEMORY.md; h=$(git rev-parse HEAD); bin/sync --auto; assert_eq "$?" "0" "auto sync off: exit 0"
assert_eq "$(git rev-parse HEAD)" "$h" "auto sync off: no commit"; grep -q "skipped: auto sync is off" "$L" || fail "auto sync off logged"
rm -f hub.conf
export PATH="$P0"
# --yes takes the same lock as --auto and waits for it (AGENT_LOCK_WAIT); review mode takes no lock
make_hub; cd "$HUB"; git add -A >/dev/null 2>&1; git commit -q --no-verify -m base >/dev/null 2>&1
export AGENT_LOCK_WAIT=3; K="$AGENT_SYNC_LOCK"; sleep 30 & sp=$!; trap 'kill $sp 2>/dev/null' EXIT
CHECK=sync_yes_waits_for_lock
mkdir "$K"; echo $sp > "$K/pid"; (sleep 1; date +%s > "$K.released"; rm -rf "$K") & r=$!
echo y1 >> memory/MEMORY.md; AGENT_LOCK_WAIT=5 bin/sync --yes >/dev/null; rc=$?; wait $r
assert_eq "$rc" 0 "$CHECK: exit"; git log -1 --pretty=%s | grep -q "^sync " || fail "$CHECK: not committed"
[ "$(git log -1 --format=%ct)" -ge "$(cat "$K.released")" ] || fail "$CHECK: committed before the lock was released"
[ -d "$K" ] && fail "$CHECK: lock left behind"
CHECK=sync_yes_busy_fails
mkdir "$K"; echo $sp > "$K/pid"; echo y2 >> memory/MEMORY.md; h=$(git rev-parse HEAD)
bin/sync --yes > /dev/null 2> "$K.err"; assert_eq "$?" 1 "$CHECK: exit"
grep -q "another sync is running" "$K.err" || fail "$CHECK: no 'another sync is running' on stderr"
assert_eq "$(git rev-parse HEAD)" "$h" "$CHECK: committed anyway"; [ -d "$K" ] || fail "$CHECK: other process's lock removed"
git diff --cached --name-only | grep -qx memory/MEMORY.md && fail "$CHECK: files left staged"
CHECK=sync_yes_live_old_kept
# a live owner's lock (pid only) is kept however old
touch -t 202001010000 "$K"; h=$(git rev-parse HEAD)
bin/sync --yes > /dev/null 2> "$K.err"; assert_eq "$?" 1 "$CHECK: exit"
grep -q "another sync is running" "$K.err" || fail "$CHECK: no 'another sync is running' on stderr"
assert_eq "$(git rev-parse HEAD)" "$h" "$CHECK: committed anyway"
[ -d "$K" ] || fail "$CHECK: live owner's old lock removed"; assert_eq "$(cat "$K/pid" 2>/dev/null)" "$sp" "$CHECK: lock owner"
CHECK=sync_yes_uses_lock_wait
# --yes waits AGENT_LOCK_WAIT, never the hook's AGENT_HOOK_LOCK_WAIT
(sleep 6; rm -rf "$K") & r=$!
AGENT_HOOK_LOCK_WAIT=1 AGENT_LOCK_WAIT=10 bin/sync --yes >/dev/null 2>&1; rc=$?; wait $r
assert_eq "$rc" 0 "$CHECK: exit"; git log -1 --pretty=%s | grep -q "^sync " || fail "$CHECK: not committed"
mkdir "$K"; echo $sp > "$K/pid"; echo y4 >> memory/MEMORY.md   # the lock and a pending change for the next check
CHECK=sync_review_takes_no_lock
out=$(bin/sync); assert_eq "$?" 0 "$CHECK: exit"; echo "$out" | grep -q "memory/MEMORY.md" || fail "$CHECK: pending change not listed"
[ -d "$K" ] && [ "$(cat "$K/pid")" = "$sp" ] || fail "$CHECK: review touched the lock"
CHECK=sync_yes_only_owner_releases
# while --yes holds the lock, another live process's pid lands in the pid file (from the pre-commit hook): --yes leaves it
rm -rf "$K"; D="$(mktemp -d)"; git config core.hooksPath "$D"
printf '#!/bin/bash\necho %s > "%s/pid"\n' "$sp" "$K" > "$D/pre-commit"; chmod +x "$D/pre-commit"
echo y3 >> memory/MEMORY.md; bin/sync --yes >/dev/null; assert_eq "$?" 0 "$CHECK: exit"
git log -1 --pretty=%s | grep -q "^sync " || fail "$CHECK: not committed"
[ -d "$K" ] || fail "$CHECK: lock removed although its pid file named another live process"
assert_eq "$(cat "$K/pid" 2>/dev/null)" "$sp" "$CHECK: lock owner"
echo ok
