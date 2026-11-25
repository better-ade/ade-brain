#!/bin/bash
# E2E (story I4, AC9), offline: two people, two HOMEs. A holds three keys; B's SSH key is served as B's "GitHub keys".
# A shares, B receives (one yes to "store these?"), B's bin/keys shows the three as stored; a second receive of the same
# block asks once, then before each replace. Every output is kept in $T and scanned for a value.
. "$(dirname "$0")/helpers.sh"
command -v age >/dev/null && command -v ssh-keygen >/dev/null || fail "age and ssh-keygen are needed for this test"
make_hub; cd "$HUB"; unset AGENT_SECRETS_DIR AGENT_KEYCHAIN_SERVICE AGENT_KEYS_NOW
printf 'HUB_SECRET_STORE=file\n' > hub.conf
T="$(mktemp -d)"; HA="$T/a"; HB="$T/b"; mkdir -p "$HA" "$HB/.ssh"
ssh-keygen -q -t ed25519 -N '' -C b -f "$HB/.ssh/id_ed25519" || fail "ssh-keygen"
export AGENT_GITHUB_KEYS_URL="$T/b.keys"; cut -d' ' -f1,2 "$HB/.ssh/id_ed25519.pub" > "$AGENT_GITHUB_KEYS_URL"
for t in deepseek glm gemini; do printf 'e2e-%s-value-%s\n' "$t" "$$" | HOME="$HA" bin/keys set "$t" >/dev/null 2>&1 || fail "A sets $t"; done
echo y | HOME="$HA" bin/keys share b --all > "$T/block" 2> "$T/e0"; assert_eq "$?" 0 "A shares: $(cat "$T/e0")"
grep -q "e2e-" "$T/block" && fail "the block holds a value in clear"
echo y | HOME="$HB" bin/keys receive "$T/block" > "$T/o1" 2> "$T/e1"; assert_eq "$?" 0 "B receives: $(cat "$T/e1")"
grep -q "store these?" "$T/e1" || fail "receive asks before storing: $(cat "$T/e1")"
out="$(HOME="$HB" bin/keys 2> "$T/e2")" || fail "B's bin/keys"
for t in deepseek glm gemini; do echo "$out" | grep -Eq "^$t +stored" || fail "B's bin/keys shows $t stored: $out"; done
echo "$out" | grep -q "e2e-" && fail "bin/keys printed a value"
assert_eq "$(HOME="$HB" bin/secret gemini-api-key)" "e2e-gemini-value-$$" "B has A's gemini key"
# the second receive: "store these?", then one question per key already stored; answers y, then y, n, y in the block's order
printf 'y\ny\nn\ny\n' | HOME="$HB" bin/keys receive "$T/block" > "$T/o3" 2> "$T/e3"; assert_eq "$?" 0 "second receive: $(cat "$T/e3")"
assert_eq "$(grep -o 'replace it?' "$T/e3" | wc -l | tr -d ' ')" 3 "asks before each of the three replaces: $(cat "$T/e3")"
# no value in any output, nor in any file outside the two stores
grep -rlF "e2e-" "$T" | grep -v "^$T/[ab]/.config/ade/secrets/" | grep -q . && fail "a value outside the stores: $(grep -rlF "e2e-" "$T")"
echo ok
