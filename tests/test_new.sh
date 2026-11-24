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
bin/new ops/backups >/dev/null && [ -f .claude/agents/ops-backups.md ] || fail "ops agent name"
bin/new projects/Bad_Name >/dev/null 2>&1; assert_eq "$?" "2" "bad name exits 2"
assert_contains projects/demo/CLAUDE.md "@memory/MEMORY.md" "new folder CLAUDE.md imports its memory"

# story P1: --repo fills the folder's Code table from the repo itself; the checkout is only read
P="$(mktemp -d)"; export AGENT_STATE="$P/state"
printf '%s\n' "HUB_NAME=p1-hub" "HUB_OWNER='Sam Lee'" "HUB_REPOS=acme/infra" > hub.conf
gitc() { git -C "$1" -c user.name=t -c user.email=t@t "${@:2}"; }
mkrepo() { git init -q -b "$2" "$1" && echo x > "$1/README" && gitc "$1" add -A && gitc "$1" commit -qm init; }
origin_head() { git -C "$1" update-ref "refs/remotes/origin/$2" HEAD && git -C "$1" symbolic-ref refs/remotes/origin/HEAD "refs/remotes/origin/$2"; }
code_row() { awk -F'|' -v r=" $2 " '/^## Code/{c=1; next} /^## /{c=0} c && $2 == r' "$1"; }
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
assert_eq "$(code_row projects/rel/ACCESS.md ci)" "| ci | $P/ci | main | Sam Lee | GitHub Actions |" "a relative checkout made absolute"
# AC7: each new owner/name joins HUB_REPOS once, with one line saying to commit hub.conf
assert_eq "$(. ./hub.conf; echo "$HUB_REPOS")" "acme/infra acme/api acme/web" "HUB_REPOS gains the new repos"
assert_eq "$(printf '%s\n' "$out" | grep -c 'hub.conf')" "1" "one line names hub.conf"
printf '%s\n' "$out" | grep 'hub.conf' | grep -qi commit || fail "the line says to commit hub.conf: $out"
assert_contains hub.conf "HUB_NAME=p1-hub" "hub.conf keeps its other lines"
out=$(bin/new projects/other --repo acme/api) || fail "the same repo in a second folder"
assert_eq "$(. ./hub.conf; echo "$HUB_REPOS")" "acme/infra acme/api acme/web" "no duplicate in HUB_REPOS"
printf '%s\n' "$out" | grep -q 'hub.conf' && fail "no hub.conf line when nothing was added"
# AC4: owner/name alone: an empty checkout (bin/work clones it); owner/name=~/x expands ~
assert_eq "$(code_row projects/other/ACCESS.md acme/api)" "| acme/api |  | main | Sam Lee | (fill in) |" "owner/name alone"
mkdir -p "$P/h/x"; HOME="$P/h" bin/new projects/home --repo 'acme/home=~/x' >/dev/null || fail "owner/name=~/x"
assert_eq "$(code_row projects/home/ACCESS.md acme/home)" "| acme/home | $P/h/x | main | Sam Lee | (fill in) |" "~ expanded"
# AC5: an existing folder gains the row and keeps every other file byte for byte
echo "my notes" > projects/shop/notes.md; echo "custom" > projects/shop/STATE.md
sums() { (cd projects/shop && find . -type f ! -name ACCESS.md -exec shasum {} \; | sort); }
S_BEFORE="$(sums)"; cp "$A" "$P/access.before"
# AC2: no remote: the directory name, its current branch, (fill in) CI
bin/new projects/shop --repo "$P/tool" >/dev/null || fail "--repo on an existing folder"
assert_eq "$(code_row "$A" tool)" "| tool | $P/tool | dev | Sam Lee | (fill in) |" "no remote"
assert_eq "$(sums)" "$S_BEFORE" "every other file kept byte for byte"
assert_eq "$(grep -vxF "| tool | $P/tool | dev | Sam Lee | (fill in) |" "$A")" "$(cat "$P/access.before")" "ACCESS.md only gains the row"
code_row "$A" tool >/dev/null; awk '/^## Code/{c=1; next} /^## /{c=0} c' "$A" | grep -q "| tool |" || fail "the row is inside the Code table"
# AC3: .github/workflows/*.yml or *.yaml: GitHub Actions
bin/new projects/shop --repo "$P/cy" >/dev/null || fail "--repo with a .yaml workflow"
assert_eq "$(code_row "$A" cy)" "| cy | $P/cy | main | Sam Lee | GitHub Actions |" "a .yaml workflow"
# AC5: refusals (exit 2, a message, nothing written): a repo already in the table, a checkout that is not a directory
cp "$A" "$P/access.before"
for r in "$P/api" acme/api "acme/api=$P/web"; do
  err=$(bin/new projects/shop --repo "$r" 2>&1 >/dev/null); assert_eq "$?" "2" "a repo already in the table ($r)"
  [ -n "$err" ] || fail "the refusal says why ($r)"; done
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
