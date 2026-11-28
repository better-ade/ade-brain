#!/bin/bash
# bin/review (story O1): a read-only summary of a hub you load. One function per acceptance criterion; AC6 is
# adopt_shows_review in tests/test_adopt.sh.
. "$(dirname "$0")/helpers.sh"
make_hub; T="$HUB"; W="$(mktemp -d)"; stub_security
export HOME="$W/home"; mkdir -p "$HOME"   # a state folder written under ~/.agent-hub would show here
# every key-store tool records a call: security (stub_security's $STORE.argv), secret-tool, and the hub's bin/secret
CALLS="$W/calls"; : > "$CALLS"; B="$W/bin"; mkdir -p "$B"
printf '#!/bin/bash\necho "secret-tool $*" >> "%s"\n' "$CALLS" > "$B/secret-tool"; chmod +x "$B/secret-tool"; export PATH="$B:$PATH"
CO="$W/infra"; mkdir -p "$CO"
mkhub() { (cd "$T" && env -u HUB bin/init --persona tech-lead --client "Acme" --owner "Kim Old" --name acme-lead --dest "$1" "${@:2}" >/dev/null) ||
  fail "init $1"; git -C "$1" config user.name t; git -C "$1" config user.email t@t
  printf '#!/bin/bash\necho "bin/secret $*" >> "%s"\n' "$CALLS" > "$1/bin/secret"; }
E="$W/empty/hub"; mkhub "$E"
D="$W/full/hub"; mkhub "$D" --repo acme/infra="$CO" --secret grafana-token
review() { (cd "$1" && HUB="$1" bin/review "${@:2}"); }
# the full hub: a folder in progress, one more folder, journal entries, memory and a person, a commit
(cd "$D" && HUB="$D" bin/new projects/demo >/dev/null && HUB="$D" bin/new projects/zeta >/dev/null) || fail "bin/new"
state() { awk -v l="$2" -v o="$3" -v w="$4" '{print} /^## Live$/{print "- " l} /^## Open$/{print "- " o} /^## Waiting on$/{print "- " w}' \
  "$D/$1/STATE.md" > "$D/$1/STATE.t" && mv "$D/$1/STATE.t" "$D/$1/STATE.md"; }
state projects/demo "api deploy to staging" "flaky login test" "client sign-off"
state projects/zeta "zulu live thing" "zulu open thing" "zulu waiting thing"
(cd "$D" && HUB="$D" bin/journal projects/demo "shipped the login fix" && HUB="$D" bin/journal projects/zeta "zulu folder note") || fail "journal"
printf -- '- [Deploy steps](deploy-steps.md) — staging first, then prod\n- [Release day](release-day.md) — Tuesdays\n' >> "$D/memory/MEMORY.md"
mkdir -p "$D/memory/users/sam"; echo "- a fact" > "$D/memory/users/sam/profile.md"
git -C "$D" add -A && git -C "$D" commit -qm work || fail "commit the full hub"

review_sections() {
  out=$(review "$D") || fail "review_sections: exit $?: $out"
  for h in "Hub" "In progress" "Recent" "Memory" "Reach" "Agents and skills"; do
    echo "$out" | grep -qx "## $h" || fail "review_sections: no '## $h' section: $out"; done
  for v in "Name: acme-lead" "Owner: Kim Old" "Persona: Tech Lead" "suggested model: sonnet" "projects/demo" \
           "Live: api deploy to staging" "Open: flaky login test" "Waiting on: client sign-off" "3 not started" \
           "shipped the login fix" "by t" "Entries: 2" "[Deploy steps](deploy-steps.md)" "People: sam" \
           "acme/infra" "Key names: grafana-token" "briefing" "monitor" "tech-lead" "bmad-build"; do
    echo "$out" | grep -qF -- "$v" || fail "review_sections: [$v] missing: $out"; done
  echo "$out" | grep -q "Hub initialized from" && fail "review_sections: bin/init's own journal line is not recent work: $out"
  true
}

snap() { (cd "$1" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum) ; (cd "$HOME" && find . | LC_ALL=C sort); }
review_read_only() {
  before="$(snap "$D")"; : > "$CALLS"; : > "$STORE.argv"
  review "$D" >/dev/null || fail "review_read_only: exit"; review "$D" projects/demo >/dev/null || fail "review_read_only: folder exit"
  assert_eq "$(snap "$D")" "$before" "review_read_only: the hub (tracked, untracked, .git) or HOME changed"
  assert_eq "$(cat "$CALLS")" "" "review_read_only: a key-store tool ran"
  assert_eq "$(cat "$STORE.argv")" "" "review_read_only: security ran"
}

review_empty_hub() {
  out=$(review "$E"); assert_eq "$?" 0 "review_empty_hub: exit"
  assert_eq "$(echo "$out" | grep '^## ')" "$(printf '## Hub\n## Agents and skills')" "review_empty_hub: the sections"
}

review_folder() {
  out=$(review "$D" projects/demo) || fail "review_folder: exit"
  echo "$out" | grep -qF "api deploy to staging" || fail "review_folder: the folder's state: $out"
  echo "$out" | grep -qF "shipped the login fix" || fail "review_folder: the folder's journal: $out"
  echo "$out" | grep -qF "zulu" && fail "review_folder: another folder shows: $out"
  out=$(review "$D" projects/nope 2>&1); assert_eq "$?" 2 "review_folder: an unknown folder"
  echo "$out" | grep -qF "projects/nope" || fail "review_folder: the refusal names the folder: $out"
}

review_cut() {
  x="$(printf 'x%.0s' $(seq 500))"; state projects/demo "$x" "o" "w"
  (cd "$D" && HUB="$D" bin/journal projects/demo "$x") || fail "review_cut: journal"; echo "- [Long]($x.md)" >> "$D/memory/MEMORY.md"
  out=$(review "$D") || fail "review_cut: exit"
  echo "$out" | grep -q xxxxxxxxxx || fail "review_cut: the long lines are not printed at all: $out"
  echo "$out" | grep xxxxxxxxxx | awk 'length($0) > 200 {print; bad=1} END{exit bad}' >/dev/null || fail "review_cut: a line over 200 characters"
}

review_sections
review_read_only
review_empty_hub
review_folder
review_cut
echo ok
