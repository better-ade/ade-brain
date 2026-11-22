#!/bin/bash
# story C1: the hub takes the method (rules.md, bmad/custom/*.toml) from ade-method. Never the network: a local fixture
# repo stands in for ade-method through AGENT_METHOD_REPO.
. "$(dirname "$0")/helpers.sh"
PIN="$(bash -c ". '$REPO/bin/lib.sh' && method_pin")"
[ -n "$PIN" ] || fail "bin/lib.sh has no method_pin"
# a fixture ade-method with tags v1 and v2 (and the pin), each holding different rules and overrides
F="$(mktemp -d)/ade-method"; method_repo "$F" v1 v2 "$PIN"
fresh() { make_hub; cd "$HUB"; export AGENT_METHOD_REPO="$F"; }

sync_copies_method() {
  fresh; bin/method sync v1 >/dev/null || fail "sync v1 failed"
  assert_eq "$(cat .ade/rules.md)" "rules v1" "rules.md copied"
  assert_eq "$(cat _bmad/custom/bmad-build.toml)" "# build v1" "bmad-build.toml copied"
  assert_eq "$(cat _bmad/custom/bmad-code-review.toml)" "# review v1" "bmad-code-review.toml copied"
  [ -f _bmad/custom/.gitignore ] || fail "sync removed _bmad/custom/.gitignore"
}
version_recorded() {
  fresh; bin/method sync v2 >/dev/null || fail "sync v2 failed"
  assert_eq "$(awk '$1=="ref"{print $2}' .ade/method-version)" "v2" "ref recorded"
  assert_eq "$(awk '$1=="commit"{print $2}' .ade/method-version)" "$(git -C "$F" rev-parse 'v2^{commit}')" "commit recorded"
}
ref_from_conf_or_arg() {
  fresh; bin/method sync >/dev/null || fail "sync with no ref and no hub.conf failed"
  assert_eq "$(cat .ade/rules.md)" "rules $PIN" "no ref: the template's pin"
  echo "HUB_METHOD_REF=v1" > hub.conf; bin/method sync >/dev/null || fail "sync from hub.conf failed"
  assert_eq "$(cat .ade/rules.md)" "rules v1" "HUB_METHOD_REF picks the ref"
  bin/method sync v2 >/dev/null || fail "sync v2 failed"
  assert_eq "$(cat .ade/rules.md)" "rules v2" "an argument overrides HUB_METHOD_REF"
}
bad_ref_changes_nothing() {
  fresh; bin/method sync v1 >/dev/null || fail "sync v1 failed"
  before="$(cat .ade/rules.md _bmad/custom/*.toml .ade/method-version)"
  bin/method sync no-such-ref >/dev/null 2>&1; assert_eq "$?" "1" "unknown ref exits 1"
  assert_eq "$(cat .ade/rules.md _bmad/custom/*.toml .ade/method-version)" "$before" "unknown ref changed nothing"
  AGENT_METHOD_REPO=/nonexistent/ade-method bin/method sync v1 >/dev/null 2>&1; assert_eq "$?" "1" "unreachable repo exits 1"
  assert_eq "$(cat .ade/rules.md _bmad/custom/*.toml .ade/method-version)" "$before" "unreachable repo changed nothing"
}
check_finds_drift() {
  fresh; bin/method sync v1 >/dev/null || fail "sync v1 failed"
  bin/method check >/dev/null || fail "check after sync exits 0"
  echo "my own rule" >> .ade/rules.md; echo x > _bmad/custom/bmad-code-review.toml
  out=$(bin/method check 2>&1); assert_eq "$?" "1" "drift exits 1"
  echo "$out" | grep -q "\.ade/rules\.md" || fail "check names rules.md: $out"
  echo "$out" | grep -q "_bmad/custom/bmad-code-review\.toml" || fail "check names the review override: $out"
  echo "$out" | grep -q "bmad-build\.toml" && fail "check names a file that matches: $out"
  rm _bmad/custom/bmad-build.toml; bin/method check 2>&1 | grep -q "bmad-build\.toml" || fail "a missing file is drift"
}
doctor_reports_drift() {
  fresh; bin/method sync v1 >/dev/null || fail "sync v1 failed"
  out=$(PATH=/usr/bin:/bin DOCTOR_OFFLINE=1 bin/doctor); echo "$out" | grep -qE "^OK +method +.*v1" || fail "in step: OK row: $out"
  echo drift >> .ade/rules.md; echo drift >> _bmad/custom/bmad-build.toml
  out=$(PATH=/usr/bin:/bin DOCTOR_OFFLINE=1 bin/doctor)
  assert_eq "$(echo "$out" | grep -cE "^[A-Z]+ +method ")" "1" "one method row"
  echo "$out" | grep -E "^MISSING +method " | grep -q "\.ade/rules\.md" || fail "doctor names the drifted file: $out"
  echo "$out" | grep -q "drift$" && fail "doctor prints file contents, not just names: $out"
  return 0
}
init_syncs_method() {
  fresh; D="$(mktemp -d)/h"; bin/init --persona tech-lead --client A --owner B --dest "$D" >/dev/null || fail "init failed"
  assert_eq "$(cat "$D/.ade/rules.md")" "rules $PIN" "init syncs the pinned rules"
  assert_eq "$(awk '$1=="ref"{print $2}' "$D/.ade/method-version")" "$PIN" "init records the pin"
  assert_eq "$(. "$D/hub.conf"; echo "$HUB_METHOD_REF")" "$PIN" "init writes HUB_METHOD_REF"
  (HUB="$D" "$D/bin/method" check >/dev/null) || fail "a new hub starts in step"
}
stale_overrides_removed() {
  # a newer ref (v3) no longer ships bmad-code-review.toml: sync removes it, but never an override the method did not install
  G="$(mktemp -d)/ade-method"; method_repo "$G" v1; git -C "$G" rm -q bmad/custom/bmad-code-review.toml
  echo "rules v3" > "$G/rules.md"; git -C "$G" commit -qam v3 && git -C "$G" tag v3
  fresh; export AGENT_METHOD_REPO="$G"; bin/method sync v1 >/dev/null || fail "sync v1 failed"
  echo "# mine" > _bmad/custom/mine.toml
  bin/method sync v3 >/dev/null || fail "sync v3 failed"
  [ -e _bmad/custom/bmad-code-review.toml ] && fail "an override v3 no longer ships was left in _bmad/custom"
  assert_eq "$(cat _bmad/custom/mine.toml)" "# mine" "an override the method did not install is kept"
  [ -f _bmad/custom/bmad-build.toml ] || fail "a shipped override was removed"
  bin/method check >/dev/null || fail "check after sync v3 exits 0"
}
init_records_failed_sync() {
  # the pin is missing from the repo, or its commit has no rules.md: init goes on, but check and doctor say so
  N="$(mktemp -d)/ade-method"; method_repo "$N" v1
  R="$(mktemp -d)/ade-method"; method_repo "$R" "$PIN"; git -C "$R" rm -q rules.md; git -C "$R" commit -qm norules
  git -C "$R" tag -f "$PIN" >/dev/null
  for repo in "$N" "$R"; do
    fresh; D="$(mktemp -d)/h"; AGENT_METHOD_REPO="$repo" bin/init --persona tech-lead --client A --owner B --dest "$D" >/dev/null 2>&1 ||
      fail "init failed when the method could not sync"
    out=$(HUB="$D" "$D/bin/method" check 2>&1); assert_eq "$?" "1" "check after a failed init sync exits 1 ($repo)"
    echo "$out" | grep -q "not synced at $PIN" || fail "check says not synced at the pin: $out"
    out=$(cd "$D" && HUB="$D" PATH=/usr/bin:/bin DOCTOR_OFFLINE=1 bin/doctor)
    echo "$out" | grep -E "^MISSING +method " | grep -q "not synced at $PIN" || fail "doctor says not synced at the pin: $out"
  done
}
template_matches_pin() {
  assert_eq "$(awk '$1=="ref"{print $2}' "$REPO/.ade/method-version")" "$PIN" "the template's method is the pinned ref"
  (unset HUB; cd "$REPO" && bin/method check) || fail "the template's .ade/rules.md or _bmad/custom/ differ from $PIN"
  grep -qi "lean mode" "$REPO/.ade/rules.md" && fail "the template's rules carry a lean-mode section of their own"
  return 0
}
# ade-method's ade.json install_templates (v2.1.0): each template file goes to its target, and check covers it
templates_installed() {
  local T; T="$(mktemp -d)/ade-method-t"; method_repo "$T" t1; mkdir -p "$T/templates"
  echo "PR template t2" > "$T/templates/pull_request_template.md"; echo "commit template t2" > "$T/templates/commit-template.txt"
  printf '{"format": 2, "install_templates": {"templates/pull_request_template.md": ".github/pull_request_template.md", "templates/commit-template.txt": ".ade/commit-template.txt"}}\n' > "$T/ade.json"
  echo "rules t2" > "$T/rules.md"; git -C "$T" add -A && git -C "$T" commit -qm t2 && git -C "$T" tag t2
  fresh; rm -f .github/pull_request_template.md .ade/commit-template.txt
  AGENT_METHOD_REPO="$T" bin/method sync t2 >/dev/null || fail "sync t2 failed"
  assert_eq "$(cat .github/pull_request_template.md)" "PR template t2" "the PR template is installed"
  assert_eq "$(cat .ade/commit-template.txt)" "commit template t2" "the commit template is installed"
  grep -q " .github/pull_request_template.md$" .ade/method-version || fail "the PR template's hash is recorded"
  grep -q " .ade/commit-template.txt$" .ade/method-version || fail "the commit template's hash is recorded"
  bin/method check >/dev/null || fail "check passes right after the sync"
  echo edited >> .github/pull_request_template.md
  out="$(bin/method check)"; assert_eq "$?" "1" "an edited template fails check"
  echo "$out" | grep -qx "differs: .github/pull_request_template.md" || fail "check names it [$out]"
  # a target outside the hub, or a source outside the method, is refused before anything changes
  printf '{"install_templates": {"templates/commit-template.txt": "../escape.txt"}}\n' > "$T/ade.json"
  git -C "$T" commit -qam bad && git -C "$T" tag t3; before="$(cat .ade/method-version)"
  AGENT_METHOD_REPO="$T" bin/method sync t3 >/dev/null 2>&1; assert_eq "$?" "1" "a target outside the hub exits 1"
  assert_eq "$(cat .ade/method-version)" "$before" "and changes nothing"; [ -e ../escape.txt ] && fail "wrote outside the hub"; true
}
for t in sync_copies_method version_recorded ref_from_conf_or_arg bad_ref_changes_nothing check_finds_drift \
         doctor_reports_drift init_syncs_method stale_overrides_removed \
         init_records_failed_sync templates_installed template_matches_pin; do (set -u; $t) || fail "$t"; done
echo ok
