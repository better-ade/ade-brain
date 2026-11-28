#!/bin/bash
# bin/adopt (story I2, .ade/context/adopt.md): a hub taken over (--handover), joined (--share) or copied (--clone), each
# run in a fresh clone of the source hub. One function per acceptance criterion; AC6 is tests/e2e_adopt.sh.
. "$(dirname "$0")/helpers.sh"
make_hub; T="$HUB"; W="$(mktemp -d)"; stub_security
export HOME="$W/home"; mkdir -p "$HOME"   # ~/.agent-hub/<name> (AC4) is this test's, never the tester's
S="$W/src/hub"; R="$W/remote.git"; CO="$W/infra"; mkdir -p "$CO"
# the source hub: owner "Kim Old" (written by bin/init and bin/new, a repo row's "who merges" too), a learned fact of
# hers and one of a sharer's, a folder's STATE.md with work in it, a journal; pushed to a bare remote
(cd "$T" && env -u HUB bin/init --persona tech-lead --client "Acme" --owner "Kim Old" --name acme-lead --dest "$S" \
  --repo acme/infra="$CO" --secret grafana-token >/dev/null) || fail "init the source hub"
(cd "$S" && HUB="$S" bin/new ops/extra >/dev/null) || fail "bin/new in the source hub"
mkdir -p "$S/memory/users/kim-old" "$S/memory/users/sam"
echo "- 2026-11-20: Kim's fact" > "$S/memory/users/kim-old/profile.md"; echo "- 2026-11-20: Sam's fact" > "$S/memory/users/sam/profile.md"
F1="$(cd "$S" && ls -d projects/* ops/* 2>/dev/null | head -1)"; printf -- '- deploy pending\n' >> "$S/$F1/STATE.md"
git -C "$S" config user.name k; git -C "$S" config user.email k@k
git -C "$S" add -A && git -C "$S" commit -qm hub && git init -q --bare "$R" && git -C "$S" remote add origin "$R" &&
  git -C "$S" push -q -u origin main || fail "push the source hub"
grep -q "Kim Old" "$S/CLAUDE.md" "$S/ACCESS.md" "$S/README.md" "$S/.claude/agents/tech-lead.md" "$S/$F1/ACCESS.md" ||
  fail "the source names its owner where bin/init and bin/new write it"
n=0
fresh() { n=$((n + 1)); C="$W/b$n/hub"; git clone -q "$R" "$C" || fail "clone $n"; git -C "$C" config user.name b; git -C "$C" config user.email b@b; }
adopt() { (cd "$C" && HUB="$C" bin/adopt "$@"); }
# the files bin/init and bin/new write the owner's name into (hub.conf's HUB_OWNER included)
owner_files() { (cd "$C" && ls hub.conf CLAUDE.md ACCESS.md README.md .claude/agents/*.md projects/*/ACCESS.md ops/*/ACCESS.md 2>/dev/null); }
cfg() { (. "$C/hub.conf"; eval "echo \"\$$1\""); }
unchanged() { assert_eq "$(git -C "$C" rev-parse HEAD)" "$(git -C "$S" rev-parse HEAD)" "$1: HEAD"
  assert_eq "$(git -C "$C" status --porcelain | grep -v '^?? stray$')" "" "$1: the tree"; assert_eq "$(git -C "$C" remote)" origin "$1: the remote"; }

adopt_handover_rewrites_the_owner() {
  fresh; out=$(adopt --handover --owner "Bo New") || fail "handover: $out"
  assert_eq "$(cfg HUB_OWNER)" "Bo New" "HUB_OWNER"
  for f in $(owner_files); do grep -q "Kim Old" "$C/$f" && fail "handover: $f still names the old owner"; done
  grep -q "working for Bo New" "$C/CLAUDE.md" || fail "handover: CLAUDE.md names the new owner"
  grep -q "Staged for Bo New to run" "$C/$F1/ACCESS.md" || fail "handover: a folder's ACCESS.md names the new owner"
  grep -q "| acme/infra | .* | Bo New |" "$C/ACCESS.md" || fail "handover: the repo row's who merges"
  [ -e "$C/memory/users/kim-old" ] && fail "handover: the old owner's memory is still in the tree"
  git -C "$C" ls-files memory/users/kim-old | grep -q . && fail "handover: the old owner's memory is still tracked"
  [ -f "$C/memory/users/sam/profile.md" ] || fail "handover: another person's memory was removed"
  echo "$out" | grep -q "git history" || fail "handover: does not say the memory stays in git history: $out"
  assert_eq "$(cat "$C"/journal/*.md | grep -c "^Handover: ")" 1 "handover: one journal line"
  grep -h "^Handover: " "$C"/journal/*.md | grep -q "Kim Old.*Bo New" || fail "handover: the journal line names both"
  assert_eq "$(git -C "$C" rev-list --count HEAD)" 2 "handover: one commit of its own"
  assert_eq "$(git -C "$C" status --porcelain)" "" "handover: nothing left uncommitted"
  echo "$out" | grep -q "transfer" || fail "handover: the GitHub repo transfer is not in the list: $out"
  # the old owner's memory folder when the name gives none: the only other person's, else --from
  fresh; git -C "$C" mv memory/users/kim-old memory/users/kimo && git -C "$C" commit -qm mv
  adopt --handover --owner "Bo New" >/dev/null 2>&1; assert_eq "$?" 2 "handover: two candidate memory folders, no --from"
  assert_eq "$(git -C "$C" status --porcelain)" "" "handover refused: nothing changed"
  adopt --handover --owner "Bo New" --from kimo >/dev/null || fail "handover --from"
  [ -e "$C/memory/users/kimo" ] && fail "handover --from: kimo still there"; [ -d "$C/memory/users/sam" ] || fail "handover --from: sam removed"
}

adopt_share_changes_nothing() {
  fresh; out=$(adopt --share) || fail "share: $out"; unchanged share
  assert_eq "$(cfg HUB_OWNER)" "Kim Old" "share: the owner stays"
  echo "$out" | grep -qF "Key missing here: grafana-token" || fail "share: the list does not name the missing key: $out"
  echo "$out" | grep -q "ade setup --telegram" || fail "share: no bot step: $out"
  echo "$out" | grep -q "bin/schedule install" || fail "share: no schedule step: $out"
  printf 'x\n' | bin_secret_put grafana-token
  out=$(adopt --share) || fail "share again"; echo "$out" | grep -qF "Key missing here: grafana-token" && fail "share: a stored key is listed as missing: $out"
  "$C/bin/secret" --forget grafana-token >/dev/null 2>&1; true
}
bin_secret_put() { (cd "$C" && HUB="$C" bin/secret --set "$1" >/dev/null 2>&1) || fail "store $1"; }

adopt_clone_makes_a_new_hub() {
  fresh; out=$(adopt --clone --owner "Bo New" --name n2) || fail "clone: $out"
  assert_eq "$(cfg HUB_NAME)" n2 "clone: HUB_NAME"; assert_eq "$(cfg HUB_KEYCHAIN_SERVICE)" n2 "clone: Keychain service"
  assert_eq "$(cfg HUB_OWNER)" "Bo New" "clone: HUB_OWNER"
  for f in $(owner_files); do grep -qE "Kim Old|acme-lead" "$C/$f" && fail "clone: $f still names the old owner or name"; done
  grep -q 'project_name = "n2"' "$C/_bmad/config.toml" || fail "clone: BMAD project name"
  assert_eq "$(git -C "$C" rev-list --count HEAD)" 1 "clone: one commit"; assert_eq "$(git -C "$C" remote)" "" "clone: no remote"
  assert_eq "$(git -C "$C" status --porcelain)" "" "clone: committed"
  assert_eq "$(git -C "$C" config core.hooksPath)" .githooks "clone: the hub's hooks"
  [ -n "$(ls "$C"/journal/[0-9]*.md 2>/dev/null)" ] && fail "clone: a journal is left"
  [ -e "$C/memory/users" ] && fail "clone: memory/users is left"
  for st in "$C"/projects/*/STATE.md "$C"/ops/*/STATE.md; do f="${st#"$C"/}"; f="${f%/STATE.md}"
    assert_eq "$(cat "$st")" "$(sed "s/{{NAME}}/${f#*/}/" "$T/templates/STATE.md")" "clone: $f/STATE.md reset"; done
  assert_eq "$(cat "$C/.ade/session.md")" "# Session journal" "clone: .ade/session.md emptied"
  diff -r "$S/personas" "$C/personas" >/dev/null || fail "clone: personas differ"
  assert_eq "$(cd "$C" && ls -d projects/* ops/*)" "$(cd "$S" && ls -d projects/* ops/*)" "clone: the folders"
  for f in $(cd "$S" && ls -d projects/* ops/*); do cmp -s "$S/$f/CLAUDE.md" "$C/$f/CLAUDE.md" || fail "clone: $f/CLAUDE.md differs"; done
  cmp -s "$S/.ade/rules.md" "$C/.ade/rules.md" || fail "clone: the rules differ"
  echo "$out" | grep -q "bin/keys" || fail "clone: no keys step: $out"
}

adopt_clone_refuses_a_name_in_use() {
  fresh; mkdir -p "$HOME/.agent-hub/n3"
  out=$(adopt --clone --owner "Bo New" --name n3 2>&1); assert_eq "$?" 2 "clone onto a name in use"
  echo "$out" | grep -q "$HOME/.agent-hub/n3" || fail "the refusal names the reason: $out"; unchanged "name in use"
}

adopt_refuses_and_changes_nothing() {
  fresh; touch "$C/stray"
  for m in "--share" "--handover --owner X" "--clone --owner X --name n4"; do
    adopt $m >/dev/null 2>&1; [ $? -ne 0 ] || fail "a dirty tree: $m ran"
    out=$(adopt $m 2>&1); echo "$out" | grep -qi "clean" || fail "dirty tree, $m: no reason: $out"; unchanged "dirty $m"; done
  rm -f "$C/stray"
  for a in "" "--bogus" "--handover" "--handover --owner" "--clone --owner X" "--clone --name n4" "--share --owner X" \
           "--handover --owner X --name n5" "--clone --owner X --name Bad_Name" "--clone --owner X --name acme-lead"; do
    adopt $a >/dev/null 2>&1; assert_eq "$?" 2 "refused: [$a]"; unchanged "refused [$a]"; done
  # a clone whose commits are on no remote would lose them: refused
  echo x > "$C/local.md"; git -C "$C" add local.md && git -C "$C" commit -qm local
  adopt --clone --owner X --name n6 >/dev/null 2>&1; assert_eq "$?" 2 "clone with unpushed commits"
  git -C "$C" log --oneline | grep -q local || fail "the unpushed commit is gone"
}

adopt_prints_the_keys_steps() {
  fresh; out=$(adopt --share)
  echo "$out" | grep -qxF 'Keys: bin/keys share <new person> --all   (they run: bin/keys receive)' || fail "share: the keys line: $out"
  echo "$out" | grep -qF 'Replace the shared keys at their source' && fail "share: the old owner's keys line"
  fresh; out=$(adopt --handover --owner "Bo New")
  echo "$out" | grep -qxF 'Keys: bin/keys share <new person> --all   (they run: bin/keys receive)' || fail "handover: the keys line: $out"
  echo "$out" | grep -qxF 'Replace the shared keys at their source (each provider'"'"'s console), then bin/keys forget <tool> for each.' ||
    fail "handover: the old owner's keys line: $out"
}

# fix round: what a clone would lose, a rule line the rewrite cannot reach, a rollback after the first write
pushed() { git -C "$C" update-ref refs/remotes/origin/main HEAD; }   # the clone's commit counts as on the remote
same() { assert_eq "$(git -C "$C" rev-parse HEAD)" "$1" "$2: HEAD"; assert_eq "$(git -C "$C" status --porcelain)" "" "$2: the tree"
  assert_eq "$(git -C "$C" remote)" origin "$2: the remote"; [ -d "$C/.git" ] || fail "$2: .git"; }
adopt_clone_keeps_unpushed_work() {
  fresh; git -C "$C" checkout -qb wip && echo w > "$C/w.md" && git -C "$C" add w.md && git -C "$C" commit -qm wip && git -C "$C" checkout -q main
  out=$(adopt --clone --owner X --name n8 2>&1); assert_eq "$?" 2 "clone with an unpushed branch"
  echo "$out" | grep -q "wip" || fail "the refusal names the branch: $out"; unchanged "unpushed branch"
  fresh; echo s >> "$C/README.md"; git -C "$C" stash -q
  out=$(adopt --clone --owner X --name n8 2>&1); assert_eq "$?" 2 "clone with a stash"
  echo "$out" | grep -qi "stash" || fail "the refusal names the stash: $out"; unchanged "stash"
  git -C "$C" rev-parse -q --verify refs/stash >/dev/null || fail "the stash is gone"
}
adopt_refuses_a_rule_it_cannot_rewrite() {
  for m in "--handover --owner Bo" "--clone --owner Bo --name n9"; do
    fresh; echo "Only Kim Old approves a merge." >> "$C/CLAUDE.md"; git -C "$C" commit -qam edit; pushed; h=$(git -C "$C" rev-parse HEAD)
    out=$(adopt $m 2>&1); assert_eq "$?" 1 "edited owner line: $m"
    echo "$out" | grep -q "CLAUDE.md:[0-9]" || fail "edited owner line, $m: no file:line: $out"; same "$h" "edited $m"
  done
}
adopt_refuses_table_breaking_values() {
  fresh; for o in "A|B" 'A`B' $'A\nB'; do
    adopt --handover --owner "$o" >/dev/null 2>&1; assert_eq "$?" 2 "owner [$o]"
    adopt --clone --owner "$o" --name n10 >/dev/null 2>&1; assert_eq "$?" 2 "clone owner [$o]"; unchanged "owner [$o]"; done
  for nm in "a|b" 'a`b' $'a\nb'; do adopt --clone --owner X --name "$nm" >/dev/null 2>&1; assert_eq "$?" 2 "name [$nm]"; done
}
adopt_clone_adds_a_missing_name() {
  fresh; grep -v '^HUB_NAME=' "$C/hub.conf" > "$C/h" && mv "$C/h" "$C/hub.conf"; git -C "$C" commit -qam noname; pushed
  adopt --clone --owner "Bo New" --name n11 >/dev/null 2>&1 || fail "clone without HUB_NAME"
  assert_eq "$(grep -c '^HUB_NAME=' "$C/hub.conf")" 1 "clone: HUB_NAME appended"; assert_eq "$(cfg HUB_NAME)" n11 "clone: HUB_NAME value"
}
adopt_clone_frees_the_old_claim() {
  fresh; d="$HOME/.agent-hub/acme-lead"; mkdir -p "$d"; (cd "$C" && pwd -P) > "$d/hub-path"
  adopt --clone --owner "Bo New" --name n12 >/dev/null 2>&1 || fail "clone n12"; [ -e "$d/hub-path" ] && fail "clone: the old name's claim on this hub is left"
  fresh; echo "$W/elsewhere" > "$d/hub-path"
  adopt --clone --owner "Bo New" --name n13 >/dev/null 2>&1 || fail "clone n13"
  assert_eq "$(cat "$d/hub-path")" "$W/elsewhere" "clone: another hub's claim is kept"; rm -rf "$d"
}
adopt_rolls_back_a_failed_commit() {
  B="$W/badbin"; mkdir -p "$B"; printf '#!/bin/bash\nexit 1\n' > "$B/gitleaks"; chmod +x "$B/gitleaks"
  for m in "--handover --owner Bo" "--clone --owner Bo --name n14"; do
    fresh; git -C "$C" config core.hooksPath .githooks; h=$(git -C "$C" rev-parse HEAD)
    (cd "$C" && PATH="$B:$PATH" HUB="$C" bin/adopt $m >/dev/null 2>&1); assert_eq "$?" 1 "failed commit: $m"
    same "$h" "rolled back $m"; [ -d "$C/memory/users/kim-old" ] || fail "rolled back $m: memory"
    ls -d "$W"/b$n/.adopt-git.* >/dev/null 2>&1 && fail "rolled back $m: a backup is left"
  done
  fresh; git -C "$C" worktree add -q "$W/wt" 2>/dev/null || fail "worktree"
  (cd "$W/wt" && HUB="$W/wt" bin/adopt --clone --owner X --name n15 >/dev/null 2>&1); assert_eq "$?" 2 "a worktree is refused"
  [ -f "$W/wt/.git" ] || fail "the worktree's .git changed"; git -C "$C" worktree remove --force "$W/wt"
}
adopt_names_the_login_for_from() {
  fresh; git -C "$C" mv memory/users/kim-old memory/users/kimo && git -C "$C" commit -qm mv
  out=$(adopt --handover --owner "Bo New" 2>&1); echo "$out" | grep -q "login" || fail "no login hint: $out"
  echo "$out" | grep -q -- "--from <login>" || fail "no --from <login>: $out"
}

# story O1: every mode prints bin/review's summary of the hub after its work, before "Left to do by hand:"
adopt_shows_review() {
  local m out
  for m in share handover clone; do fresh
    case "$m" in share) out=$(adopt --share) ;; handover) out=$(adopt --handover --owner "Bo New") ;;
      clone) out=$(adopt --clone --owner "Bo New" --name n16) ;; esac || fail "adopt_shows_review: $m: $out"
    echo "$out" | awk '/^## Hub$/{h=NR} /^Left to do by hand:$/{l=NR} END{exit !(h && l && h < l)}' ||
      fail "adopt_shows_review: $m: no review before \"Left to do by hand:\": $out"
    echo "$out" | grep -qx "## Agents and skills" || fail "adopt_shows_review: $m: the review is cut short: $out"
    [ "$m" = share ] || { echo "$out" | grep -qx "Owner: Bo New" || fail "adopt_shows_review: $m: the review names the new owner: $out"; }
  done
}
adopt_handover_rewrites_the_owner
adopt_share_changes_nothing
adopt_clone_makes_a_new_hub
adopt_clone_refuses_a_name_in_use
adopt_refuses_and_changes_nothing
adopt_prints_the_keys_steps
adopt_clone_keeps_unpushed_work
adopt_refuses_a_rule_it_cannot_rewrite
adopt_refuses_table_breaking_values
adopt_clone_adds_a_missing_name
adopt_clone_frees_the_old_claim
adopt_rolls_back_a_failed_commit
adopt_names_the_login_for_from
adopt_shows_review
echo ok
