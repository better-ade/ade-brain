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
echo "$out" | grep -q "gemini is not connected yet" || fail "gemini says it is not connected [$out]"
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
echo ok
