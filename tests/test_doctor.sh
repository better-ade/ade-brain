#!/bin/bash
. "$(dirname "$0")/helpers.sh"
make_hub; cd "$HUB"
out=$(PATH=/usr/bin:/bin AGENT_REMOTE_KEY=/nonexistent DOCTOR_OFFLINE=1 bin/doctor); rc=$?
assert_eq "$rc" "0" "doctor always exits 0"
echo "$out" | grep -qE "^MISSING +gitleaks" || fail "missing gitleaks reported"
echo "$out" | grep -qE "^MISSING +remote ssh key +/nonexistent" || fail "missing ssh key reported"
out=$(PATH=/usr/bin:/bin DOCTOR_OFFLINE=1 bin/doctor); echo "$out" | grep -q "remote ssh key" && fail "no key configured, nothing to report"
echo "$out" | grep -qE "^MISSING +brain index +none yet" || fail "no index reported"
bin/brain index >/dev/null 2>&1; out=$(DOCTOR_OFFLINE=1 bin/doctor); echo "$out" | grep -qE "^OK +brain index" || fail "fresh index OK"
echo "- new" >> memory/MEMORY.md; out=$(DOCTOR_OFFLINE=1 bin/doctor); echo "$out" | grep -qE "^MISSING +brain index +1 file" || fail "stale index reported"
# a folder made before a hook was added to the template: doctor warns; bin/new --settings re-renders only that file
bin/new projects/old >/dev/null 2>&1; S=projects/old/.claude/settings.json
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); del d["hooks"]["PostToolUse"]; json.dump(d, open(sys.argv[1],"w"))' "$S"
echo "keep me" > projects/old/STATE.md
out=$(DOCTOR_OFFLINE=1 bin/doctor); echo "$out" | grep -qE "^WARN +settings projects/old +.*PostToolUse.*bin/new --settings projects/old" || fail "no warning for old settings: [$out]"
echo "$out" | grep -qE "settings projects/[^o]" && fail "a current folder warned"
bin/new --settings projects/old >/dev/null || fail "bin/new --settings failed"
[ -f "$S.bak" ] && ! grep -q PostToolUse "$S.bak" || fail "no .bak copy of the old settings"
grep -q '"PostToolUse"' "$S" && grep -q "bin/inbox projects/old" "$S" || fail "settings not re-rendered: $(cat "$S")"
assert_eq "$(cat projects/old/STATE.md)" "keep me" "--settings touches only the settings files"
DOCTOR_OFFLINE=1 bin/doctor | grep -q "settings projects/old" && fail "still warned after the re-render"
# story I1: a settings.json that names a hub path (a folder from before I1) is flagged for bin/setup, which fixes it
sed -i.x "s#\"\\\\\"\$CLAUDE_PROJECT_DIR\\\\\"/../../bin/inbox#\"\\\\\"$HUB\\\\\"/bin/inbox#" "$S"; rm -f "$S.x"
grep -qF "\\\"$HUB\\\"/bin/inbox" "$S" || fail "test setup: no hub path in $S"
out=$(DOCTOR_OFFLINE=1 bin/doctor); echo "$out" | grep -qE "^WARN +settings projects/old +.*names a hub path.*bin/setup" || fail "no warning for a hub path: [$out]"
bin/setup >/dev/null 2>&1; DOCTOR_OFFLINE=1 bin/doctor | grep -q "settings projects/old" && fail "still flagged after bin/setup"
# no local settings at all (a fresh clone before bin/setup): MISSING, and bin/setup writes them
L=projects/old/.claude/settings.local.json
rm "$L"; out=$(DOCTOR_OFFLINE=1 bin/doctor); echo "$out" | grep -qE "^MISSING +settings projects/old .*bin/setup" || fail "no MISSING for absent local settings: [$out]"
bin/setup >/dev/null 2>&1; DOCTOR_OFFLINE=1 bin/doctor | grep -q "settings projects/old" && fail "still flagged after bin/setup"
bin/new --settings projects/none >/dev/null 2>&1; assert_eq "$?" "2" "--settings on a missing folder exits 2"
echo ok
