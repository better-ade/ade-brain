#!/bin/bash
# The Gemini CLI engine (story E1, .ade/context/engines.md "Gemini CLI engine"): role entries gemini:<model>, bin/work,
# bin/agent, bin/gemini-run, bin/sessions and bin/dispatch with a gemini pick.
# bash tests/test_engines.sh [check ...] runs only the named checks (all of them by default).
# Hermetic: a fake `gemini` and a fake `claude` first on PATH, a stub bin/secret in the hub copy, a temp HOME. No vendor
# and no real key is ever reached. tests/test_gemini_real.sh runs the real CLI offline (opt-in).
. "$(dirname "$0")/helpers.sh"
make_hub; cd "$HUB"
unset CLAUDE_CONFIG_DIR HUB_CLAUDE_CONFIG_DIR AGENT_CLAUDE AGENT_FOLDER AGENT_TIMEOUT GEMINI_CLI_HOME GEMINI_API_KEY GOOGLE_API_KEY AGENT_GEMINI_LOOPBACK_URL
S="$(mktemp -d)"; S="$(cd "$S" && pwd -P)"; mkdir -p "$S/tmp" "$S/home" "$S/cap" "$S/state" "$S/bin"
export TMPDIR="$S/tmp" HOME="$S/home" AGENT_STATE="$S/state"
trap 'rm -rf "$S" "$(dirname "$HUB")" "$CLAUDE_HOME" "$(dirname "$AGENT_SYNC_LOG")" "$(dirname "$AGENT_SYNC_LOCK")"' EXIT
bin/new projects/demo >/dev/null
CK="$S/demo-code"; mkdir -p "$CK" && git -C "$CK" init -q
printf '| demo-code | %s | main | Owner | none |\n' "$CK" >> projects/demo/ACCESS.md
C="$S/cap"; KEY="AIzaENGINETEST-$RANDOM$RANDOM-c0ffee"; TASK="TASK-TEXT-$RANDOM$RANDOM"
GH="$HUB/.local/engines"   # the hub's own Gemini CLI homes (GEMINI_CLI_HOME), one per sign-in
# the fake gemini records what it was given: argv, environment, cwd, stdin, its settings layer (the user settings in
# GEMINI_CLI_HOME), the --admin-policy file, and its parent's environment (where else the key is visible)
cat > "$S/bin/gemini" <<STUB
#!/bin/bash
C="$C"; [ "\${1:-}" = --version ] && { echo "0.0.0-fake"; exit 0; }
echo run >> "\$C/runs"; printf '%s\n' "\$@" > "\$C/argv"; env > "\$C/env"; pwd -P > "\$C/cwd"
[ -t 0 ] || cat > "\$C/stdin"
[ -f "\${GEMINI_CLI_HOME:-/nonexistent}/.gemini/settings.json" ] && cp "\$GEMINI_CLI_HOME/.gemini/settings.json" "\$C/settings.json"
p=""; for a in "\$@"; do [ "\$p" = --admin-policy ] && cp "\$a" "\$C/policy.toml"; p="\$a"; done
if [ -r "/proc/\$PPID/environ" ]; then tr '\0' '\n' < "/proc/\$PPID/environ" > "\$C/parent.env"; else ps -wwE -o command= -p "\$PPID" > "\$C/parent.env" 2>/dev/null; fi
sh -c 'printenv GEMINI_API_KEY' > "\$C/child.key" 2>/dev/null
[ -f "$S/behave" ] && . "$S/behave"
echo "report from the fake gemini"
STUB
# a fake claude: any call is recorded, so a check can prove Claude Code never ran
printf '#!/bin/bash\necho run >> "%s/claude.runs"; echo "fake claude"\n' "$C" > "$S/bin/claude"
# the stub keeps its paths inside (bin/agent's run clears the environment); RT_SECRET_MODE=empty answers an empty key
cat > bin/secret <<STUB
#!/bin/bash
echo "secret \$*" >> "$S/calls"
case "\$1" in --has) grep -qx "\$2" "$S/stored"; exit;; esac
grep -qx "\$1" "$S/stored" || exit 1
[ "\${RT_SECRET_MODE:-}" = empty ] || printf '%s' "$KEY"
STUB
chmod +x "$S/bin/gemini" "$S/bin/claude" bin/secret; export PATH="$S/bin:$PATH"

conf() { printf '%s\n' "$@" > hub.conf; }
owner() { conf 'HUB_PROVIDERS_ALLOWED="anthropic gemini"' 'HUB_OWNED_BY_OWNER=1' 'HUB_ROLE_BUILDER="gemini:gemini-2.5-pro anthropic:opus"' "$@"; }
reset() { rm -rf "$C" "$S/behave" "$HOME/.gemini" "$CK/.gemini" "$GH" "$S/elsewhere"; mkdir -p "$C"; : > "$S/calls"; echo gemini-api-key > "$S/stored"; owner; }
nokey() { : > "$S/stored"; }
google() { mkdir -p "$GH/gemini-google/.gemini"; echo '{"fake": true}' > "$GH/gemini-google/.gemini/oauth_creds.json"; }
ran() { [ -e "$C/runs" ]; }
envval() { sed -n "s/^$1=//p" "$C/env"; }
arg_after() { awk -v k="$1" 'p{print; exit} $0==k{p=1}' "$C/argv"; }
no_secret_in() { local f; for f in "$@"; do [ ! -e "$f" ] || ! grep -qF -- "$KEY" "$f" || fail "the key value is in $f"; done; }
# launch [bin/work args...]: write the launcher (WORK_NO_OPEN) and run it to the end, as a terminal would
launch() { L="$(WORK_NO_OPEN=1 bin/work "$@" 2> "$S/err" | tee "$S/out" | sed -n 's/^launcher: //p')"; [ -n "$L" ] && [ -x "$L" ] || fail "no launcher: $(cat "$S/out" "$S/err")"
  cp "$L" "$S/launcher.copy"; bash "$L" > "$S/lout" 2> "$S/lerr" < /dev/null; }
setting() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."): d=d[k]
print(json.dumps(d))' "$1" "$2"; }
agent() { printf '%s\n' "$TASK" | bin/agent --role builder --folder projects/demo > "$S/out" 2> "$S/err"; rc=$?; }

role_table_takes_gemini() {   # AC1
  reset; bin/roles > "$S/roles" 2>&1; assert_eq "$?" 0 "bin/roles exit: $(cat "$S/roles")"
  grep -q '^builder  *gemini:gemini-2.5-pro .*engine gemini' "$S/roles" || fail "builder shown with its engine: $(cat "$S/roles")"
  assert_eq "$( . bin/lib.sh; role_candidates builder | tr '\n' ' ')" "gemini:gemini-2.5-pro anthropic:opus " "gemini entry accepted"
  assert_eq "$( . bin/lib.sh; engine_of gemini; engine_of anthropic; engine_of deepseek)" "gemini
claude
claude" "engine of each provider"
  conf 'HUB_ROLE_BUILDER="gemini:gpt-5"'; ( . bin/lib.sh; role_candidates builder ) >/dev/null 2>&1; assert_eq "$?" 2 "a non-Gemini model is a bad entry"
  grep -q '^routine  *anthropic:sonnet$' "$S/roles" || fail "claude roles keep their plain line: $(cat "$S/roles")"
  # no Gemini CLI installed: a skip reason, and nothing starts
  reset; owner 'HUB_ROLE_BUILDER="gemini:gemini-2.5-pro"'; mv "$S/bin/gemini" "$S/gemini.off"
  local np d; np=""; local IFS=:; for d in $PATH; do [ -x "$d/gemini" ] || np="$np${np:+:}$d"; done; unset IFS   # no real gemini either
  PATH="$np" bin/roles > "$S/roles" 2>&1; grep -q "skipped gemini:gemini-2.5-pro: the Gemini CLI (gemini) is not installed" "$S/roles" || fail "missing CLI: $(cat "$S/roles")"
  PATH="$np" WORK_DRY=1 bin/work --role builder projects/demo >/dev/null 2>&1; assert_eq "$?" 1 "bin/work without the CLI"
  PATH="$np" WORK_DRY=1 bin/work --provider gemini --model gemini-2.5-pro projects/demo >/dev/null 2>&1; assert_eq "$?" 1 "bin/work --provider gemini without the CLI"
  mv "$S/gemini.off" "$S/bin/gemini"
}
work_launches_gemini() {   # AC2
  reset; launch --role builder projects/demo; ran || fail "gemini did not run: $(cat "$S/lerr")"
  [ ! -e "$C/claude.runs" ] || fail "Claude Code ran"
  assert_eq "$(cat "$C/cwd")" "$CK" "runs in the checkout"
  assert_eq "$(arg_after -m)" gemini-2.5-pro "model passed with -m"
  for f in --settings --permission-mode --remote-control --agents --effort --model --dangerously-skip-permissions; do
    grep -qx -- "$f" "$C/argv" && fail "Claude Code flag $f given to gemini"; done
  assert_eq "$(arg_after --approval-mode)" auto_edit "the hub's default mode (auto) is auto_edit"
  assert_eq "$(envval AGENT_FOLDER)" projects/demo "AGENT_FOLDER"
  assert_eq "$(envval GEMINI_CLI_HOME)" "$GH/gemini-key" "the hub's own Gemini home (a user layer the CLI loads)"
  grep -q '^GEMINI_CLI_SYSTEM_SETTINGS_PATH=' "$C/env" && fail "no system-settings slot (the CLI skips a file not owned by root)"
  setting "$C/settings.json" context.fileName | grep -q '"CLAUDE.md"' || fail "rules file in context.fileName: $(cat "$C/settings.json")"
  setting "$C/settings.json" context.fileName | grep -q '"AGENTS.md"' || fail "AGENTS.md in context.fileName"
  assert_eq "$(setting "$C/settings.json" advanced.ignoreLocalEnv)" true "a checkout .env is not loaded"
  assert_eq "$(setting "$C/settings.json" tools.discoveryCommand)" '""' "no tool discovery command"
  assert_eq "$(setting "$C/settings.json" hooksConfig.enabled)" false "no hooks"
  [ -f "$C/policy.toml" ] || fail "the hub's admin policy is passed (--admin-policy)"
  grep -qx -- --skip-trust "$C/argv" && fail "a focus session keeps the CLI's own trust prompt"
  WORK_DRY=1 bin/work --role builder --prompt "bmad-build 1.1" --mode manual projects/demo > "$S/dry" 2>&1 || fail "dry run: $(cat "$S/dry")"
  grep -q "/bin/gemini-run' --auth key --mode focus" "$S/dry" || fail "dry run shows the gemini command: $(cat "$S/dry")"
  grep -q -- "--approval-mode default" "$S/dry" || fail "--mode manual is approval mode default"
  grep -q -- "-i bmad-build\\\\ 1.1" "$S/dry" || fail "the prompt is the first message (-i): $(cat "$S/dry")"
  WORK_DRY=1 bin/work --role builder --effort high projects/demo >/dev/null 2>&1; assert_eq "$?" 2 "--effort is a Claude Code flag"
}
yolo_refused() {   # AC3
  reset; local a
  for a in --yolo -y -dy --approval-mode=yolo --approvalMode=yolo --APPROVAL-MODE=yolo; do
    WORK_DRY=1 bin/work --role builder projects/demo "$a" >/dev/null 2> "$S/err"; assert_eq "$?" 2 "work $a"
    grep -qi yolo "$S/err" || fail "reason names yolo: $(cat "$S/err")"; done
  WORK_DRY=1 bin/work --role builder projects/demo --approval-mode yolo >/dev/null 2>&1; assert_eq "$?" 2 "work --approval-mode yolo"
  printf 'HUB_WORK_MODE=yolo\n' >> hub.conf; WORK_DRY=1 bin/work --role builder projects/demo >/dev/null 2>&1; assert_eq "$?" 2 "HUB_WORK_MODE=yolo"
  reset; for a in "--yolo" "-y" "--approval-mode yolo" "--approvalMode yolo" "--approvalMode=yolo" "-m gemini-2.5-pro --approval-mode=yolo"; do
    (cd "$CK" && "$HUB/bin/gemini-run" --auth google --mode focus $a >/dev/null 2>&1); assert_eq "$?" 2 "gemini-run $a"; done
  ran && fail "gemini ran with yolo"
  (cd "$CK" && "$HUB/bin/gemini-run" --auth google --mode focus -i "-y is only a prompt" >/dev/null 2>&1); assert_eq "$?" 1 "a prompt is not a flag (refused later only for the missing login)"
  launch --role builder projects/demo; assert_eq "$(setting "$C/settings.json" security.disableYoloMode)" true "the layer disables yolo"
  grep -q 'modes = \["yolo"\]' "$C/policy.toml" && grep -q 'decision = "ask_user"' "$C/policy.toml" || fail "the policy asks in yolo mode anyway: $(cat "$C/policy.toml")"
}
no_signin_refused() {   # AC4
  reset; nokey; WORK_NO_OPEN=1 bin/work --role builder projects/demo > "$S/out" 2> "$S/err"; assert_eq "$?" 0 "falls to anthropic:opus: $(cat "$S/err")"
  grep -q "^work: skipped gemini:gemini-2.5-pro: .*bin/keys set gemini" "$S/err" || fail "the skip is said, not silent: $(cat "$S/err")"
  owner 'HUB_ROLE_BUILDER="gemini:gemini-2.5-pro"'
  WORK_NO_OPEN=1 bin/work --role builder projects/demo > "$S/out" 2> "$S/err"; assert_eq "$?" 1 "no sign-in, no key"
  grep -q "bin/keys set gemini" "$S/err" && grep -q "GEMINI_CLI_HOME=.*gemini-google" "$S/err" || fail "hint: $(cat "$S/err")"
  grep -q '^launcher:' "$S/out" && fail "a launcher was written"
  ran && fail "gemini ran"; [ ! -e "$C/claude.runs" ] || fail "fell back to Claude Code"
  WORK_NO_OPEN=1 bin/work --provider gemini --model gemini-2.5-pro projects/demo > "$S/out" 2> "$S/err"; assert_eq "$?" 1 "--provider gemini, no sign-in"
  agent; assert_eq "$rc" 2 "agent: no sign-in"; grep -q "bin/keys set gemini" "$S/err" || fail "agent hint: $(cat "$S/err")"; ran && fail "agent ran gemini"
  # a login elsewhere (the caller's GEMINI_CLI_HOME or ~/.gemini) is not the CLI's login here: the home is pinned
  mkdir -p "$S/elsewhere/.gemini" "$HOME/.gemini"; echo '{}' > "$S/elsewhere/.gemini/oauth_creds.json"; echo '{}' > "$HOME/.gemini/oauth_creds.json"
  GEMINI_CLI_HOME="$S/elsewhere" WORK_NO_OPEN=1 bin/work --role builder projects/demo >/dev/null 2>&1; assert_eq "$?" 1 "another home's login does not count"
  reset; nokey; google; GEMINI_CLI_HOME="$S/elsewhere" launch --role builder projects/demo; ran || fail "the hub home's login is a sign-in: $(cat "$S/err" "$S/lerr")"
  assert_eq "$(envval GEMINI_CLI_HOME)" "$GH/gemini-google" "the CLI gets the same home the login was judged in"
  assert_eq "$(setting "$C/settings.json" security.auth.selectedType)" '"oauth-personal"' "login auth"
  assert_eq "$(envval GEMINI_API_KEY)" "" "a login run has no key"
  assert_eq "$(grep -c '^secret [^-]' "$S/calls")" 0 "a login run reads no key"
}
key_only_in_gemini() {   # AC5
  reset; GEMINI_API_KEY=from-the-shell GOOGLE_API_KEY=from-the-shell GOOGLE_GEMINI_BASE_URL=https://elsewhere.example GEMINI_CLI_TRUST_WORKSPACE=true launch --role builder projects/demo
  ran || fail "gemini did not run: $(cat "$S/lerr")"
  assert_eq "$(envval GEMINI_API_KEY)" "$KEY" "the stored key reaches gemini (and the shell's does not)"
  local v; for v in GOOGLE_API_KEY GOOGLE_GEMINI_BASE_URL GOOGLE_GENAI_USE_VERTEXAI GOOGLE_APPLICATION_CREDENTIALS GEMINI_CLI_TRUST_WORKSPACE; do
    grep -qx "$v=" "$C/env" || fail "$v is set empty, so no .env file can set it: $(grep "^$v" "$C/env")"; done
  grep -qF -- "$KEY" "$C/parent.env" && fail "the key is visible to gemini's parent (the launcher)"
  [ -s "$C/parent.env" ] || fail "the parent's environment could not be read (the check would prove nothing)"
  assert_eq "$(cat "$C/child.key")" "$KEY" "a plain child of the CLI inherits it: only the CLI's redaction (on) keeps it from tools (engines.md)"
  assert_eq "$(setting "$C/settings.json" security.auth.selectedType)" '"gemini-api-key"' "key auth"
  assert_eq "$(setting "$C/settings.json" security.environmentVariableRedaction.enabled)" true "tool children get the key redacted"
  setting "$C/settings.json" security.environmentVariableRedaction.blocked | grep -q '"GEMINI_API_KEY"' || fail "GEMINI_API_KEY is on the redaction list"
  no_secret_in "$C/argv" "$S/launcher.copy" "$C/settings.json" "$C/policy.toml" "$S/out" "$S/err" "$S/lout" "$S/lerr"
  grep -rlF -- "$KEY" "$HUB" "$CK" "$S/state" 2>/dev/null | grep -vx "$HUB/bin/secret" | grep -q . && fail "the key is in a file in the hub, the checkout or the state dir"
  grep -q 'GEMINI_API_KEY=' "$S/launcher.copy" && fail "the launcher sets the key itself"
  reset; RT_SECRET_MODE=empty WORK_NO_OPEN=1 bin/work --role builder projects/demo >/dev/null 2> "$S/err"; assert_eq "$?" 1 "an empty key is refused"
}
gemini_allowed_per_hub() {   # AC6
  reset; conf 'HUB_PROVIDERS_ALLOWED="anthropic"' 'HUB_OWNED_BY_OWNER=1' 'HUB_ROLE_BUILDER="gemini:gemini-2.5-pro"'
  WORK_DRY=1 bin/work --role builder projects/demo >/dev/null 2> "$S/err"; assert_eq "$?" 1 "not in HUB_PROVIDERS_ALLOWED"
  grep -q "not in HUB_PROVIDERS_ALLOWED" "$S/err" || fail "reason: $(cat "$S/err")"
  (cd "$CK" && "$HUB/bin/gemini-run" --auth key --mode focus -m gemini-2.5-pro > /dev/null 2> "$S/err"); assert_eq "$?" 2 "gemini-run itself checks the allowlist"
  conf 'HUB_PROVIDERS_ALLOWED="anthropic gemini"' 'HUB_ROLE_BUILDER="gemini:gemini-2.5-pro anthropic:opus"'
  bin/roles > "$S/roles" 2>&1; grep -q '^builder  *anthropic:opus' "$S/roles" || fail "client hub skips gemini: $(cat "$S/roles")"
  grep -q "skipped gemini:gemini-2.5-pro: .*HUB_GEMINI_CLIENT_APPROVED" "$S/roles" || fail "client reason: $(cat "$S/roles")"
  WORK_DRY=1 bin/work --provider gemini --model gemini-2.5-pro projects/demo >/dev/null 2>&1; assert_eq "$?" 2 "client hub, --provider gemini"
  (cd "$CK" && "$HUB/bin/gemini-run" --auth key --mode agent -m gemini-2.5-pro > /dev/null 2> "$S/err"); assert_eq "$?" 2 "gemini-run itself checks the client approval"
  grep -q HUB_GEMINI_CLIENT_APPROVED "$S/err" || fail "gemini-run says why: $(cat "$S/err")"; ran && fail "gemini ran in a client hub"
  conf 'HUB_PROVIDERS_ALLOWED="anthropic gemini"' 'HUB_GEMINI_CLIENT_APPROVED=1' 'HUB_ROLE_BUILDER="gemini:gemini-2.5-pro anthropic:opus"'
  bin/roles > "$S/roles" 2>&1; grep -q '^builder  *gemini:gemini-2.5-pro' "$S/roles" || fail "a client that approved it: $(cat "$S/roles")"
  conf 'HUB_PROVIDERS_ALLOWED="anthropic gemini"' 'HUB_ROLE_BUILDER="gemini:gemini-2.5-pro anthropic:opus"'
  HUB_GEMINI_CLIENT_APPROVED=1 bin/roles > "$S/roles" 2>&1; grep -q '^builder  *anthropic:opus' "$S/roles" || fail "approval comes only from hub.conf, never the environment"
}
agent_read_only() {   # AC7
  reset; agent; assert_eq "$rc" 0 "agent: $(cat "$S/err") $(cat "$HUB"/.local/agent-out/*.err 2>/dev/null)"
  [ ! -e "$C/claude.runs" ] || fail "Claude Code ran"
  grep -q "^<<<AGENT-OUTPUT nonce=" "$S/out" && grep -q "report from the fake gemini" "$S/out" || fail "framed report: $(cat "$S/out")"
  grep -q "$TASK" "$C/stdin" || fail "the task comes on stdin"; grep -qF -- "$TASK" "$C/argv" && fail "the task is in argv"
  grep -qx -- -p "$C/argv" || fail "headless (-p)"; assert_eq "$(arg_after -e)" none "no extensions"
  assert_eq "$(arg_after -m)" gemini-2.5-pro "model"
  assert_eq "$(arg_after --approval-mode)" default "never auto-approved"
  grep -qx -- --skip-trust "$C/argv" || fail "headless needs a trusted folder: --skip-trust, after the workspace check"
  local P="$C/policy.toml" n
  grep -q 'toolName = "\*"' "$P" && grep -q 'denyMessage = "hub: a delegated run is read-only"' "$P" || fail "everything but reading is denied: $(cat "$P")"
  grep -q 'toolName = \["read_file", "read_many_files", "glob", "grep_search", "list_directory"\]' "$P" || fail "the read tools are the only ones allowed"
  for n in '\.env' 'pem' 'key' 'id_rsa' '\.ssh' '\.aws' '\.npmrc' '\.netrc' 'credentials' 'secrets'; do grep -q "argsPattern = .*$n" "$P" || fail "secret files denied: $n"; done
  assert_eq "$(cat "$C/cwd")" "$CK" "runs in the checkout"
  grep -q '^HUB_OWNED_BY_OWNER=\|^AGENT_RUN_' "$C/env" && fail "the environment is cleared"
  assert_eq "$(envval GEMINI_API_KEY)" "$KEY" "the key reaches gemini"
  no_secret_in "$C/argv" "$S/out" "$S/err" "$HUB"/journal/*.md
  grep -q 'provider=gemini model=gemini-2.5-pro exit=0' "$HUB"/journal/delegations-*.md || fail "journaled"
  # the checkout's own Gemini configuration is refused before anything runs: settings (a discovery command), hooks, .env
  local f; for f in settings.json hooks .env; do reset; owner 'HUB_ROLE_BUILDER="gemini:gemini-2.5-pro"'; mkdir -p "$CK/.gemini"
    case "$f" in settings.json) printf '{"tools":{"discoveryCommand":"touch %s/DISCOVERED; echo []"}}' "$S" > "$CK/.gemini/settings.json" ;; hooks) mkdir -p "$CK/.gemini/hooks" ;; *) echo X=1 > "$CK/.gemini/.env" ;; esac
    agent; assert_eq "$rc" 2 "agent with a checkout .gemini/$f"; ran && fail "gemini ran with .gemini/$f"
    WORK_DRY=1 bin/work --provider gemini --model gemini-2.5-pro projects/demo >/dev/null 2>&1; assert_eq "$?" 2 "work with a checkout .gemini/$f"
    (cd "$CK" && "$HUB/bin/gemini-run" --auth key --mode agent -m gemini-2.5-pro >/dev/null 2>&1); assert_eq "$?" 2 "gemini-run with .gemini/$f"
  done
  [ ! -e "$S/DISCOVERED" ] || fail "the discovery command ran"
}
sessions_and_dispatch() {   # AC8
  reset; printf 'sleep 30\n' > "$S/behave"
  L="$(WORK_NO_OPEN=1 bin/work --role builder projects/demo 2>/dev/null | sed -n 's/^launcher: //p')"; [ -x "$L" ] || fail "launcher"
  bash "$L" >/dev/null 2>&1 < /dev/null & lp=$!
  local i; for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -e "$C/runs" ] && break; sleep 0.25; done
  bin/sessions > "$S/sess"; pkill -P "$lp" 2>/dev/null; kill "$lp" 2>/dev/null; wait "$lp" 2>/dev/null
  head -1 "$S/sess" | grep -q 'ENGINE' || fail "ENGINE column: $(cat "$S/sess")"
  awk 'NR>1 && $1=="demo" {print $6, $NF}' "$S/sess" | grep -qx 'builder gemini' || fail "session shows its engine: $(cat "$S/sess")"
  reset; mkdir -p "$CK/_bmad"; : > "$CK/_bmad/ade-runtime.mjs"
  printf '#!/bin/bash\necho %s\n' "'{\"ready_to_start\":[{\"ref\":\"1.1\",\"risk\":\"low\"}],\"ready_to_refine\":[],\"in_progress\":[],\"blocked\":[]}'" > "$S/bin/node"; chmod +x "$S/bin/node"
  WORK_DRY=1 bin/dispatch projects/demo > "$S/out" 2> "$S/err"; assert_eq "$?" 0 "dispatch: $(cat "$S/err")"
  grep -q "^started: 1.1" "$S/out" || fail "dispatch started 1.1: $(cat "$S/out")"
  grep -q "/bin/gemini-run' --auth key --mode focus" "$S/out" || fail "a gemini builder: $(cat "$S/out")"
  rm -rf "$CK/_bmad" "$S/bin/node"
}
docs_record_gemini() {   # AC9
  local e="$REPO/.ade/context/engines.md" a="$REPO/.ade/context/decisions/0002-providers-and-engines.md"
  grep -q '^## Gemini CLI engine' "$e" || fail "engines.md has the Gemini section"
  for w in GEMINI_API_KEY disableYoloMode environmentVariableRedaction oauth-personal 'Unpaid Services' 'Gaps' 'owned by root' \
    'admin-policy' 'skip-trust' 'discoveryCommand' 'sandbox' 'GEMINI_CLI_HOME' '.env'; do grep -q -- "$w" "$e" || fail "engines.md: $w"; done
  grep -q 'Not written yet' "$a" && fail "ADR 0002 Engines section is written"
  grep -q 'Gemini' "$a" || fail "ADR 0002 names Gemini"
}

ALL="role_table_takes_gemini work_launches_gemini yolo_refused no_signin_refused key_only_in_gemini gemini_allowed_per_hub agent_read_only sessions_and_dispatch docs_record_gemini"
for t in ${@:-$ALL}; do "$t"; done
echo ok
