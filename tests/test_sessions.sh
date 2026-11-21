#!/bin/bash
# bin/sessions: the durable list of focus sessions bin/work started, with the session that started each
. "$(dirname "$0")/helpers.sh"
make_hub; cd "$HUB"
unset ADE_HOOK_BIN ADE_HOOK_PORT ADE_HOOK_TOKEN ADE_PTY_ID   # never the real ADE
ST="$(mktemp -d)"; export AGENT_STATE="$ST"
bin/new projects/demo >/dev/null
S="$(mktemp -d)"; printf '#!/bin/bash\nexec sleep 30\n' > "$S/claude-stub"; chmod +x "$S/claude-stub"
launch() { WORK_NO_OPEN=1 bin/work --force --claude claude-stub projects/demo 2>/dev/null | sed -n 's/^launcher: //p'; }
wait_for() { for _ in $(seq 1 50); do eval "$1" && return 0; sleep 0.1; done; return 1; }
# a session started from a Claude session (CLAUDE_PID=777) registers itself with that parent
f=$(CLAUDE_PID=777 launch); [ -x "$f" ] || fail "launcher written"
PATH="$S:$PATH" bash "$f" & lp=$!
wait_for '[ -f "$ST/sessions/demo.$lp" ]' || fail "running session is registered"
out=$(bin/sessions); echo "$out" | grep -q "^demo  *projects/demo  *[0-9][0-9]*  *777 " || fail "listed with claude pid and parent: $out"
cp=$(pgrep -P "$lp" | head -1); echo "$out" | grep -q " $cp  *777 " || fail "claude pid is the launcher's child ($cp): $out"
bin/sessions --parent 777 | grep -q "^demo " || fail "--parent 777 lists it"
bin/sessions --parent 1 | grep -q "^demo " && fail "--parent 1 does not"
CLAUDE_PID=777 bin/sessions --mine | grep -q "^demo " || fail "--mine lists the caller's children"
CLAUDE_PID=778 bin/sessions --mine | grep -q "^demo " && fail "--mine skips other sessions' children"
# the session ending removes its entry
kill "$cp"; wait "$lp" 2>/dev/null
wait_for '[ ! -e "$ST/sessions/demo.$lp" ]' || fail "entry removed when the session ends"
[ ! -e "$f" ] || fail "launcher removed itself"
# started outside a Claude session: parent is -
f=$(env -u CLAUDE_PID bash -c "$(declare -f launch); launch"); PATH="$S:$PATH" bash "$f" & lp=$!
wait_for '[ -f "$ST/sessions/demo.$lp" ]' || fail "registered without a parent"
bin/sessions | grep -q "^demo  *projects/demo  *[0-9][0-9]*  *-  *20" || fail "no parent shows as -: $(bin/sessions)"
kill "$(pgrep -P "$lp" | head -1)"; wait "$lp" 2>/dev/null
# --name N registers the session as N (bin/dispatch matches a running ticket by NAME and FOLDER)
f=$(WORK_NO_OPEN=1 bin/work --force --name t-1.1 --role builder --claude claude-stub projects/demo 2>/dev/null | sed -n 's/^launcher: //p')
PATH="$S:$PATH" bash "$f" & lp=$!
wait_for '[ -f "$ST/sessions/t-1.1.$lp" ]' || fail "a --name session is registered under its name"
bin/sessions | grep -q "^t-1.1  *projects/demo  *[0-9][0-9]*  *[^ ][^ ]*  *20.* builder " || fail "listed by its --name with its role: $(bin/sessions)"
kill "$(pgrep -P "$lp" | head -1)"; wait "$lp" 2>/dev/null
# live status: the folder hooks mark the session's own entry busy (prompt) and idle (stop); bin/sessions shows it
printf '#!/bin/bash\nenv | grep "^CLAUDE" > "$AGENT_STATE/env.txt"\n"$HUB/bin/changes" projects/demo </dev/null >/dev/null 2>&1; touch "$AGENT_STATE/s1"\nfor _ in $(seq 1 100); do [ -e "$AGENT_STATE/go" ] && break; sleep 0.1; done\n"$HUB/bin/stop-check" projects/demo </dev/null >/dev/null 2>&1; touch "$AGENT_STATE/s2"\nexec sleep 20\n' > "$S/claude-hooks"; chmod +x "$S/claude-hooks"
f=$(CLAUDE_PID=777 CLAUDE_CONFIG_DIR=/keep/me WORK_NO_OPEN=1 bin/work --force --claude claude-hooks projects/demo 2>/dev/null | sed -n 's/^launcher: //p'); [ -x "$f" ] || fail "launcher written (hooks stub)"
# the tab's terminal carries a dead session's variables (ADE): the launcher drops them; the account is the one bin/work
# ran as (/keep/me), never the new terminal's (.ade/context/model-defaults.md)
PATH="$S:$PATH" CLAUDE_PID=5 CLAUDE_CODE_CHILD_SESSION=1 CLAUDE_CODE_MESSAGING_SOCKET=/tmp/dead.sock CLAUDE_CODE_MESSAGING_TOKEN=tok CLAUDE_CODE_SESSION_ID=old CLAUDE_CODE_BRIDGE_SESSION_ID=old CLAUDE_CODE_SESSION_ATTENDED=1 CLAUDE_CODE_ENTRYPOINT=cli CLAUDECODE=1 CLAUDE_CONFIG_DIR=/login/shell bash "$f" & lp=$!
wait_for '[ -e "$ST/s1" ]' || fail "prompt hook ran"
out=$(bin/sessions); echo "$out" | head -1 | grep -q "STATUS  *LAST" || fail "header has STATUS and LAST: $out"
echo "$out" | grep -q "^demo .* busy  *20[0-9-]*T[0-9:]*Z  *claude$" || fail "busy after a prompt (ENGINE last, story E1): $out"
grep -qE '^CLAUDE_(PID|CODE_CHILD_SESSION|CODE_MESSAGING_SOCKET|CODE_MESSAGING_TOKEN|CODE_SESSION_ID|CODE_BRIDGE_SESSION_ID|CODE_SESSION_ATTENDED|CODE_ENTRYPOINT)=|^CLAUDECODE=' "$ST/env.txt" && fail "inherited session variables dropped: $(cut -d= -f1 "$ST/env.txt" | tr '\n' ' ')"
grep -q '^CLAUDE_CONFIG_DIR=/keep/me$' "$ST/env.txt" || fail "the caller's CLAUDE_CONFIG_DIR kept, not the terminal's: $(grep CONFIG "$ST/env.txt")"
bin/sessions --parent 777 | grep -q "^demo " || fail "parent still the caller after a status write"
touch "$ST/go"; wait_for '[ -e "$ST/s2" ]' || fail "stop hook ran"
bin/sessions | grep -q "^demo .* idle  *20[0-9-]*T[0-9:]*Z  *claude$" || fail "idle after stop: $(bin/sessions)"
[ -z "$(ls -A "$ST/sessions" | grep -v "^demo\.$lp$")" ] || fail "no stray files in the registry: $(ls -A "$ST/sessions")"
# negative: a hook outside any focus session (the hub root, a plain terminal) changes no entry and adds none
before=$(cat "$ST/sessions/demo.$lp"); bin/changes projects/demo </dev/null >/dev/null 2>&1; bin/stop-check projects/demo </dev/null >/dev/null 2>&1
assert_eq "$(cat "$ST/sessions/demo.$lp")" "$before" "a hook outside the session leaves the entry alone"
assert_eq "$(ls -A "$ST/sessions" | wc -l | tr -d ' ')" "1" "no entry created by a stray hook"
kill "$(pgrep -P "$lp" | head -1)"; wait "$lp" 2>/dev/null
# an entry with no status yet (no prompt so far) shows - -
f=$(launch); PATH="$S:$PATH" bash "$f" & lp=$!
wait_for '[ -f "$ST/sessions/demo.$lp" ]' || fail "registered (no status)"
bin/sessions | grep -q "^demo .* -  *-  *claude$" || fail "no status shows as - -: $(bin/sessions)"
kill "$(pgrep -P "$lp" | head -1)"; wait "$lp" 2>/dev/null
# negatives: a dead launcher (killed hard) is pruned; bad arguments; --mine outside a Claude session
mkdir -p "$ST/sessions"; printf 'name=ghost\nfolder=projects/ghost\nlauncher=999999\nparent=1\nstarted=x\n' > "$ST/sessions/ghost.999999"
bin/sessions | grep -q "^ghost" && fail "dead launcher not listed"
[ ! -e "$ST/sessions/ghost.999999" ] || fail "dead entry pruned"
# a reused pid (a live process that is not a launcher) is pruned too
sleep 30 & other=$!; printf 'name=reused\nfolder=projects/x\nlauncher=%s\nparent=1\nstarted=x\n' "$other" > "$ST/sessions/reused.$other"
bin/sessions | grep -q "^reused" && fail "reused pid not listed"; [ ! -e "$ST/sessions/reused.$other" ] || fail "reused entry pruned"; kill "$other"
bin/sessions --parent x >/dev/null 2>&1; assert_eq "$?" "2" "bad --parent"
bin/sessions --nope >/dev/null 2>&1; assert_eq "$?" "2" "unknown option"
env -u CLAUDE_PID bin/sessions --mine >/dev/null 2>&1; assert_eq "$?" "2" "--mine needs CLAUDE_PID"
echo ok
