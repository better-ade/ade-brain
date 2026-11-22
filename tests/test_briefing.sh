#!/bin/bash
. "$(dirname "$0")/helpers.sh"
make_hub; cd "$HUB"; export MONITOR_QUIET=1 AGENT_STATE="$(mktemp -d)"
S="$(mktemp -d)"; J="journal/$(date -u +%Y-%m-%d).md"
printf '#!/bin/bash\necho "$@" > "%s/args"; echo "1) staging healthy"; echo "5) top task: projects/app"\n' "$S" > "$S/fakeclaude"; chmod +x "$S/fakeclaude"
AGENT_CLAUDE="$S/fakeclaude" bin/briefing || fail "briefing failed"
assert_contains "$J" "briefing:" "journal entry"; assert_contains "$J" "top task: projects/app" "briefing text"
assert_contains "$S/args" "--model haiku" "cheap model"; assert_contains "$S/args" "hub's technical agent" "persona"
grep -qE "allowedTools [^ ]*(Edit|Write)" "$S/args" && fail "briefing may write"
# negative: the model fails, the failure is journalled and the exit is 1
printf '#!/bin/bash\necho "rate limited"; exit 3\n' > "$S/badclaude"; chmod +x "$S/badclaude"
AGENT_CLAUDE="$S/badclaude" bin/briefing; assert_eq "$?" "1" "failure exits 1"
assert_contains "$J" "briefing failed: exit 3, rate limited" "failure journalled"
printf '#!/bin/bash\necho "   "\n' > "$S/emptyclaude"; chmod +x "$S/emptyclaude"
AGENT_CLAUDE="$S/emptyclaude" bin/briefing; assert_eq "$?" "1" "empty output is a failure"
# schedule writes a weekday plist pointing at this hub (dry: nothing loaded)
L="$(mktemp -d)"; AGENT_LAUNCHAGENTS="$L" SCHEDULE_DRY=1 bin/schedule install >/dev/null || fail "schedule install"
assert_contains "$L/ai.agent-hub.hub.briefing.plist" "$HUB/bin/briefing" "plist runs this hub's briefing"
plist_ok "$L/ai.agent-hub.hub.briefing.plist" || fail "plist is not valid"
bin/schedule bogus >/dev/null 2>&1; assert_eq "$?" "2" "bad subcommand exits 2"
echo ok
