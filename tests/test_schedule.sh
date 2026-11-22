#!/bin/bash
. "$(dirname "$0")/helpers.sh"
make_hub; cd "$HUB"; export AGENT_STATE="$(mktemp -d)"
# dry install: one plist per job, labelled per hub, logs under the state dir; nothing is loaded
L="$(mktemp -d)"; out=$(AGENT_LAUNCHAGENTS="$L" SCHEDULE_DRY=1 bin/schedule install) || fail "schedule install"
P="$L/ai.agent-hub.hub.sync.plist"; [ -f "$P" ] || fail "sync plist written"
echo "$out" | grep -q "wrote $P" || fail "dry install names the sync plist"
plist_ok "$P" || fail "sync plist is not valid"
assert_contains "$P" "<string>ai.agent-hub.hub.sync</string>" "sync label"
assert_contains "$P" "<string>$HUB/bin/sync</string><string>--auto</string>" "sync job runs bin/sync --auto"
grep -q -- "--yes" "$P" && fail "sync job must never run --yes"
assert_contains "$P" "<integer>1800</integer>" "every 30 minutes"
assert_contains "$P" "$AGENT_STATE/logs/sync.log" "sync log in the state dir"
grep -q "{{" "$P" && fail "unfilled placeholder in the sync plist"
[ -d "$AGENT_STATE/logs" ] || fail "logs dir made"
M="$L/ai.agent-hub.hub.monitor.plist"; [ -f "$M" ] || fail "monitor plist written"
plist_ok "$M" || fail "monitor plist is not valid"
assert_contains "$M" "<string>ai.agent-hub.hub.monitor</string>" "monitor label"
assert_contains "$M" "<string>$HUB/bin/monitor</string>" "monitor job runs this hub's bin/monitor"
assert_contains "$M" "<integer>1800</integer>" "monitor every 30 minutes"
assert_contains "$M" "$AGENT_STATE/logs/monitor.log" "monitor log in the state dir"
assert_contains "$M" "$HOME/.local/bin" "monitor PATH has ~/.local/bin"
grep -q "{{" "$M" && fail "unfilled placeholder in the monitor plist"
# HUB_AUTO_SYNC=0 in hub.conf: no sync job (and an earlier one is removed); the other jobs stay
echo HUB_AUTO_SYNC=0 > hub.conf
out=$(AGENT_LAUNCHAGENTS="$L" SCHEDULE_DRY=1 bin/schedule install) || fail "schedule install, auto sync off"
[ -f "$P" ] && fail "auto sync off: sync plist kept"
echo "$out" | grep -q "removed ai.agent-hub.hub.sync" || fail "auto sync off: removal reported"
[ -f "$L/ai.agent-hub.hub.briefing.plist" ] || fail "auto sync off: briefing plist missing"
[ -f "$L/ai.agent-hub.hub.monitor.plist" ] || fail "auto sync off: monitor plist missing"
rm -f hub.conf
echo ok
