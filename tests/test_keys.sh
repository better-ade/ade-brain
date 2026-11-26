#!/bin/bash
# bin/keys: one place to set each AI tool's key. It stores through bin/secret, shows status only, and enables nothing.
. "$(dirname "$0")/helpers.sh"
make_hub; cd "$HUB"; stub_security
K=sk-test-VALUE-123
out=$(bin/keys) || fail "list"
for t in anthropic deepseek glm muse gemini; do echo "$out" | grep -qE "^$t " || fail "no $t line [$out]"; done
echo "$out" | grep -E '^deepseek ' | grep -q missing || fail "deepseek starts missing [$out]"
echo "$out" | grep -E '^anthropic ' | grep -q missing || fail "anthropic starts missing [$out]"
echo "$out" | grep -A2 -E '^anthropic ' | grep -qi "claude login" || fail "without a key anthropic uses the Claude login [$out]"
echo "$out" | grep -q "bin/keys set glm" || fail "list says how to set a key [$out]"
for pair in anthropic:anthropic-api-key deepseek:deepseek-api-key glm:zai-api-key muse:meta-model-api-key gemini:gemini-api-key; do
  t=${pair%%:*}; n=${pair#*:}; printf '%s-%s\n' "$K" "$t" | bin/keys set "$t" >o 2>e || fail "set $t [$(cat e)]"
  assert_eq "$(bin/secret "$n")" "$K-$t" "$t is stored under $n"; grep -q "$K" o e && fail "set $t printed the key"; done
grep -q "$K" "$STORE.argv" && fail "a key reached a security argument"
out=$(bin/keys); echo "$out" | grep -q "$K" && fail "list printed a key"
echo "$out" | grep -E '^glm ' | grep -q stored || fail "glm is stored [$out]"
echo "$out" | grep -Eq '^anthropic +stored' || fail "anthropic is stored [$out]"
echo "$out" | grep -q "muse is not connected yet" || fail "muse says it is not connected [$out]"
echo "$out" | grep -q "gemini is not connected yet" && fail "gemini is an engine now (story E1) [$out]"
echo "$out" | grep -A2 -E '^gemini ' | grep -q "not usable yet: gemini is not in HUB_PROVIDERS_ALLOWED" || fail "a stored key does not enable gemini [$out]"
echo "$out" | grep -q "HUB_PROVIDERS_ALLOWED" || fail "a stored key does not enable deepseek [$out]"
[ ! -e hub.conf ] || ! grep -q deepseek hub.conf || fail "set changed hub.conf"
printf 'HUB_PROVIDERS_ALLOWED="anthropic deepseek"\nHUB_OWNED_BY_OWNER=1\n' > hub.conf
bin/keys | grep -A1 -E '^deepseek ' | grep -q ready || fail "an allowed provider with a key is ready [$(bin/keys)]"
bin/keys forget glm 2>/dev/null || fail "forget"; bin/secret --has zai-api-key && fail "forget left the key"
bin/keys forget glm >/dev/null 2>&1; assert_eq "$?" "1" "forgetting a missing key exits 1"
out=$(bin/keys set glm "$K" 2>&1); assert_eq "$?" "2" "a key as an argument is refused"; echo "$out" | grep -q "$K" && fail "the refusal repeated the key"
out=$(bin/keys set "$K" </dev/null 2>&1); assert_eq "$?" "2" "unknown tool"; echo "$out" | grep -q "$K" && fail "a key typed as the tool was repeated"
bin/secret --has gemini-api-key || fail "forgetting glm removed another tool's key"
printf '\n' | bin/keys set glm >/dev/null 2>&1; assert_eq "$?" "1" "an empty key is refused"; bin/secret --has zai-api-key && fail "an empty key was stored"
printf 'x\n' | SECURITY_FAIL=1 bin/keys set glm >/dev/null 2>e; assert_eq "$?" "1" "a failed store exits 1"; assert_contains e "could not store" "a failed store says so"
NS="$(mktemp -d)"; for c in bash dirname sed grep awk tr cat python3 git; do ln -s "$(command -v "$c")" "$NS/$c"; done
PATH="$NS" bin/keys bogus >/dev/null 2>&1; assert_eq "$?" "2" "without security, a bad command is still a usage error"
PATH="$NS" bin/keys >/dev/null 2>e; assert_eq "$?" "1" "without security, the list stops"; assert_contains e "macOS Keychain" "it says why"
bin/keys set anthropic "$K" </dev/null >/dev/null 2>&1; assert_eq "$?" "2" "an Anthropic key as an argument is refused"
bin/keys bogus >/dev/null 2>&1; assert_eq "$?" "2" "unknown command"
assert_contains README.md "bin/keys set" "README documents bin/keys"; assert_contains templates/hub/CLAUDE.md "bin/keys" "hub rules name bin/keys"
# --- story K1: users are told how their keys are kept safe ---
readme_keys_safe() {
  local sec rest n p
  grep -n '^## ' README.md | grep -A1 -x '[0-9]*:## Keeping your keys safe' | tail -n 1 | grep -q ':## Handing keys to another person$' ||
    fail "README: 'Keeping your keys safe' comes just before 'Handing keys to another person'"
  sec="$(awk '/^## Keeping your keys safe$/{x=1; next} /^## /{x=0} x' README.md)"
  for p in "Type a key once, in your own terminal." "It lives in a real secret store." "\`bin/keys\` never prints it." \
           "Agents are kept away from it." "Agents are told never to read or ask for a key." "To give a key to someone, seal it."; do printf '%s' "$sec" | grep -qF -- "$p" || fail "README section says: $p"; done
  # every command and setting it names exists
  for n in set forget share; do printf '%s' "$sec" | grep -qF "bin/keys $n" || fail "README names bin/keys $n"
    grep -q "^  $n) " bin/keys || fail "bin/keys has no $n command"; done
  printf '%s' "$sec" | grep -qF 'HUB_SECRET_STORE' && grep -q 'HUB_SECRET_STORE:-' bin/lib.sh || fail "HUB_SECRET_STORE is named and read by bin/lib.sh"
  printf '%s' "$sec" | grep -qF '`0700`' && printf '%s' "$sec" | grep -qF '`0600`' || fail "README names 0700 and 0600"
  grep -q 'dirs 0700, files 0600' bin/lib.sh && grep -q '= 700 \]' bin/lib.sh && grep -q '= 600 \]' bin/lib.sh || fail "0700/0600 match bin/lib.sh"
  grep -q 'never read or print a key' templates/hub/CLAUDE.md || fail "the hub rules tell agents never to read a key, as the README says"
  printf '%s' "$sec" | grep -qF 'weaker store' && grep -q 'the weaker store' bin/doctor || fail "bin/doctor calls the file store the weaker store"
  # each deny pattern it names is one of the hub's deny rules (bin/agent's secret-file names; a folder/ is folder/**)
  rest="$(printf '%s' "$sec" | tr '\n' ' ' | sed -n 's/.*deny rules also keep secret files (\([^)]*\)).*/\1/p')"
  [ -n "$rest" ] || fail "README names the deny patterns"
  for p in $(printf '%s' "$rest" | grep -o '`[^`]*`' | tr -d '`'); do case "$p" in */) p="$p**" ;; esac
    grep -E '^names = \[' bin/agent | grep -qF "\"$p\"" || fail "README deny pattern $p is not in bin/agent's deny names"; done
}
set_says_where() {
  local line="keys: glm stored in the Keychain; agents never see it. Share it sealed: bin/keys share <github-user> glm"
  printf '%s\n' "$K-k1" | bin/keys set glm >o 2>e || fail "set glm [$(cat e)]"
  assert_eq "$(bin/secret zai-api-key)" "$K-k1" "set glm stores the key"
  grep -qxF -- "$line" e || fail "set glm says where, on stderr [$(cat e)]"; grep -q "stored in" o && fail "the line is on stderr only"
  # the label comes from secret_store_label: the Linux file store names its folder
  local FH; FH="$(mktemp -d)"; chmod 700 "$FH"
  printf '%s\n' "$K-k1f" | HOME="$FH" AGENT_SECRETS_DIR= AGENT_PLATFORM=linux bin/keys set glm >o 2>e || fail "set glm in the file store [$(cat e)]"
  grep -qxF -- "keys: glm stored in the file store ($FH/.config/ade/secrets); agents never see it. Share it sealed: bin/keys share <github-user> glm" e ||
    fail "the file store's label [$(cat e)]"
  assert_eq "$(HOME="$FH" AGENT_SECRETS_DIR= AGENT_PLATFORM=linux bin/secret zai-api-key)" "$K-k1f" "stored in the file store"
  grep -rlF -- "$K-k1f" "$FH" | grep -v "^$FH/.config/ade/secrets/" | grep -q . && fail "the value is in a file outside the store"
  rm -rf "$FH"
}
set_fail_quiet() {
  local rc
  printf 'x\n' | SECURITY_FAIL=1 bin/keys set glm >o 2>e; assert_eq "$?" 1 "a failed store exits 1 (bin/secret's status)"
  grep -q "stored in" o e && fail "a failed store says stored in [$(cat e)]"
  printf '\n' | bin/keys set glm >o 2>e; assert_eq "$?" 1 "a cancelled (empty) store exits 1"
  grep -q "stored in" o e && fail "a cancelled store says stored in [$(cat e)]"
  bin/keys set glm </dev/null >o 2>e; assert_eq "$?" 1 "no input exits 1"
  grep -q "stored in" o e && fail "no input says stored in [$(cat e)]"
  # a refused store (the file store's folder is loose)
  local FH; FH="$(mktemp -d)"; chmod 700 "$FH"; mkdir -p "$FH/.config/ade/secrets"; chmod 755 "$FH/.config/ade/secrets"
  printf 'x\n' | HOME="$FH" AGENT_SECRETS_DIR= AGENT_PLATFORM=linux bin/keys set glm >o 2>e; rc=$?; [ "$rc" != 0 ] || fail "a refused store exits non-zero"
  grep -q "stored in" o e && fail "a refused store says stored in [$(cat e)]"; rm -rf "$FH"
  # a TERM while it waits for the value: nothing stored, nothing said
  bin/secret --forget zai-api-key >/dev/null 2>&1
  { sleep 3; printf 'sk-TERM-k1\n'; } | bin/keys set glm >o 2>e & local pid=$!
  sleep 1; kill -TERM "$pid" 2>/dev/null; wait "$pid"; rc=$?; [ "$rc" != 0 ] || fail "a TERM exits non-zero"; sleep 3
  bin/secret --has zai-api-key && fail "a key was stored after a TERM"; grep -q "stored" e && fail "a TERM says stored [$(cat e)]"
  return 0
}
set_no_value() {
  local V="$K-nolk-$$" FH; FH="$(mktemp -d)"; chmod 700 "$FH"
  : > "$STORE.argv"
  # every command the scripts start goes through a wrapper that logs its arguments and environment (none is called by
  # an absolute path, so PATH reaches them all)
  local W c r E; W="$(mktemp -d)"; : > "$W.log"; E="$(type -P env)"   # the wrappers log with the real env
  for c in security pass gpg python3 cat mv cp chmod rm mkdir stat id dirname basename uname sed grep awk tr head tail cut \
           sort git mktemp ls find env echo printf tee date wc readlink realpath perl xargs; do r="$(type -P "$c")" || continue
    # (not what the test's own Keychain stub runs: the real security reads its commands on stdin)
    printf '#!/bin/bash\ncase "$(ps -o command= -p $PPID)" in *%q*) ;; *) { printf "ARGV %%s\\n" "$0 $*"; %q; } >> %q ;; esac\nexec %q "$@"\n' \
      "$(dirname "$STORE")/security" "$E" "$W.log" "$r" > "$W/$c"; chmod +x "$W/$c"; done
  [ -z "$(grep -nE '(^|[;|&(!] *|\$\()/(usr/|opt/)?s?bin/' bin/keys bin/secret bin/lib.sh | grep -v ':1:#!')" ] ||
    fail "bin/keys, bin/secret and bin/lib.sh call nothing by an absolute path"
  printf '%s\n' "$V" | PATH="$W:$PATH" env SHELLOPTS=xtrace bin/keys set deepseek >o 2>e || fail "set under xtrace [$(head -c 300 e)]"
  printf '%s\n' "$V" | PATH="$W:$PATH" bin/keys set muse >>o 2>>e || fail "set muse"
  printf '%s\n' "$V" | PATH="$W:$PATH" HOME="$FH" AGENT_SECRETS_DIR= AGENT_PLATFORM=linux env SHELLOPTS=xtrace bin/keys set gemini >>o 2>>e ||
    fail "set gemini in the file store"
  grep -q '^ARGV .*/security -i' "$W.log" && grep -q '^ARGV .*/mv ' "$W.log" || fail "the wrappers saw the store's commands"
  grep -qF -- "$V" "$W.log" && fail "the value reached a process argument or environment: $(grep -F -- "$V" "$W.log" | head -n 3)"
  grep -qF -- "$V" o e && fail "the value was printed"
  grep -qF -- "$V" "$STORE.argv" && fail "the value reached a process argument"
  grep -q 'stored in' e || fail "the line was printed"
  # outside the stores: the Keychain stub's file and the file store's folder
  # (the whole TMPDIR only under tests/run.sh, which gives each test file its own)
  local where=("$(dirname "$HUB")" "$(dirname "$STORE")" "$FH" "$CLAUDE_HOME"); case "${TMPDIR:-}" in */ade-test.*) where+=("$TMPDIR") ;; esac
  outside() { grep -rlF -- "$V" "${where[@]}" 2>/dev/null | grep -v "^$FH/.config/ade/secrets/" | grep -vxF -- "$STORE"; }
  [ -z "$(outside)" ] || fail "the value is in a file outside the store: $(outside)"
  git grep --untracked -qF -- "$V" && fail "the value is in the hub (git grep)"
  rm -rf "$FH" "$W" "$W.log"
}
readme_keys_safe; set_says_where; set_fail_quiet; set_no_value
echo ok
