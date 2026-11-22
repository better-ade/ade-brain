#!/bin/bash
# Story SP: DeepSeek behind Claude Code (docs/stories/SP-providers.md). One function per acceptance check.
# bash tests/test_providers.sh [check ...] runs only the named checks (all of them by default).
# Hermetic: a fake `claude` and stub `osascript`, `security` and bin/secret sit first on PATH (or in the hub copy). The
# real claude, the real Keychain and any vendor are never reached. The stub key value must never appear in anything
# bin/work prints or writes, nor in the engine's argv or environment.
. "$(dirname "$0")/helpers.sh"
make_hub; cd "$HUB"
# never inherit the shell's Claude config dir: a launch without a CLAUDE_CONFIG_DIR prefix must land in $CLAUDE_HOME
unset CLAUDE_CONFIG_DIR HUB_CLAUDE_CONFIG_DIR
S="$(mktemp -d)"; mkdir -p "$S/tmp" "$S/home"; export TMPDIR="$S/tmp" HOME="$S/home"   # never the tester's HOME
# every temp dir this suite (and make_hub) made goes when it exits
trap 'rm -rf "$S" "$(dirname "$HUB")" "$CLAUDE_HOME" "$(dirname "$AGENT_SYNC_LOG")" "$(dirname "$AGENT_SYNC_LOCK")" "$(dirname "$METHOD_FIXTURE")"' EXIT
bin/new projects/demo >/dev/null
export SP_ROOT="$S" SP_CAP="$S/cap" SP_CALLS="$S/calls" SP_KEYFILE="$S/key" SP_STORED="$S/stored" SP_NONCE="fake-$$-$RANDOM"
KEY="sk-SPTEST-$RANDOM$RANDOM-c0ffee"; printf '%s' "$KEY" > "$SP_KEYFILE"; chmod 600 "$SP_KEYFILE"; : > "$SP_CALLS"
echo deepseek-api-key > "$SP_STORED"
# stub `security`: accounts listed in $SP_STORED exist; -w prints the stub key
cat > "$S/security" <<'STUB'
#!/bin/bash
op="$1"; shift; acct=""; w=0
while [ $# -gt 0 ]; do case "$1" in -a) acct="$2"; shift 2;; -w) w=1; shift;; *) shift;; esac; done
echo "security $op $acct" >> "$SP_CALLS"
case "$op" in find-generic-password) grep -qx "$acct" "$SP_STORED" || exit 44; [ "$w" = 1 ] && cat "$SP_KEYFILE"; exit 0;; esac
exit 1
STUB
# stub `osascript`: copies the launcher and the settings file it names, then runs the launcher synchronously
cat > "$S/osascript" <<'STUB'
#!/bin/bash
echo "osascript" >> "$SP_CALLS"
[ "${SP_OSA_FAIL:-}" = 1 ] && { echo "osascript stub: failing on purpose" >&2; exit 1; }
L=$(printf '%s\n' "$@" | grep -o 'bash -l [^"]*' | head -1); L="${L#bash -l }"
[ -f "$L" ] || { echo "osascript stub: no launcher in [$*]" >&2; exit 1; }
mkdir -p "$SP_CAP"; cp "$L" "$SP_CAP/launcher"
m=$(grep -o -- "--settings '[^']*'" "$L" | head -1 | sed "s/^--settings '//; s/'\$//")
[ -n "$m" ] && [ -f "$m" ] && { cp "$m" "$SP_CAP/settings.json"; python3 -c 'import os, sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$m" > "$SP_CAP/settings.mode"; echo "$m" > "$SP_CAP/settings.path"; }
bash "$L" > "$SP_CAP/launcher.out" 2>&1
STUB
# the fake engine: writes a marker, its argv, whether its environment holds the key, and a /model-style settings write
cat > "$S/claude" <<'STUB'
#!/bin/bash
[ "${1:-}" = --version ] && { echo "fake claude"; exit 0; }
mkdir -p "$SP_CAP"; echo "FAKE-CLAUDE $SP_NONCE" > "$SP_CAP/marker"
printf '%s\n' "$@" > "$SP_CAP/argv"
if env | grep -qF -- "$(cat "$SP_KEYFILE")"; then echo yes; else echo no; fi > "$SP_CAP/env-has-key"
env | sed 's/=.*//' | sort > "$SP_CAP/env-names"
echo "${CLAUDE_CONFIG_DIR:-}" > "$SP_CAP/config-dir"
d="${CLAUDE_CONFIG_DIR:-$CLAUDE_HOME}"
case "$d" in "$HUB"/*|"$CLAUDE_HOME"|"$SP_ROOT"/*) mkdir -p "$d"; printf '{"model":"deepseek-v4-pro"}\n' > "$d/settings.json" ;;
  *) echo "$d" > "$SP_CAP/outside-write" ;; esac   # never write outside the test's temp dirs
STUB
# stub bin/secret (installed into the hub copy): counts its calls; SP_SECRET_MODE=fail exits 1, =empty prints nothing
cat > "$S/secret" <<'STUB'
#!/bin/bash
echo "secret $*" >> "$SP_CALLS"; echo "hub=${HUB:-} svc=${AGENT_KEYCHAIN_SERVICE:-}" >> "$SP_ROOT/secret-env"
case "$1" in --has) grep -qx "$2" "$SP_STORED"; exit;; esac
case "${SP_SECRET_MODE:-ok}" in fail) echo "secret: $1 not stored" >&2; exit 1;; empty) exit 0;; esac
cat "$SP_KEYFILE"
STUB
chmod +x "$S/security" "$S/osascript" "$S/claude" "$S/secret"
cp bin/secret "$S/secret.real"; cp "$S/secret" bin/secret
export PATH="$S:$PATH" AGENT_CLAUDE=claude
cp bin/lib.sh "$S/lib.sh.orig"
DS_URL="https://api.deepseek.com/anthropic"

conf() { printf '%s\n' "$@" > hub.conf; }
allow() { conf 'HUB_PROVIDERS_ALLOWED="anthropic deepseek"' 'HUB_OWNED_BY_OWNER=1' "$@"; }   # an owner's own hub
client() { conf 'HUB_PROVIDERS_ALLOWED="anthropic deepseek"' "$@"; }                         # a client hub
no_key_in() { local f; for f in "$@"; do [ ! -e "$f" ] || ! grep -qF -- "$KEY" "$f" || fail "the key value is in $f"; done; }
settings_of() { printf '%s\n' "$1" | grep -o -- "--settings '[^']*'" | head -1 | sed "s/^--settings '//; s/'\$//"; }
jget() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."): d = d.get(k, "<absent>") if isinstance(d, dict) else "<absent>"
print(json.dumps(d) if not isinstance(d, str) else d)' "$1" "$2"; }
agents_json() { eval "$(printf '%s\n' "$1" | head -1 | sed -E 's/^.* --agents /printf %s /; s/ --(permission-mode|model|effort) [^ ]*//g; s/ -- .*$//')"; }
calls() { grep -c "^$1" "$SP_CALLS"; }
dry() { WORK_DRY=1 bin/work "$@"; }
# a provider dry run prints the command, then the merged settings JSON (no file is kept): the JSON, as a file to read
dry_settings() { printf '%s\n' "$1" | sed 1d > "$S/dry.json"; echo "$S/dry.json"; }
# launch [bin/work args]: a non-dry run through the stubs; sets rc, output in $SP_CAP/work.out
launch() {
  [ "$(command -v osascript)" = "$S/osascript" ] || fail "osascript is not the stub"
  [ "$(command -v claude)" = "$S/claude" ] || fail "claude is not the fake"
  rm -rf "$SP_CAP"; mkdir -p "$SP_CAP"; : > "$SP_CALLS"
  bin/work "$@" > "$S/work.out" 2>&1; rc=$?; cp "$S/work.out" "$SP_CAP/work.out"
  [ ! -e "$SP_CAP/outside-write" ] || fail "the engine's config dir is outside the test: $(cat "$SP_CAP/outside-write")"
  if [ -e "$SP_CAP/marker" ]; then assert_eq "$(cat "$SP_CAP/marker")" "FAKE-CLAUDE $SP_NONCE" "the engine that ran is the fake"; fi
  no_key_in "$SP_CAP"/*
}
fake_ran() { [ -e "$SP_CAP/marker" ]; }
with_lib_edit() {  # <sed delete pattern> <cmd...>: run cmd against a hub whose lib.sh has that go line removed
  local pat="$1"; shift
  grep -q "$pat" bin/lib.sh || fail "lib.sh has no line matching [$pat] to edit"
  sed "/$pat/d" "$S/lib.sh.orig" > bin/lib.sh
  "$@"; local r=$?; cp "$S/lib.sh.orig" bin/lib.sh; return $r
}
agent() {  # <folder> <file> <front matter lines...>
  local f="$1" n="$2"; shift 2; mkdir -p "$f/.claude/agents"
  { echo ---; printf '%s\n' "$@"; echo ---; echo "You help."; } > "$f/.claude/agents/$n.md"
}

# AC1
provider_rows_static() {
  . bin/lib.sh; local ids p u tbl
  ids="$(providers)"; [ -n "$ids" ] || fail "no provider rows"
  tbl=$(grep -oE '^ *[a-z0-9-]+:base_url\)' bin/lib.sh | sed -E 's/^ *//; s/:base_url\)//' | sort | tr '\n' ' ')
  assert_eq "$tbl" "$(printf '%s\n' $ids | sort | tr '\n' ' ')" "providers lists every table row"
  for p in deepseek glm; do printf '%s\n' $ids | grep -qx "$p" || fail "no $p row"; done
  for p in $ids; do
    u="$(provider_field "$p" base_url)"
    [[ "$u" == https://* ]] || fail "$p base URL is not https: $u"
    [[ "$u" != */ ]] || fail "$p base URL ends in /"
    [[ "$u" != */v1 ]] || fail "$p base URL ends in /v1"
    [ -n "$(provider_field "$p" secret)" ] || fail "$p has no Keychain secret name"
    [ -n "$(provider_field "$p" label)" ] || fail "$p has no doctor label"
  done
  assert_eq "$(provider_field deepseek base_url)" "$DS_URL" "deepseek base URL"
  assert_eq "$(provider_field deepseek secret)" "deepseek-api-key" "deepseek secret name"
  assert_eq "$(provider_field glm base_url)" "https://api.z.ai/api/anthropic" "glm base URL"
  assert_eq "$(provider_field glm secret)" "zai-api-key" "glm secret name"
}
# AC2
dry_run_deepseek() {
  allow; : > "$SP_CALLS"
  local out m; out=$(dry --provider deepseek projects/demo 2>&1) || fail "dry run failed: $out"
  echo "$out" | grep -qF "AGENT_FOLDER='projects/demo' CLAUDE_CONFIG_DIR='$HUB/.local/providers/deepseek' claude --settings '" || fail "config dir prefix: $out"
  echo "$out" | grep -q -- "--remote-control" && fail "remote control in a provider session"
  m="$(settings_of "$out")"; [ "$m" != "$HUB/projects/demo/.claude/settings.json" ] || fail "the folder's own settings were passed"
  [ ! -e "$m" ] || fail "a dry run kept the merged settings file: $m"
  m="$(dry_settings "$out")"
  assert_eq "$(jget "$m" env.ANTHROPIC_BASE_URL)" "$DS_URL" "base URL"
  assert_eq "$(jget "$m" env.ANTHROPIC_MODEL)" "deepseek-flash" "main model"
  assert_eq "$(jget "$m" env.ANTHROPIC_DEFAULT_OPUS_MODEL)" "deepseek-v4-pro" "opus slot"
  assert_eq "$(jget "$m" env.ANTHROPIC_DEFAULT_SONNET_MODEL)" "deepseek-flash" "sonnet slot"
  assert_eq "$(jget "$m" env.ANTHROPIC_DEFAULT_HAIKU_MODEL)" "deepseek-flash" "haiku slot"
  assert_eq "$(jget "$m" env.ANTHROPIC_SMALL_FAST_MODEL)" "deepseek-flash" "small-fast slot"
  assert_eq "$(jget "$m" env.CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC)" "1" "nonessential traffic off"
  grep -q CLAUDE_CODE_SUBAGENT_MODEL "$m" && fail "subagent model set"
  printf '%s' "$out" | grep -qF -- "$KEY" && fail "the key is in the dry-run output"
  no_key_in "$m"
  assert_eq "$(calls secret)" "0" "a dry run never reads the key"
  launch --provider deepseek projects/demo; assert_eq "$rc" "0" "launch exit"
  assert_eq "$(cat "$SP_CAP/settings.mode")" "600" "merged settings file mode"
}
# AC3, AC30
launcher_file_holds_no_key() {
  allow; launch --provider deepseek projects/demo
  assert_eq "$rc" "0" "launch exit ($(cat "$SP_CAP/work.out"))"
  [ -s "$SP_CAP/launcher" ] && [ -s "$SP_CAP/settings.json" ] || fail "launcher and settings not captured"
  no_key_in "$SP_CAP/launcher" "$SP_CAP/settings.json" "$SP_CAP/work.out"
  grep -qE 'ANTHROPIC_(AUTH_TOKEN|API_KEY)=' "$SP_CAP/launcher" "$SP_CAP/settings.json" && fail "an auth variable is set"
  grep -qE '"ANTHROPIC_(AUTH_TOKEN|API_KEY)"' "$SP_CAP/settings.json" && fail "an auth variable is in the env block"
  assert_eq "$(cat "$SP_CAP/env-has-key")" "no" "the engine's environment holds no key"
  grep -qxE 'ANTHROPIC_(AUTH_TOKEN|API_KEY)' "$SP_CAP/env-names" && fail "the engine got an auth variable"
  fake_ran || fail "the fake engine did not run"
}
# AC4, AC30
engine_argv_holds_no_key() {
  allow; launch --provider deepseek projects/demo
  [ -s "$SP_CAP/argv" ] || fail "no argv captured"
  no_key_in "$SP_CAP/argv"; grep -qx -- "--settings" "$SP_CAP/argv" || fail "argv has no --settings"
}
# AC5
fail_closed_on_missing_key() {
  allow; SP_SECRET_MODE=fail launch --provider deepseek projects/demo
  assert_eq "$rc" "1" "missing key exit"; assert_contains "$SP_CAP/work.out" "bin/secret --set deepseek-api-key" "hint"
  fake_ran && fail "the engine started without a key"; assert_eq "$(calls osascript)" "0" "no terminal opened"
}
fail_closed_on_empty_key() {
  allow; SP_SECRET_MODE=empty launch --provider deepseek projects/demo
  assert_eq "$rc" "1" "empty key exit"; assert_contains "$SP_CAP/work.out" "bin/secret --set deepseek-api-key" "hint"
  fake_ran && fail "the engine started with an empty key"; assert_eq "$(calls osascript)" "0" "no terminal opened"
}
# AC6, AC30
key_checked_once_before_launch() {
  allow; launch --provider deepseek projects/demo; assert_eq "$rc" "0" "launch exit"
  assert_eq "$(calls secret)" "1" "bin/secret calls"
  assert_eq "$(grep '^secret' "$SP_CALLS")" "secret deepseek-api-key" "bin/secret reads the deepseek key"
  assert_eq "$(grep -E '^(secret|osascript)' "$SP_CALLS" | awk '{print $1}' | tr '\n' ' ')" "secret osascript " "key read before the launch"
}
single_merged_settings_keeps_hooks() {
  allow; launch --provider deepseek projects/demo; assert_eq "$rc" "0" "launch exit"
  assert_eq "$(jget "$SP_CAP/settings.json" apiKeyHelper)" "HUB='$HUB' AGENT_KEYCHAIN_SERVICE='hub' '$HUB/bin/secret' deepseek-api-key" "apiKeyHelper"
  python3 -c 'import json,sys; a=json.load(open(sys.argv[1])); b=json.load(open(sys.argv[2]))
assert a.get("hooks") and a["hooks"] == b["hooks"], "hooks differ"' "$SP_CAP/settings.json" projects/demo/.claude/settings.json || fail "merged settings lost the folder hooks"
  assert_eq "$(grep -cx -- "--settings" "$SP_CAP/argv")" "1" "one --settings"
}
# AC7 (skip)
checkout_base_url_conflict_refused() {
  grep -q 'The `env` block of the `--settings` layer \*\*wins\*\*' "$REPO/.ade/context/engines.md" || fail "engines.md no longer records that the provider layer wins"
  echo "SKIP AC7 checkout_base_url_conflict_refused: S0 item 21: the provider layer's env wins over checkout and user settings (engines.md, Settings precedence)"
}
# AC8
provider_implies_no_remote() {
  allow; local out; out=$(dry --provider deepseek projects/demo) || fail "dry run"
  echo "$out" | grep -q -- "--remote-control" && fail "--provider leaves remote control on"
  dry projects/demo | grep -q -- "--remote-control demo" || fail "anthropic keeps remote control"
}
# AC9
provider_rejects_wrapper_from_each_source() {
  allow; local out
  out=$(dry --provider deepseek --claude mywrap projects/demo 2>&1); assert_eq "$?" "2" "--claude wrapper"
  echo "$out" | grep -q "plain claude" || fail "wrapper refusal names the rule: $out"
  dry --provider deepseek --claude /opt/bin/claude projects/demo >/dev/null 2>&1; assert_eq "$?" "2" "a claude path is not plain claude"
  allow 'HUB_CLAUDE=mywrap'
  env -u AGENT_CLAUDE WORK_DRY=1 bin/work --provider deepseek projects/demo >/dev/null 2>&1; assert_eq "$?" "2" "HUB_CLAUDE wrapper"
  allow; AGENT_CLAUDE=mywrap WORK_DRY=1 bin/work --provider deepseek projects/demo >/dev/null 2>&1; assert_eq "$?" "2" "AGENT_CLAUDE wrapper"
  dry --provider deepseek --claude claude projects/demo >/dev/null || fail "--claude claude accepted"
  allow 'HUB_CLAUDE=claude'
  env -u AGENT_CLAUDE WORK_DRY=1 bin/work --provider deepseek projects/demo >/dev/null || fail "HUB_CLAUDE=claude accepted"
  allow; AGENT_CLAUDE=claude WORK_DRY=1 bin/work --provider deepseek projects/demo >/dev/null || fail "AGENT_CLAUDE=claude accepted"
}
# AC10
provider_model_rules() {
  allow; local out
  out=$(dry --provider deepseek --model sonnet projects/demo) || fail "slot alias refused"
  echo "$out" | grep -q -- " --model sonnet" || fail "--model sonnet passed"
  dry --provider deepseek --model deepseek-v4-pro projects/demo | grep -q -- " --model deepseek-v4-pro" || fail "row id refused"
  out=$(dry --provider deepseek --model claude-sonnet-4-5 projects/demo 2>&1); assert_eq "$?" "2" "Anthropic id refused"
  echo "$out" | grep -q "deepseek" || fail "refusal names the provider: $out"
  bin/new projects/agbad >/dev/null; agent projects/agbad x 'name: x' 'description: d' 'model: claude-sonnet-4-5'
  dry --provider deepseek projects/agbad >/dev/null 2>&1; assert_eq "$?" "2" "agent with an Anthropic model id"
  bin/new projects/aginh >/dev/null; agent projects/aginh y 'name: y' 'description: d' 'model: inherit'
  dry --provider deepseek projects/aginh >/dev/null || fail "agent with model: inherit"
  dry --provider deepseek projects/aginh --agent-model claude-opus-4 >/dev/null 2>&1; assert_eq "$?" "2" "--agent-model Anthropic id"
  dry --provider deepseek projects/aginh --agent-model haiku >/dev/null || fail "--agent-model slot alias"
}
hub_model_not_passed() {
  allow 'HUB_MODEL=claude-sonnet-4-5' 'HUB_AGENT_MODEL=sonnet'
  bin/new projects/hm >/dev/null; agent projects/hm z 'name: z' 'description: d'
  local out; out=$(dry --provider deepseek projects/hm) || fail "HUB_MODEL broke a provider session"
  echo "$out" | grep -q -- " --model" && fail "HUB_MODEL passed: $out"
  assert_eq "$(agents_json "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["z"].get("model",""))')" "" "HUB_AGENT_MODEL not passed"
  dry projects/hm | grep -q -- " --model claude-sonnet-4-5" || fail "anthropic sessions still get HUB_MODEL"
}
# AC11
provider_effort_accepted() {
  allow; dry --provider deepseek --effort high projects/demo | grep -q -- " --effort high" || fail "--effort high with deepseek"
}
provider_effort_refused() {
  allow; local out
  out=$(with_lib_edit 'deepseek:effort)' env WORK_DRY=1 bin/work --provider deepseek --effort high projects/demo 2>&1); assert_eq "$?" "2" "--effort with a no-go"
  echo "$out" | grep -q "S0 item 21" || fail "effort refusal names S0: $out"
  allow 'HUB_EFFORT=high'
  with_lib_edit 'deepseek:effort)' env WORK_DRY=1 bin/work --provider deepseek projects/demo >/dev/null 2>&1; assert_eq "$?" "2" "HUB_EFFORT with a no-go"
  allow; bin/new projects/eff >/dev/null; agent projects/eff e 'name: e' 'description: d'
  with_lib_edit 'deepseek:effort)' env WORK_DRY=1 bin/work --provider deepseek projects/eff --agent-effort high >/dev/null 2>&1; assert_eq "$?" "2" "--agent-effort with a no-go"
  dry --provider deepseek projects/demo >/dev/null || fail "lib.sh restored"
}
# AC12
hub_provider_model_override() {
  allow 'HUB_DEEPSEEK_MODEL=deepseek-v4-pro' 'HUB_DEEPSEEK_SMALL_MODEL=deepseek-flash'
  local m; m="$(dry_settings "$(dry --provider deepseek projects/demo)")"
  assert_eq "$(jget "$m" env.ANTHROPIC_MODEL)" "deepseek-v4-pro" "HUB_DEEPSEEK_MODEL"
  assert_eq "$(jget "$m" env.ANTHROPIC_SMALL_FAST_MODEL)" "deepseek-flash" "HUB_DEEPSEEK_SMALL_MODEL"
  allow 'HUB_DEEPSEEK_SMALL_MODEL=opus'
  m="$(dry_settings "$(dry --provider deepseek projects/demo)")"
  assert_eq "$(jget "$m" env.ANTHROPIC_SMALL_FAST_MODEL)" "deepseek-v4-pro" "a slot alias resolves through the row"
}
hub_provider_model_checked() {
  local out
  allow 'HUB_DEEPSEEK_MODEL=deepseek-v4-flash'
  out=$(dry --provider deepseek projects/demo 2>&1); assert_eq "$?" "2" "stale HUB_DEEPSEEK_MODEL"
  echo "$out" | grep -q HUB_DEEPSEEK_MODEL || fail "refusal names the setting: $out"
  allow 'HUB_DEEPSEEK_SMALL_MODEL=claude-haiku-4-5'
  dry --provider deepseek projects/demo >/dev/null 2>&1; assert_eq "$?" "2" "stale HUB_DEEPSEEK_SMALL_MODEL"
}
# AC13
no_base_url_override() {
  allow 'HUB_DEEPSEEK_BASE_URL=https://conf.example.invalid'
  local m; m="$(dry_settings "$(HUB_DEEPSEEK_BASE_URL=https://env.example.invalid WORK_DRY=1 bin/work --provider deepseek projects/demo)")"
  assert_eq "$(jget "$m" env.ANTHROPIC_BASE_URL)" "$DS_URL" "base URL comes only from the table"
  grep -q "example.invalid" "$m" && fail "an override reached the settings file"
  grep -q "BASE_URL" bin/work && grep -q 'HUB_.*BASE_URL' bin/work && fail "bin/work reads a HUB_*_BASE_URL"
  return 0
}
# AC14
provider_env_not_trusted() {
  rm -f hub.conf; local plain out
  plain=$(dry projects/demo)
  out=$(HUB_PROVIDER=deepseek HUB_PROVIDERS_ALLOWED="anthropic deepseek" WORK_DRY=1 bin/work projects/demo 2>&1) || fail "env provider broke the default run: $out"
  assert_eq "$out" "$plain" "HUB_PROVIDER from the environment is ignored"
  HUB_PROVIDERS_ALLOWED="anthropic deepseek" WORK_DRY=1 bin/work --provider deepseek projects/demo >/dev/null 2>&1; assert_eq "$?" "2" "HUB_PROVIDERS_ALLOWED from the environment is ignored"
  allow 'HUB_PROVIDER=deepseek'
  dry projects/demo | grep -qF "CLAUDE_CONFIG_DIR='$HUB/.local/providers/deepseek'" || fail "HUB_PROVIDER in hub.conf picks the session provider"
  dry --provider anthropic projects/demo | grep -q CLAUDE_CONFIG_DIR && fail "--provider anthropic overrides hub.conf"
  return 0
}
provider_not_allowed() {
  local out
  rm -f hub.conf; out=$(dry --provider deepseek projects/demo 2>&1); assert_eq "$?" "2" "allowed list unset"
  echo "$out" | grep -q HUB_PROVIDERS_ALLOWED || fail "refusal names HUB_PROVIDERS_ALLOWED: $out"
  conf 'HUB_PROVIDERS_ALLOWED=anthropic'; dry --provider deepseek projects/demo >/dev/null 2>&1; assert_eq "$?" "2" "anthropic only"
  conf 'HUB_PROVIDERS_ALLOWED="anthropic meta"'; dry --provider meta projects/demo >/dev/null 2>&1; assert_eq "$?" "2" "a provider with no row"
}
# AC15
no_go_pair_refused_by_work() {
  conf 'HUB_PROVIDERS_ALLOWED="anthropic deepseek glm"' 'HUB_OWNED_BY_OWNER=1'; local out
  out=$(dry --provider glm projects/demo 2>&1); assert_eq "$?" "2" "glm refused"
  echo "$out" | grep -q "S0 item 21" || fail "glm refusal names S0 item 21: $out"
  out=$(with_lib_edit 'deepseek:focus)' env WORK_DRY=1 bin/work --provider deepseek projects/demo 2>&1); assert_eq "$?" "2" "deepseek focus no-go"
  echo "$out" | grep -q "S0 item 21" || fail "deepseek refusal names S0 item 21: $out"
  launch --provider glm projects/demo; assert_eq "$rc" "2" "glm launch refused"
  assert_eq "$(calls secret)" "0" "a refused provider never reads a key"; fake_ran && fail "glm engine ran"
  return 0
}
# AC16
agents_provider_check() {
  allow; bin/new projects/three >/dev/null
  agent projects/three none 'name: plain' 'description: d'
  agent projects/three same 'name: same' 'description: d' 'provider: deepseek'
  agent projects/three other 'name: other' 'description: d' 'provider: glm'
  local out; out=$(dry --provider deepseek projects/three 2>"$S/err") || fail "agents run: $(cat "$S/err")"
  assert_eq "$(agents_json "$out" | python3 -c 'import json,sys; print(" ".join(sorted(json.load(sys.stdin))))')" "plain same" "agents kept"
  assert_contains "$S/err" "work: delegatable (not in --agents): other (provider glm)" "left-out agent named"
  agents_json "$out" | grep -q provider && fail "provider: leaked into the agents JSON"
  return 0
}
# AC17
doctor_provider_rows_name_only() {
  allow; cp "$S/secret.real" bin/secret; local out
  out=$(DOCTOR_OFFLINE=1 bin/doctor); cp "$S/secret" bin/secret
  echo "$out" | grep -qE "^OK +DeepSeek API key +deepseek-api-key" || fail "deepseek OK row: $out"
  echo "$out" | grep -qiE "z\.ai|zai-api-key|glm" && fail "a row for a provider that is not allowed"
  printf '%s' "$out" | grep -qF -- "$KEY" && fail "doctor printed the key"
  : > "$SP_STORED"; cp "$S/secret.real" bin/secret
  out=$(DOCTOR_OFFLINE=1 bin/doctor); cp "$S/secret" bin/secret; echo deepseek-api-key > "$SP_STORED"
  echo "$out" | grep -qE "^MISSING +DeepSeek API key +deepseek-api-key" || fail "deepseek MISSING row: $out"
  rm -f hub.conf; DOCTOR_OFFLINE=1 bin/doctor | grep -q "DeepSeek" && fail "no row when only anthropic is allowed"
  return 0
}
readme_section() { awk '/^## /{p=($0=="## Providers behind Claude Code")} p' README.md; }
# AC18
meta_row_only_with_a_go() {
  . bin/lib.sh; providers | grep -qx meta && fail "meta row in the table"
  grep -qE '^ *meta:' bin/lib.sh && fail "meta case in lib.sh"
  [ -n "$(readme_section)" ] || fail "README has no provider section"
  readme_section | grep -i meta | grep -v "not offered" | grep -q . && fail "README offers meta"
  return 0
}
# AC19 (skip)
allowed_tools_applied() {
  grep -qF "Tool restriction (AC19): none needed for DeepSeek." "$REPO/.ade/context/engines.md" || fail "engines.md lost the tool restriction finding"
  echo "SKIP AC19 allowed_tools_applied: none needed for DeepSeek (engines.md, Tool restriction)"
}
# AC20
readme_provider_section() {
  local s; s="$(readme_section)"; [ -n "$s" ] || fail "README has no provider section"
  local w; for w in "--provider" "HUB_PROVIDERS_ALLOWED" "bin/secret --set deepseek-api-key" "Remote Control is off" \
    "plain \`claude\`" "Data sharing" "never in the environment, argv or a file" "GLM is disabled" "Meta is not offered"; do
    printf '%s\n' "$s" | grep -qF -- "$w" || fail "README provider section lacks [$w]"
  done
}
# AC21
adr_0002_provider_section() {
  local a; a=$(ls "$REPO"/.ade/context/decisions/0002-*.md 2>/dev/null); [ "$(echo "$a" | grep -c .)" = 1 ] || fail "exactly one ADR 0002: [$a]"
  sec() { awk -v h="$1" '/^#+ /{p=($0==h)} p' "$a"; }
  [ -n "$(sec "## Providers (story SP)")" ] || fail "ADR 0002 has no provider section"
  sec "### Credential option" | grep -q "option 1" || fail "credential option 1"
  sec "### Credential option" | grep -q "apiKeyHelper" || fail "credential option names the helper"
  sec "### Credential option" | grep -q "CLAUDE_CODE_SUBPROCESS_ENV_SCRUB" || fail "credential option names the scrub variable"
  sec "### Data sharing per hub" | grep -q "HUB_OWNED_BY_OWNER=1" || fail "data sharing records the owner rule"
  sec "### Data sharing per hub" | grep -q "2026-11-09" || fail "data sharing rule is dated"
  sec "### Vendor API terms" | grep -q "Terms of Use §4.3" || fail "DeepSeek terms cite ToU §4.3"
  sec "### Vendor API terms" | grep -q "https://cdn.deepseek.com/policies/en-US/deepseek-terms-of-use.html" || fail "DeepSeek terms URL"
  sec "### Vendor API terms" | grep -q "People's Republic of China" || fail "DeepSeek storage location"
}
# AC23
hermetic_fake_engine_only() {
  assert_eq "$(command -v claude)" "$S/claude" "claude on PATH is the fake"
  assert_eq "$AGENT_CLAUDE" "claude" "AGENT_CLAUDE"
  allow; launch --provider deepseek projects/demo; fake_ran || fail "the fake engine did not run"
  assert_eq "$(cat "$SP_CAP/marker")" "FAKE-CLAUDE $SP_NONCE" "marker written by the fake"
}
# AC25
provider_config_dir_isolated() {
  allow; printf '{"model":"opus"}\n' > "$CLAUDE_HOME/settings.json"
  launch --provider deepseek projects/demo; assert_eq "$rc" "0" "launch exit"
  assert_eq "$(cat "$SP_CAP/config-dir")" "$HUB/.local/providers/deepseek" "the engine's CLAUDE_CONFIG_DIR"
  assert_eq "$(cat "$CLAUDE_HOME/settings.json")" '{"model":"opus"}' "the owner's settings.json is unchanged"
  assert_contains "$HUB/.local/providers/deepseek/settings.json" '"model":"deepseek-v4-pro"' "/model wrote to the provider dir"
  rm -f "$CLAUDE_HOME/settings.json"
}
# AC26
provider_memory_linked() {
  allow; launch --provider deepseek projects/demo; assert_eq "$rc" "0" "launch exit"
  local P="$HUB/.local/providers/deepseek/projects"
  assert_eq "$(readlink "$P/$(encode_path "$HUB")/memory")" "$HUB/memory" "hub memory link"
  assert_eq "$(readlink "$P/$(encode_path "$HUB/projects/demo")/memory")" "$HUB/projects/demo/memory" "folder memory link"
  local R; R="$(mktemp -d "$S/tmp/rc.XXXXXX")/rc"; mkdir -p "$R"; bin/new projects/withrepo >/dev/null
  printf '| rc | %s | main | Owner | none |\n' "$R" >> projects/withrepo/ACCESS.md
  launch --provider deepseek projects/withrepo; assert_eq "$rc" "0" "repo launch exit"
  assert_eq "$(readlink "$P/$(encode_path "$R")/memory")" "$HUB/projects/withrepo/memory" "checkout memory link"
  launch --provider deepseek projects/demo; assert_eq "$rc" "0" "a second launch keeps the links"
}
# AC27
provider_resume_refused() {
  allow; local f
  for f in --resume --continue -r -c; do
    launch --provider deepseek projects/demo "$f"; assert_eq "$rc" "2" "$f exit"
    assert_contains "$SP_CAP/work.out" "does not resume" "$f names the rule"
    assert_eq "$(calls secret)" "0" "$f: no key read"; fake_ran && fail "$f: the engine ran"
  done
  launch --provider deepseek --resume projects/demo; assert_eq "$rc" "2" "--resume before the folder"
  return 0
}
# AC28
provider_layer_flags() {
  allow; bin/new projects/flags >/dev/null
  python3 -c 'import json,sys; p=sys.argv[1]; s=json.load(open(p)); s["env"]={"CLAUDE_CODE_SUBAGENT_MODEL":"x","ANTHROPIC_BASE_URL":"https://other.invalid","KEEP":"1"}; json.dump(s,open(p,"w"))' projects/flags/.claude/settings.json
  local out m; out=$(dry --provider deepseek projects/flags) || fail "dry run"; m="$(dry_settings "$out")"
  assert_eq "$(jget "$m" skipWebFetchPreflight)" "true" "skipWebFetchPreflight"
  assert_eq "$(jget "$m" env.CLAUDE_CODE_SUBPROCESS_ENV_SCRUB)" "1" "subprocess env scrub"
  assert_eq "$(jget "$m" env.ANTHROPIC_BASE_URL)" "$DS_URL" "provider env wins over the folder env"
  assert_eq "$(jget "$m" env.KEEP)" "1" "other folder env kept"
  grep -q CLAUDE_CODE_SUBAGENT_MODEL "$m" && fail "subagent model in the settings file"
  echo "$out" | grep -q CLAUDE_CODE_SUBAGENT_MODEL && fail "subagent model in the command"
  return 0
}
# AC29
anthropic_path_unchanged() {
  local a b; for c in "" 'HUB_PROVIDERS_ALLOWED="anthropic deepseek"'; do
    if [ -n "$c" ]; then conf "$c"; else rm -f hub.conf; fi
    a=$(dry --provider anthropic projects/demo) || fail "--provider anthropic"; b=$(dry projects/demo)
    assert_eq "$a" "$b" "--provider anthropic is the default command"
    echo "$a" | grep -q CLAUDE_CONFIG_DIR && fail "anthropic has a config dir prefix"
    echo "$a" | grep -qF -- "--settings '$HUB/projects/demo/.claude/settings.json'" || fail "anthropic uses the folder settings"
  done
  launch projects/demo; assert_eq "$rc" "0" "anthropic launch"; assert_eq "$(calls secret)" "0" "anthropic reads no key"
  grep -q "^trap 'rm -f \"\$0\" \"\$R\"' EXIT$" "$SP_CAP/launcher" || fail "anthropic launcher trap unchanged (itself and its session record)"
}

# AC31: owner rule (2026-11-09): DeepSeek only in the owner's own hubs; a client hub refuses it even when allowed
deepseek_client_hub_refused() {
  client; local out
  out=$(dry --provider deepseek projects/demo 2>&1); assert_eq "$?" "2" "client hub refuses deepseek"
  echo "$out" | grep -q "HUB_OWNED_BY_OWNER" || fail "refusal names HUB_OWNED_BY_OWNER: $out"
  echo "$out" | grep -q "ADR 0002" || fail "refusal names ADR 0002: $out"
  echo "$out" | grep -qi "training" && echo "$out" | grep -q "China" || fail "refusal gives the reason: $out"
  client 'HUB_PROVIDER=deepseek'; dry projects/demo >/dev/null 2>&1; assert_eq "$?" "2" "client hub with HUB_PROVIDER=deepseek"
  client 'HUB_OWNED_BY_OWNER=0'; dry --provider deepseek projects/demo >/dev/null 2>&1; assert_eq "$?" "2" "HUB_OWNED_BY_OWNER=0 is a client hub"
  client; launch --provider deepseek projects/demo; assert_eq "$rc" "2" "client launch refused"
  assert_eq "$(calls secret)" "0" "a client hub never reads the deepseek key"; fake_ran && fail "client hub engine ran"
  client; dry projects/demo >/dev/null || fail "anthropic sessions still run in a client hub"
}
# AC32
deepseek_owned_hub_allowed() {
  allow; dry --provider deepseek projects/demo >/dev/null || fail "owned hub allows deepseek"
  allow 'HUB_PROVIDER=deepseek'; dry projects/demo | grep -qF "CLAUDE_CONFIG_DIR='$HUB/.local/providers/deepseek'" || fail "owned hub HUB_PROVIDER=deepseek"
}
# AC33
owned_by_owner_env_not_trusted() {
  client; local out
  out=$(HUB_OWNED_BY_OWNER=1 WORK_DRY=1 bin/work --provider deepseek projects/demo 2>&1); assert_eq "$?" "2" "env HUB_OWNED_BY_OWNER ignored"
  echo "$out" | grep -q "HUB_OWNED_BY_OWNER" || fail "env refusal names the rule: $out"
  out=$(HUB_OWNED_BY_OWNER=1 DOCTOR_OFFLINE=1 bin/doctor); echo "$out" | grep -qE "^MISSING +client hub" || fail "doctor ignores env HUB_OWNED_BY_OWNER: $out"
}
# AC34
doctor_flags_client_hub_deepseek() {
  local out; client; out=$(DOCTOR_OFFLINE=1 bin/doctor)
  echo "$out" | grep -qE "^MISSING +client hub +.*deepseek.*HUB_OWNED_BY_OWNER" || fail "doctor flags a client hub listing deepseek: $out"
  allow; DOCTOR_OFFLINE=1 bin/doctor | grep -q "client hub" && fail "owned hub flagged"
  rm -f hub.conf; DOCTOR_OFFLINE=1 bin/doctor | grep -q "client hub" && fail "a hub without deepseek flagged"
  return 0
}

# B1: an Anthropic credential or a provider switch beats apiKeyHelper; none may reach a provider session
SCRUB="ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY ANTHROPIC_CUSTOM_HEADERS CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY CLAUDE_CODE_OAUTH_TOKEN"
plant_value() { case "$1" in CLAUDE_CODE_USE_*) echo 1 ;; *) echo "sk-ant-FAKE-PLANT-$1" ;; esac; }
# a folder whose code lives in a separate (clean) checkout, so its own settings are only merged, never loaded as project settings
repo_folder() {  # <folder>
  local R; R="$(mktemp -d "$S/tmp/co.XXXXXX")/co"; mkdir -p "$R"; bin/new "$1" >/dev/null
  printf '| co | %s | main | Owner | none |\n' "$R" >> "$1/ACCESS.md"; echo "$R"
}
set_env_block() {  # <settings file> <KEY=VALUE...>: writes (or adds) an env block
  local f="$1"; shift; mkdir -p "$(dirname "$f")"
  python3 -c 'import json,os,sys; p=sys.argv[1]; s=json.load(open(p)) if os.path.exists(p) else {}
s.setdefault("env", {}).update(dict(a.split("=",1) for a in sys.argv[2:])); json.dump(s, open(p,"w"))' "$f" "$@"
}
# AC35
provider_env_creds_scrubbed() {
  allow; local v envs=""
  for v in $SCRUB; do envs="$envs $v=$(plant_value "$v")"; done
  rm -rf "$SP_CAP"; mkdir -p "$SP_CAP"; : > "$SP_CALLS"
  env $envs bin/work --provider deepseek projects/demo > "$S/work.out" 2>&1; rc=$?
  assert_eq "$rc" "0" "launch exit with planted credentials ($(cat "$S/work.out"))"; fake_ran || fail "the fake engine did not run"
  for v in $SCRUB; do
    grep -qx "$v" "$SP_CAP/env-names" && fail "the engine saw $v from the launching environment"
    grep -qF -- "-u $v " "$SP_CAP/launcher" || fail "the launcher does not unset $v"
  done
  grep -q "FAKE-PLANT" "$SP_CAP/argv" "$SP_CAP/settings.json" && fail "a planted value reached the engine's argv or settings"
  # the anthropic path is untouched: its own login and env are its business
  dry projects/demo | grep -q -- "env -u" && fail "the anthropic command changed"
  return 0
}
# AC36
folder_env_creds_dropped() {
  allow; local v kv="KEEP=1" m
  repo_folder projects/fenv >/dev/null
  for v in $SCRUB; do kv="$kv $v=$(plant_value "$v")"; done
  set_env_block projects/fenv/.claude/settings.json $kv
  local out; out=$(dry --provider deepseek projects/fenv 2>&1) || fail "dry run: $out"
  m="$(dry_settings "$out")"
  for v in $SCRUB; do assert_eq "$(jget "$m" "env.$v")" "<absent>" "$v dropped from the merged env (dry)"; done
  assert_eq "$(jget "$m" env.KEEP)" "1" "other folder env kept"
  launch --provider deepseek projects/fenv; assert_eq "$rc" "0" "launch exit ($(cat "$SP_CAP/work.out"))"
  for v in $SCRUB; do assert_eq "$(jget "$SP_CAP/settings.json" "env.$v")" "<absent>" "$v dropped from the merged env"; grep -qx "$v" "$SP_CAP/env-names" && fail "the engine saw $v"; done
  grep -q "FAKE-PLANT" "$SP_CAP/settings.json" && fail "a planted value is in the merged settings"
  return 0
}
# AC37
checkout_env_creds_refused() {
  allow; local R f v out
  R="$(repo_folder projects/cenv)"
  for f in settings.json settings.local.json; do
    for v in $SCRUB; do
      rm -rf "$R/.claude"; set_env_block "$R/.claude/$f" "$v=$(plant_value "$v")"
      launch --provider deepseek projects/cenv; assert_eq "$rc" "2" "$f with $v: exit"
      assert_contains "$SP_CAP/work.out" "$R/.claude/$f" "$f with $v: refusal names the file"
      assert_contains "$SP_CAP/work.out" "$v" "$f with $v: refusal names the key"
      assert_eq "$(calls secret)" "0" "$f with $v: no key read"; fake_ran && fail "$f with $v: the engine ran"
      grep -q "FAKE-PLANT" "$SP_CAP/work.out" && fail "the refusal printed the planted value"
    done
  done
  rm -rf "$R/.claude"; set_env_block "$R/.claude/settings.local.json" "KEEP=1"
  dry --provider deepseek projects/cenv >/dev/null || fail "a checkout env without credentials is accepted"
  # a folder with no repo works in its own folder: its settings are also the checkout's, so a credential there is refused
  bin/new projects/nenv >/dev/null; set_env_block projects/nenv/.claude/settings.json "ANTHROPIC_AUTH_TOKEN=$(plant_value ANTHROPIC_AUTH_TOKEN)"
  out=$(dry --provider deepseek projects/nenv 2>&1); assert_eq "$?" "2" "no-repo folder with a credential in its settings"
  echo "$out" | grep -q ANTHROPIC_AUTH_TOKEN || fail "no-repo refusal names the key: $out"
  dry projects/nenv >/dev/null || fail "the anthropic path does not check the checkout env"
}
# AC38 (M1): the helper reads the same Keychain item as the pre-check
helper_pins_hub_and_service() {
  allow 'HUB_KEYCHAIN_SERVICE=svc-conf'; rm -f "$SP_ROOT/secret-env"
  launch --provider deepseek projects/demo; assert_eq "$rc" "0" "launch exit"
  local h; h="$(jget "$SP_CAP/settings.json" apiKeyHelper)"
  assert_eq "$h" "HUB='$HUB' AGENT_KEYCHAIN_SERVICE='svc-conf' '$HUB/bin/secret' deepseek-api-key" "helper pins hub and service"
  assert_eq "$(cat "$SP_ROOT/secret-env")" "hub=$HUB svc=svc-conf" "the pre-check read hub and service"
  # the helper, run by /bin/sh from a bare environment, reads the very same item
  rm -f "$SP_ROOT/secret-env"
  env -i PATH="$PATH" SP_CALLS="$SP_CALLS" SP_ROOT="$SP_ROOT" SP_KEYFILE="$SP_KEYFILE" SP_STORED="$SP_STORED" /bin/sh -c "$h" >/dev/null || fail "helper failed"
  assert_eq "$(cat "$SP_ROOT/secret-env")" "hub=$HUB svc=svc-conf" "the helper reads the pre-check's item"
  rm -f "$SP_ROOT/secret-env"; AGENT_KEYCHAIN_SERVICE=svc-env launch --provider deepseek projects/demo; assert_eq "$rc" "0" "launch exit"
  assert_eq "$(jget "$SP_CAP/settings.json" apiKeyHelper)" "HUB='$HUB' AGENT_KEYCHAIN_SERVICE='svc-env' '$HUB/bin/secret' deepseek-api-key" "helper takes the env service"
  assert_eq "$(cat "$SP_ROOT/secret-env")" "hub=$HUB svc=svc-env" "pre-check took the env service"
}
# AC39 (M3)
merged_settings_removed_after_launch() {
  allow; launch --provider deepseek projects/demo; assert_eq "$rc" "0" "launch exit"; fake_ran || fail "the fake did not run"
  local m; m="$(cat "$SP_CAP/settings.path")"; [ -n "$m" ] || fail "no settings path captured"
  [ ! -e "$m" ] || fail "the merged settings file is still there after the launcher exited: $m"
  ls "$TMPDIR"/agent-work.* >/dev/null 2>&1 && fail "a launcher file is left: $(ls "$TMPDIR"/agent-work.*)"
  return 0
}
# AC40 (M3)
agents_no_go_refused() {
  allow; bin/new projects/agng >/dev/null; agent projects/agng a 'name: a' 'description: d'
  local out; out=$(with_lib_edit 'deepseek:agents)' env WORK_DRY=1 bin/work --provider deepseek projects/agng 2>&1); assert_eq "$?" "2" "--agents with a no-go"
  echo "$out" | grep -q "S0 item 21" || fail "agents refusal names S0: $out"
  with_lib_edit 'deepseek:agents)' env WORK_DRY=1 bin/work --provider deepseek projects/demo >/dev/null || fail "a folder with no agents needs no agents go"
  dry --provider deepseek projects/agng >/dev/null || fail "lib.sh restored"
}
# AC41 (m1)
no_settings_left_behind() {
  allow; rm -f "$TMPDIR"/agent-settings.* "$TMPDIR"/agent-work.*
  dry --provider deepseek projects/demo >/dev/null || fail "dry run"
  ls "$TMPDIR"/agent-settings.* >/dev/null 2>&1 && fail "a dry run left a settings file"
  SP_OSA_FAIL=1 launch --provider deepseek projects/demo; [ "$rc" != 0 ] || fail "a failed hand-off exits non-zero"
  ls "$TMPDIR"/agent-settings.* "$TMPDIR"/agent-work.* >/dev/null 2>&1 && fail "a failed hand-off left files: $(ls "$TMPDIR")"
  SP_OSA_FAIL=1 launch projects/demo
  ls "$TMPDIR"/agent-work.* >/dev/null 2>&1 && fail "a failed anthropic hand-off left its launcher"
  return 0
}
# AC42 (m2)
hub_env_mismatch_refused() {
  allow; rm -rf "$S/hub2"; cp -R "$HUB" "$S/hub2"; local out
  out=$(HUB="$S/hub2" WORK_DRY=1 "$HUB/bin/work" --provider deepseek projects/demo 2>&1); assert_eq "$?" "2" "HUB from another hub"
  echo "$out" | grep -q "HUB=" || fail "refusal names HUB: $out"
  HUB="$(cd "$HUB" && pwd -P)" WORK_DRY=1 bin/work --provider deepseek projects/demo >/dev/null || fail "the same hub by its real path"
  env -u HUB WORK_DRY=1 bin/work --provider deepseek projects/demo >/dev/null || fail "HUB unset"
  rm -rf "$S/hub2"
}
# AC43 (m3)
owner_only_default_refuses() {
  . bin/lib.sh; assert_eq "$(provider_field glm owner_only)" "1" "glm is owner-only (z.ai is China-based)"
  client; local out
  out=$(with_lib_edit 'deepseek:owner_only)' env WORK_DRY=1 bin/work --provider deepseek projects/demo 2>&1); assert_eq "$?" "2" "no owner_only value refuses in a client hub"
  echo "$out" | grep -q "HUB_OWNED_BY_OWNER" || fail "refusal names HUB_OWNED_BY_OWNER: $out"
  allow; with_lib_edit 'deepseek:owner_only)' env WORK_DRY=1 bin/work --provider deepseek projects/demo >/dev/null || fail "an owned hub still runs"
}
# AC44 (m4)
config_dir_symlink_refused() {
  allow; local fake="$S/fake-dot-claude" P="$HUB/.local/providers"
  rm -rf "$fake"; mkdir -p "$fake" "$P"; rm -rf "$P/deepseek"; ln -s "$fake" "$P/deepseek"
  launch --provider deepseek projects/demo; assert_eq "$rc" "2" "config dir symlinked out"
  assert_contains "$SP_CAP/work.out" "outside" "refusal says why"; fake_ran && fail "engine ran"; assert_eq "$(calls secret)" "0" "no key read"
  rm -f "$P/deepseek"; mkdir -p "$P/deepseek"; rm -rf "$P/deepseek/projects"; ln -s "$fake" "$P/deepseek/projects"
  launch --provider deepseek projects/demo; assert_eq "$rc" "2" "projects symlinked out"
  rm -f "$P/deepseek/projects"; mv "$HUB/.local" "$S/real-local"; ln -s "$fake" "$HUB/.local"
  launch --provider deepseek projects/demo; assert_eq "$rc" "2" ".local symlinked out"
  rm -f "$HUB/.local"; mv "$S/real-local" "$HUB/.local"
  assert_eq "$(ls -A "$fake")" "" "nothing was written to the fake ~/.claude"
  launch --provider deepseek projects/demo; assert_eq "$rc" "0" "a real config dir runs"
}
# AC45 (m5)
home_is_temp() { case "$HOME" in "$S"/*) ;; *) fail "HOME is not the suite's temp dir: $HOME" ;; esac; }
# the temp dirs this run made (macOS mktemp -d ignores TMPDIR, so they are listed, not found)
record_temp_dirs() { printf '%s\n' "$S" "$(dirname "$HUB")" "$CLAUDE_HOME" "$(dirname "$AGENT_SYNC_LOG")" "$(dirname "$AGENT_SYNC_LOCK")" > "$SP_TEMP_REPORT"; }
env_is_clean() { local v; for v in $(compgen -e); do case "$v" in ANTHROPIC_*|CLAUDE_CODE_USE_*|CLAUDE_CODE_OAUTH_TOKEN) fail "the tester's $v reached the suite" ;; esac; done; }
suite_hermetic_and_clean() {
  local X d; X="$(mktemp -d "$S/tmp/child.XXXXXX")"; mkdir -p "$X/tmp" "$X/home"
  env TMPDIR="$X/tmp" HOME="$X/home" SP_TEMP_REPORT="$X/temps" ANTHROPIC_API_KEY=sk-ant-FAKE-PLANT ANTHROPIC_AUTH_TOKEN=sk-ant-FAKE-PLANT CLAUDE_CODE_USE_BEDROCK=1 \
    bash "$REPO/tests/test_providers.sh" home_is_temp env_is_clean provider_rows_static provider_memory_linked record_temp_dirs > "$X/out" 2>&1 || fail "child suite failed: $(tail -3 "$X/out")"
  assert_eq "$(tail -1 "$X/out")" "ok" "child suite ok"
  [ "$(grep -c . "$X/temps")" = 5 ] || fail "the child did not list its temp dirs"
  while read -r d; do [ ! -e "$d" ] || fail "the child suite left $d"; done < "$X/temps"
  assert_eq "$(ls -A "$X/tmp")" "" "the child suite left files in its TMPDIR"
  assert_eq "$(ls -A "$X/home")" "" "the child suite wrote to the HOME it was given"
  rm -rf "$X"
}

ALL="provider_rows_static dry_run_deepseek launcher_file_holds_no_key engine_argv_holds_no_key fail_closed_on_missing_key
fail_closed_on_empty_key key_checked_once_before_launch single_merged_settings_keeps_hooks checkout_base_url_conflict_refused
provider_implies_no_remote provider_rejects_wrapper_from_each_source provider_model_rules hub_model_not_passed
provider_effort_accepted provider_effort_refused hub_provider_model_override hub_provider_model_checked no_base_url_override
provider_env_not_trusted provider_not_allowed no_go_pair_refused_by_work agents_provider_check doctor_provider_rows_name_only
meta_row_only_with_a_go allowed_tools_applied readme_provider_section adr_0002_provider_section
hermetic_fake_engine_only provider_config_dir_isolated provider_memory_linked provider_resume_refused provider_layer_flags
anthropic_path_unchanged deepseek_client_hub_refused deepseek_owned_hub_allowed owned_by_owner_env_not_trusted
doctor_flags_client_hub_deepseek provider_env_creds_scrubbed folder_env_creds_dropped checkout_env_creds_refused
helper_pins_hub_and_service merged_settings_removed_after_launch agents_no_go_refused no_settings_left_behind
hub_env_mismatch_refused owner_only_default_refuses config_dir_symlink_refused suite_hermetic_and_clean"
for c in ${*:-$ALL}; do "$c"; done
echo ok
