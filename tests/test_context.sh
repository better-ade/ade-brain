#!/bin/bash
. "$(dirname "$0")/helpers.sh"
make_hub; cd "$HUB"
bin/new projects/demo >/dev/null; bin/new ops/backups >/dev/null; rm ops/backups/STATE.md
out=$(bin/context); echo "$out" | grep -q "projects/demo" || fail "root lists folders"
echo "$out" | grep -q "(no STATE.md)" || fail "missing STATE.md tolerated"
bin/journal projects/demo "shipped #79" || fail "journal failed"
f="journal/$(date -u +%Y-%m-%d).md"; assert_contains "$f" "· projects/demo" "entry header"; assert_contains "$f" "shipped #79" "entry text"
bin/context projects/demo | grep -q "shipped #79" || fail "folder mode shows its journal"
bin/context projects/demo | grep -q "## Live" || fail "folder mode shows STATE"
# --rules: the shared rules, the Tools section and the hub memory index (a checkout session loads neither itself)
out=$(bin/context projects/demo --rules); echo "$out" | grep -q '^## Tools' || fail "--rules prints the Tools section"
echo "$out" | grep -q "^## Hub memory" && fail "an empty memory index prints a header"
echo '- [Deploy steps](deploy-steps.md) — staging first, then prod' >> memory/MEMORY.md
out=$(bin/context projects/demo --rules); echo "$out" | grep -q "^## Hub memory (read a file from $HUB/memory/" || fail "--rules names the hub memory dir: [$out]"
echo "$out" | grep -qxF -- '- [Deploy steps](deploy-steps.md) — staging first, then prod' || fail "--rules prints the memory index lines"
bin/context projects/demo | grep -q "Deploy steps" && fail "memory index printed without --rules"
# coordination: every focus session gets it (a checkout session does not load the hub CLAUDE.md); the main-agent section stays at the hub root
out=$(bin/context projects/demo --rules); echo "$out" | grep -q '^## Coordination' || fail "--rules prints the Coordination section"
echo "$out" | grep -q '^## The main agent' && fail "--rules leaves out the main-agent section"
bin/context projects/demo | grep -q '^## Coordination' && fail "Coordination printed without --rules"
# everything a focus session or its subagents produce reports to the main session
echo "$out" | grep -q "Report to the main session" || fail "--rules tells focus sessions to report to the main session"
echo "$out" | grep -q "subagents you start" || fail "--rules covers the subagents a focus session starts"
bin/journal >/dev/null 2>&1; assert_eq "$?" "2" "journal needs args"
touch -t 202001010000 projects/demo/STATE.md
bin/stop-check projects/demo | grep -q "STATE.md" || fail "stop-check reminds"
# story T1: ade at session start, in the hub root and in a folder session (--rules)
# ade_missing_installs: no ade, the hook returns at once with the installing line; one install runs, in the background
ade_sandbox; s=$(date +%s); out=$(bin/context); e=$(date +%s)
[ $((e - s)) -lt 3 ] || fail "ade_missing_installs: the session start waited for the install ($((e - s)) s)"
echo "$out" | grep -q "^ade: not installed; installing it in the background (log: $HOME/.agent-hub/hub/ade/install.log)" || fail "ade_missing_installs: the installing line: [$out]"
echo "$out" | grep -q "bin/ scripts do the same jobs" || fail "ade_missing_installs: names the bin/ scripts meanwhile"
ade_wait test -s "$ADE_FAKE_RUNS" || fail "ade_missing_installs: the installer never ran"
out=$(bin/context projects/demo --rules); echo "$out" | grep -q "^ade: not installed; installing it in the background" || fail "ade_missing_installs: a folder session gets the line: [$out]"
sleep 0.5; assert_eq "$(runs_of "$ADE_FAKE_RUNS")" 1 "ade_missing_installs: a second start while it runs starts no other"
touch "$ADE_FAKE_RELEASE"; ade_wait test ! -e "$HOME/.agent-hub/hub/ade/install.lock" || fail "ade_missing_installs: the lock stayed"
[ -x "$HOME/.local/bin/ade" ] || fail "ade_missing_installs: the installer put no ade in ~/.local/bin"
out=$(bin/context); echo "$out" | grep -qF "ade: ade 9.9.9 is installed at $HOME/.local/bin/ade, not on PATH: run it by that path (\`$HOME/.local/bin/ade help\`" || fail "ade_missing_installs: the next start finds the new ade in ~/.local/bin and names its path: [$out]"
# an installer that exits 0 but puts no ade anywhere is a failure, reported on the next start
ade_sandbox; touch "$ADE_FAKE_RELEASE"; printf 'sudo true\nexit 0\n' > "${ADE_CLI_INSTALL_URL#file://}"; bin/context >/dev/null
ade_wait test -e "$HOME/.agent-hub/hub/ade/install.failed" || fail "ade_missing_installs: an installer without an ade is not a success"
assert_contains "$HOME/.agent-hub/hub/ade/install.log" "sudo refused" "ade_missing_installs: a session start never prompts for sudo"
bin/context | grep -q "^ade: the last install failed (the installer finished but no ade is on PATH or in ~/.local/bin;" || fail "ade_missing_installs: no-ade install reported"
# ade_install_failed: the next start reports the failure with the log's last line
ade_sandbox; export ADE_FAKE_FAIL=1; touch "$ADE_FAKE_RELEASE"; bin/context >/dev/null
ade_wait test -s "$ADE_FAKE_RUNS" && ade_wait test ! -e "$HOME/.agent-hub/hub/ade/install.lock" || fail "ade_install_failed: the install did not finish"
out=$(bin/context); echo "$out" | grep -q "^ade: the last install failed (fake: download failed; log: $HOME/.agent-hub/hub/ade/install.log)" || fail "ade_install_failed: [$out]"
unset ADE_FAKE_FAIL
# ade_install_off: HUB_ADE_INSTALL=off in hub.conf downloads nothing and gives the install command
ade_sandbox; cp hub.conf hub.conf.t1 2>/dev/null; trap 'if [ -f hub.conf.t1 ]; then mv hub.conf.t1 hub.conf; else rm -f hub.conf; fi' EXIT
echo HUB_ADE_INSTALL=off >> hub.conf
out=$(bin/context); sleep 0.5; assert_eq "$(runs_of "$ADE_FAKE_RUNS")" 0 "ade_install_off: nothing downloaded"
echo "$out" | grep -qF "ade: not installed (HUB_ADE_INSTALL=off); install it by hand: curl -fsSL $ADE_CLI_INSTALL_URL | bash" || fail "ade_install_off: the install command: [$out]"
if [ -f hub.conf.t1 ]; then mv hub.conf.t1 hub.conf; else rm -f hub.conf; fi
# ade_install_env_ignored: an exported HUB_ADE_INSTALL=off does not turn the install off when hub.conf is silent
ade_sandbox; out=$(HUB_ADE_INSTALL=off bin/context); ade_wait test -s "$ADE_FAKE_RUNS" || fail "ade_install_env_ignored: the environment switched the install off: [$out]"
# ade_present_help: an ade on PATH: its version and the `ade help` line, and no install
ade_sandbox; FA="$(mktemp -d)"; printf '#!/bin/sh\n[ "$1" = --version ] && echo "ade 1.2.3"\n' > "$FA/ade"; chmod +x "$FA/ade"; PATH="$FA:$PATH"
out=$(bin/context projects/demo --rules); sleep 0.5
echo "$out" | grep -qF 'ade: ade 1.2.3 is installed; `ade help` lists its commands: run it before the first ade command in a session' || fail "ade_present_help: [$out]"
assert_eq "$(runs_of "$ADE_FAKE_RUNS")" 0 "ade_present_help: no install"
[ -e "$HOME/.agent-hub/hub/ade" ] && fail "ade_present_help: install state written"
echo ok
