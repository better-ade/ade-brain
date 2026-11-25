#!/bin/bash
. "$(dirname "$0")/helpers.sh"
make_hub; cd "$HUB"; . bin/lib.sh
# --- the hub's Claude install pins its config dir (memory and skills go there, whatever the shell has) ---
W="$(mktemp -d)"; CD="$(mktemp -d)/.claude-work"
printf '#!/bin/bash\nexport CLAUDE_CONFIG_DIR="%s"\nexec claude "$@"\n' "$CD" > "$W/claude-work"; chmod +x "$W/claude-work"
D="$(mktemp -d)/h1"
PATH="$W:$PATH" bin/init --persona tech-lead --client "Acme" --owner "Sam" --dest "$D" --claude claude-work \
  --model opus --effort high --agent-model sonnet --briefing-model sonnet >/dev/null || fail "init with models failed"
. "$D/hub.conf"; . "$D/.local/hub.conf"   # the install is per machine (story I1)
assert_eq "$HUB_CLAUDE_CONFIG_DIR" "$CD" "config dir read from the wrapper"
assert_eq "$HUB_MODEL/$HUB_EFFORT/$HUB_AGENT_MODEL/$HUB_BRIEFING_MODEL" "opus/high/sonnet/sonnet" "model defaults"
assert_contains "$D/.claude/agents/planning.md" "model: sonnet" "folder agents use the agent model"
assert_contains "$D/.claude/agents/tech-lead.md" "model: opus" "the persona agent uses the hub model"
# setup links into the hub's install, even when the shell points at another one
(cd "$D" && env -u HUB -u CLAUDE_HOME CLAUDE_CONFIG_DIR=/tmp/elsewhere bin/setup >/dev/null 2>&1) || fail "setup failed"
[ -L "$CD/projects/$(encode_path "$D")/memory" ] || fail "memory not linked into the hub's install"
[ -e "/tmp/elsewhere/projects/$(encode_path "$D")" ] && fail "linked into the shell's install"
out=$(cd "$D" && env -u HUB -u CLAUDE_HOME DOCTOR_OFFLINE=1 bin/doctor); echo "$out" | grep -qE "^OK +hub memory link" || fail "doctor: link ok [$out]"
rm "$CD/projects/$(encode_path "$D")/memory"
out=$(cd "$D" && env -u HUB -u CLAUDE_HOME DOCTOR_OFFLINE=1 bin/doctor); echo "$out" | grep -qE "^MISSING +hub memory link .*bin/setup" || fail "doctor: missing link"
echo "$out" | grep -qE "claude install +claude-work \($CD\)" || fail "doctor names the install"
# an explicit --claude-config-dir wins; a plain claude command means ~/.claude
D2="$(mktemp -d)/h2"; bin/init --persona qa-test-engineer --client B --owner C --dest "$D2" --claude-config-dir /x/cfg >/dev/null || fail "init 2"
assert_eq "$(. "$D2/.local/hub.conf"; echo "$HUB_CLAUDE_CONFIG_DIR")" "/x/cfg" "explicit config dir"
D3="$(mktemp -d)/h3"; bin/init --persona qa-test-engineer --client B --owner C --dest "$D3" >/dev/null || fail "init 3"
assert_eq "$(. "$D3/.local/hub.conf"; echo "$HUB_CLAUDE_CONFIG_DIR")" "$HOME/.claude" "plain claude uses ~/.claude"
bin/init --persona tech-lead --client B --owner C --model 'opus;rm' --dest "$(mktemp -d)/bad" >/dev/null 2>&1; assert_eq "$?" "2" "unsafe model refused"
bin/init --persona tech-lead --client B --owner C --effort huge --dest "$(mktemp -d)/bad" >/dev/null 2>&1; assert_eq "$?" "2" "bad effort refused"
# --- HUB_SUBAGENT_MODEL is a fallback only: no settings env (it would override ADE's); bin/work applies it at launch ---
noenv() { python3 -c 'import json,sys; sys.exit("env" in json.load(open(sys.argv[1])))' "$1"; }
for f in "$REPO/.claude/settings.json" "$REPO/templates/folder-settings.json" "$REPO/templates/folder-settings-local.json" "$D3/.claude/settings.json" "$D3/projects/app/.claude/settings.json" "$D3/projects/app/.claude/settings.local.json"; do
  noenv "$f" || fail "no env block in $f (a settings env replaces ADE's value)"; done
assert_eq "$(. "$D3/hub.conf"; echo "$HUB_SUBAGENT_MODEL")" "sonnet" "subagent model default"
D4="$(mktemp -d)/h4"; bin/init --persona qa-test-engineer --client B --owner C --dest "$D4" --subagent-model haiku >/dev/null || fail "init 4"
assert_eq "$(. "$D4/hub.conf"; echo "$HUB_SUBAGENT_MODEL")" "haiku" "--subagent-model"
bin/init --persona tech-lead --client B --owner C --subagent-model 'x"y' --dest "$(mktemp -d)/bad" >/dev/null 2>&1; assert_eq "$?" "2" "unsafe subagent model refused"
# a context suffix (sonnet[1m]) is a valid subagent model, as bin/work accepts it; hub.conf keeps it as given
D5="$(mktemp -d)/h5"; bin/init --persona qa-test-engineer --client B --owner C --dest "$D5" --subagent-model 'sonnet[1m]' >/dev/null 2>&1 || fail "init with --subagent-model sonnet[1m]"
assert_eq "$(. "$D5/hub.conf"; echo "$HUB_SUBAGENT_MODEL")" "sonnet[1m]" "--subagent-model keeps a bracket suffix"
# sub ENV...: the launcher bin/work writes (WORK_NO_OPEN: nothing opened), printed and removed
sub() { local o l; o=$(cd "$D4" && env -u HUB -u CLAUDE_HOME WORK_NO_OPEN=1 "$@" bin/work --no-remote projects/app) || return $?
  l=$(printf '%s\n' "$o" | sed -n 's/^launcher: //p'); cat "$l"; rm -f "$l"; }
out=$(sub env -u CLAUDE_CODE_SUBAGENT_MODEL) || fail "work 4"
echo "$out" | grep -qF 'export CLAUDE_CODE_SUBAGENT_MODEL="${CLAUDE_CODE_SUBAGENT_MODEL:-haiku}"' || fail "work falls back to HUB_SUBAGENT_MODEL [$out]"
echo "$out" | grep -q "_FORCE" && fail "an explicit subagent model must still win (no _FORCE)"
x=$(echo "$out" | grep '^export CLAUDE_CODE_SUBAGENT_MODEL=')
assert_eq "$(env -u CLAUDE_CODE_SUBAGENT_MODEL bash -c "$x; echo \$CLAUDE_CODE_SUBAGENT_MODEL")" "haiku" "the launcher exports the fallback"
assert_eq "$(CLAUDE_CODE_SUBAGENT_MODEL=opus bash -c "$x; echo \$CLAUDE_CODE_SUBAGENT_MODEL")" "opus" "the launcher's own value wins"
out=$(sub env CLAUDE_CODE_SUBAGENT_MODEL=opus) || fail "work 4 env"
echo "$out" | grep -qF 'CLAUDE_CODE_SUBAGENT_MODEL="${CLAUDE_CODE_SUBAGENT_MODEL:-opus}"' || fail "an inherited (ADE) value wins over hub.conf [$out]"
sed -i.bak 's/^HUB_SUBAGENT_MODEL=.*/HUB_SUBAGENT_MODEL=/' "$D4/hub.conf"
out=$(sub env -u CLAUDE_CODE_SUBAGENT_MODEL); echo "$out" | grep -qF ':-sonnet}' || fail "an empty HUB_SUBAGENT_MODEL means sonnet"
sed -i.bak 's/^HUB_SUBAGENT_MODEL=.*/HUB_SUBAGENT_MODEL="x;y"/' "$D4/hub.conf"
sub env -u CLAUDE_CODE_SUBAGENT_MODEL >/dev/null 2>&1; assert_eq "$?" "2" "bad HUB_SUBAGENT_MODEL refused"
sub env 'CLAUDE_CODE_SUBAGENT_MODEL=a b' >/dev/null 2>&1; assert_eq "$?" "2" "bad inherited subagent model refused"
sub env 'CLAUDE_CODE_SUBAGENT_MODEL=a"b' >/dev/null 2>&1; assert_eq "$?" "2" "a quote in the inherited subagent model refused"
# a 1M-context suffix (engines.md: sonnet[1m]) is a valid name ADE may set: kept, and exported as given
out=$(sub env 'CLAUDE_CODE_SUBAGENT_MODEL=sonnet[1m]') || fail "an inherited sonnet[1m] was refused"
x=$(echo "$out" | grep '^export CLAUDE_CODE_SUBAGENT_MODEL=')
assert_eq "$(env -u CLAUDE_CODE_SUBAGENT_MODEL bash -c "$x; echo \$CLAUDE_CODE_SUBAGENT_MODEL")" "sonnet[1m]" "a bracket suffix reaches the session"
# --- BMAD overrides: their wording is ade-method's (story C1); test_method.sh keeps _bmad/custom/ equal to the pin ---
# --- persona model suggestion: the default when --model is not given ---
grep -q "^model: opus" personas/fractional-cto.md || fail "fractional CTO suggests opus"
assert_eq "$(. "$D3/hub.conf"; echo "$HUB_MODEL")" "$(awk -F': ' '$1=="model"{print $2; exit}' personas/qa-test-engineer.md)" "persona model is the default"
# --- bin/work uses the defaults; the command line wins ---
cd "$D"; R="$(mktemp -d)/code"; mkdir -p "$R"; printf '| acme/code | %s | main | Sam | none |\n' "$R" >> projects/planning/ACCESS.md
mkdir -p projects/planning/.claude/agents; printf -- '---\nname: rev\ndescription: r\n---\nreview\n' > projects/planning/.claude/agents/rev.md
out=$(env -u HUB -u CLAUDE_HOME WORK_DRY=1 bin/work projects/planning)
echo "$out" | grep -q "' claude-work --settings" || fail "work runs the hub's install"
echo "$out" | grep -q -- "--model opus" || fail "work uses HUB_MODEL"; echo "$out" | grep -q -- "--effort high" || fail "work uses HUB_EFFORT"
echo "$out" | grep -q '\\"model\\":\\"sonnet\\"' || fail "agents use HUB_AGENT_MODEL [$out]"
out=$(env -u HUB -u CLAUDE_HOME WORK_DRY=1 bin/work --model haiku --agent-model rev=opus projects/planning)
echo "$out" | grep -q -- "--model haiku" || fail "--model wins"; echo "$out" | grep -q -- "--model opus" && fail "default model also passed"
echo "$out" | grep -q '\\"model\\":\\"opus\\"' || fail "--agent-model name=M wins"
# --- the briefing uses HUB_BRIEFING_MODEL ---
S="$(mktemp -d)"; printf '#!/bin/bash\necho "$@" > "%s/args"; echo ok-brief\n' "$S" > "$S/fc"; chmod +x "$S/fc"
env -u HUB MONITOR_QUIET=1 AGENT_CLAUDE="$S/fc" bin/briefing >/dev/null || fail "briefing failed"
assert_contains "$S/args" "--model sonnet" "briefing model from hub.conf"
# --- bin/models: show and change every model setting after init ---
m() { (cd "$D" && env -u HUB bin/models "$@"); }
out=$(m) || fail "models show failed"
for k in "root +HUB_ROOT_MODEL" "focus +HUB_MODEL +opus" "agents +HUB_AGENT_MODEL +sonnet" "subagents +HUB_SUBAGENT_MODEL" "briefing +HUB_BRIEFING_MODEL +sonnet"; do
  echo "$out" | grep -qE "^$k" || fail "models shows $k [$out]"; done
m set agents haiku >/dev/null || fail "set agents"
. "$D/hub.conf"; assert_eq "$HUB_AGENT_MODEL" "haiku" "set agents writes hub.conf"
assert_contains "$D/.claude/agents/planning.md" "model: haiku" "set agents rewrites the folder agents"
assert_contains "$D/.claude/agents/tech-lead.md" "model: opus" "set agents leaves the persona agent"
assert_eq "$HUB_OWNER" "Sam" "other hub.conf values are kept"
m set focus sonnet >/dev/null || fail "set focus"
. "$D/hub.conf"; assert_eq "$HUB_MODEL" "sonnet" "set focus writes HUB_MODEL"
assert_contains "$D/.claude/agents/tech-lead.md" "model: sonnet" "set focus updates the persona agent"
(cd "$D" && env -u HUB bin/new projects/mdl >/dev/null && env -u HUB WORK_DRY=1 bin/work projects/mdl) | grep -q -- "--model sonnet" || fail "focus sessions start on the focus model"
m set root opus >/dev/null || fail "set root"
assert_eq "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["model"])' "$D/.claude/settings.json")" "opus" "set root writes the root settings"
m set all 'opus[1m]' >/dev/null || fail "set all"
. "$D/hub.conf"; assert_eq "$HUB_ROOT_MODEL/$HUB_MODEL/$HUB_AGENT_MODEL/$HUB_SUBAGENT_MODEL/$HUB_BRIEFING_MODEL" "opus[1m]/opus[1m]/opus[1m]/opus[1m]/opus[1m]" "set all sets every model"
grep -q "^model: opus\[1m\]$" "$D/.claude/agents/planning.md" || fail "set all rewrites the agents"
# negatives: nothing changes on a refused call
cp "$D/hub.conf" "$S/conf.before"
m set agents 'x;rm -rf' >/dev/null 2>&1; assert_eq "$?" "2" "bad model name refused"
m set nope opus >/dev/null 2>&1; assert_eq "$?" "2" "unknown scope refused"
m set agents >/dev/null 2>&1; assert_eq "$?" "2" "missing model refused"
m frob >/dev/null 2>&1; assert_eq "$?" "2" "unknown command refused"
cmp -s "$D/hub.conf" "$S/conf.before" || fail "a refused call changed hub.conf"
echo ok
