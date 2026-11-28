#!/bin/bash
. "$(dirname "$0")/helpers.sh"
make_hub; cd "$HUB"
bin/new projects/demo >/dev/null || fail "bin/new failed"
for f in projects/demo/CLAUDE.md projects/demo/ACCESS.md projects/demo/STATE.md projects/demo/memory/MEMORY.md \
         projects/demo/.claude/settings.json .claude/agents/demo.md; do [ -f "$f" ] || fail "missing $f"; done
assert_contains .claude/agents/demo.md "projects/demo/STATE.md" "the agent reads its STATE.md"
assert_contains projects/demo/STATE.md "## Live" "STATE sections"
echo "custom" > projects/demo/STATE.md
bin/new projects/demo | grep -q "kept projects/demo/STATE.md" || fail "did not report kept"
assert_eq "$(cat projects/demo/STATE.md)" "custom" "never overwrites"
# no AI attribution (.ade/rules.md "Commit as the user"): the hub root, a new folder, and a folder re-rendered by --settings
attr_off() { python3 -c 'import json,sys; a=json.load(open(sys.argv[1])).get("attribution",{}); sys.exit(0 if a.get("commit")=="" and a.get("pr")=="" else 1)' "$1"; }
attr_off .claude/settings.json || fail "the hub root settings do not turn attribution off"
attr_off projects/demo/.claude/settings.json || fail "a new folder's settings do not turn attribution off"
bin/new --settings projects/demo >/dev/null || fail "bin/new --settings failed"
attr_off projects/demo/.claude/settings.json || fail "bin/new --settings drops attribution off"
bin/new ops/backups >/dev/null && [ -f .claude/agents/ops-backups.md ] || fail "ops agent name"
bin/new projects/Bad_Name >/dev/null 2>&1; assert_eq "$?" "2" "bad name exits 2"
assert_contains projects/demo/CLAUDE.md "@memory/MEMORY.md" "new folder CLAUDE.md imports its memory"

# story P1: --repo fills the folder's Code table from the repo itself; the checkout is only read
P="$(mktemp -d)"; export AGENT_STATE="$P/state"
printf '%s\n' "HUB_NAME=p1-hub" "HUB_OWNER='Sam Lee'" "HUB_REPOS=acme/infra" > hub.conf
gitc() { git -C "$1" -c user.name=t -c user.email=t@t "${@:2}"; }
mkrepo() { git init -q -b "$2" "$1" && echo x > "$1/README" && gitc "$1" add -A && gitc "$1" commit -qm init; }
origin_head() { git -C "$1" update-ref "refs/remotes/origin/$2" HEAD && git -C "$1" symbolic-ref refs/remotes/origin/HEAD "refs/remotes/origin/$2"; }
# code_row <ACCESS.md> <repo> [<checkout>]: the Code table row(s) for that repo cell (and checkout cell, when given)
code_row() { awk -F'|' -v r=" $2 " -v k=" ${3:-} " -v n="$#" '/^## Code/{c=1; next} /^## /{c=0} c && $2 == r && (n < 3 || $3 == k)' "$1"; }
snap() { git -C "$1" status --porcelain; (cd "$1" && find . | sort); }
mkrepo "$P/api" feature; git -C "$P/api" remote add origin git@github.com:acme/api.git; origin_head "$P/api" master
mkrepo "$P/web" feature; git -C "$P/web" remote add origin https://github.com/acme/web.git; origin_head "$P/web" trunk
mkrepo "$P/tool" dev
mkrepo "$P/ci" main; mkdir -p "$P/ci/.github/workflows"; echo "on: push" > "$P/ci/.github/workflows/ci.yml"
mkrepo "$P/cy" main; mkdir -p "$P/cy/.github/workflows"; echo "on: push" > "$P/cy/.github/workflows/build.yaml"
API_BEFORE="$(snap "$P/api")"; WEB_BEFORE="$(snap "$P/web")"
# AC1: a GitHub origin (ssh and https): owner/name, the absolute checkout, origin/HEAD's branch (not the current one)
out=$(bin/new projects/shop --repo "$P/api" --repo "$P/web") || fail "bin/new --repo with local checkouts"
A=projects/shop/ACCESS.md
assert_eq "$(code_row "$A" acme/api)" "| acme/api | $P/api | master | Sam Lee | (fill in) |" "ssh origin, master default"
assert_eq "$(code_row "$A" acme/web)" "| acme/web | $P/web | trunk | Sam Lee | (fill in) |" "https origin"
(cd "$P" && "$HUB/bin/new" projects/rel --repo ./ci >/dev/null) || fail "a relative checkout"
assert_eq "$(code_row projects/rel/ACCESS.md "(no remote)")" "| (no remote) | $P/ci | main | Sam Lee | GitHub Actions |" "a relative checkout made absolute"
# AC7: each new owner/name joins HUB_REPOS once, with one line saying to commit hub.conf
assert_eq "$(. ./hub.conf; echo "$HUB_REPOS")" "acme/infra acme/api acme/web" "HUB_REPOS gains the new repos"
assert_eq "$(printf '%s\n' "$out" | grep -c 'hub.conf')" "1" "one line names hub.conf"
printf '%s\n' "$out" | grep 'hub.conf' | grep -qi commit || fail "the line says to commit hub.conf: $out"
assert_contains hub.conf "HUB_NAME=p1-hub" "hub.conf keeps its other lines"
out=$(bin/new projects/other --repo acme/api) || fail "the same repo in a second folder"
assert_eq "$(. ./hub.conf; echo "$HUB_REPOS")" "acme/infra acme/api acme/web" "no duplicate in HUB_REPOS"
printf '%s\n' "$out" | grep -q 'hub.conf' && fail "no hub.conf line when nothing was added"
# AC4: owner/name alone: an empty checkout (bin/work clones it); owner/name=~/x is stored as ~/x (story I1: no machine path)
assert_eq "$(code_row projects/other/ACCESS.md acme/api)" "| acme/api |  | main | Sam Lee | (fill in) |" "owner/name alone"
mkdir -p "$P/h/x"; HOME="$P/h" bin/new projects/home --repo 'acme/home=~/x' >/dev/null || fail "owner/name=~/x"
assert_eq "$(code_row projects/home/ACCESS.md acme/home)" "| acme/home | ~/x | main | Sam Lee | (fill in) |" "stored under ~"
# AC5: an existing folder gains the row and keeps every other file byte for byte
echo "my notes" > projects/shop/notes.md; echo "custom" > projects/shop/STATE.md
sums() { (cd projects/shop && find . -type f ! -name ACCESS.md -exec shasum {} \; | sort); }
S_BEFORE="$(sums)"; cp "$A" "$P/access.before"
# AC2: no remote: (no remote) and the absolute checkout (as ade project add writes it), its current branch, (fill in) CI
bin/new projects/shop --repo "$P/tool" >/dev/null || fail "--repo on an existing folder"
assert_eq "$(code_row "$A" "(no remote)")" "| (no remote) | $P/tool | dev | Sam Lee | (fill in) |" "no remote"
assert_eq "$(sums)" "$S_BEFORE" "every other file kept byte for byte"
assert_eq "$(grep -vxF "| (no remote) | $P/tool | dev | Sam Lee | (fill in) |" "$A")" "$(cat "$P/access.before")" "ACCESS.md only gains the row"
awk '/^## Code/{c=1; next} /^## /{c=0} c' "$A" | grep -qF "| (no remote) | $P/tool |" || fail "the row is inside the Code table"
assert_eq "$(. ./hub.conf; echo "$HUB_REPOS")" "acme/infra acme/api acme/web acme/home" "(no remote) never joins HUB_REPOS"
# AC3: .github/workflows/*.yml or *.yaml: GitHub Actions. cy has no remote either: a second (no remote) row in the
# same folder is not a duplicate, since (no remote) rows are told apart by their checkout
bin/new projects/shop --repo "$P/cy" >/dev/null || fail "a second no-remote checkout refused as a duplicate"
assert_eq "$(code_row "$A" "(no remote)" "$P/cy")" "| (no remote) | $P/cy | main | Sam Lee | GitHub Actions |" "a .yaml workflow"
assert_eq "$(code_row "$A" "(no remote)" | wc -l | tr -d ' ')" "2" "two (no remote) rows, one per checkout"
assert_eq "$(. ./hub.conf; echo "$HUB_REPOS")" "acme/infra acme/api acme/web acme/home" "HUB_REPOS still without (no remote)"
mkrepo "$P/n1" main; mkrepo "$P/n2" main
bin/new projects/pair --repo "$P/n1" --repo "$P/n2" >/dev/null || fail "two no-remote checkouts in one call"
assert_eq "$(code_row projects/pair/ACCESS.md "(no remote)" | wc -l | tr -d ' ')" "2" "both no-remote rows written in one call"
# AC5: refusals (exit 2, a message, nothing written): a repo already in the table, a checkout that is not a directory
cp "$A" "$P/access.before"
for r in "$P/api" acme/api "acme/api=$P/web" "$P/tool" "$P/cy"; do
  err=$(bin/new projects/shop --repo "$r" 2>&1 >/dev/null); assert_eq "$?" "2" "a repo already in the table ($r)"
  [ -n "$err" ] || fail "the refusal says why ($r)"; done
# a (no remote) row as ade project add writes it: the checkout under ~, appended after the table; the same checkout again is refused
mkrepo "$P/h/lc" main; printf '| (no remote) | ~/lc | main | (owner) | none found |\n' >> "$A"; cp "$A" "$P/access.before"
err=$(HOME="$P/h" bin/new projects/shop --repo "$P/h/lc" 2>&1 >/dev/null); assert_eq "$?" "2" "a (no remote) checkout already in the file under ~"
[ -n "$err" ] || fail "the refusal says why ($P/h/lc)"
for r in "$P/nope" "acme/nope=$P/nope" "$P/ci/README"; do
  err=$(bin/new projects/shop --repo "$r" 2>&1 >/dev/null); assert_eq "$?" "2" "a checkout that is not a directory ($r)"
  [ -n "$err" ] || fail "the refusal says why ($r)"; done
assert_eq "$(cat "$A")" "$(cat "$P/access.before")" "a refusal writes nothing"
bin/new projects/fresh --repo "$P/nope" >/dev/null 2>&1; assert_eq "$?" "2" "refused before the folder is made"
[ -e projects/fresh ] && fail "a refused --repo made the folder"
bin/new projects/twice --repo "$P/tool" --repo "$P/tool" >/dev/null 2>&1; assert_eq "$?" "2" "the same repo twice in one call"
bin/new projects/x --repo >/dev/null 2>&1; assert_eq "$?" "2" "--repo needs a value"
# AC6: the checkouts are only read
assert_eq "$(snap "$P/api")" "$API_BEFORE" "the api checkout unchanged"
assert_eq "$(snap "$P/web")" "$WEB_BEFORE" "the web checkout unchanged"
rm -f hub.conf
echo ok
