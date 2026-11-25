#!/bin/bash
# E2E (story I6, AC6), offline: two people, two HOMEs, one local fake Onetime Secret (tests/fake_onetime.py). A shares
# three keys signed with --link; B receives by the link (verified, one yes) and holds them; a second receive of the same
# link finds it gone and stores nothing. Every output and the service's log are scanned for a value.
. "$(dirname "$0")/helpers.sh"
command -v age >/dev/null && command -v ssh-keygen >/dev/null || fail "age and ssh-keygen are needed for this test"
make_hub; cd "$HUB"; unset AGENT_SECRETS_DIR AGENT_KEYCHAIN_SERVICE AGENT_KEYS_NOW AGENT_ONETIME_TIMEOUT HUB_ONETIME_URL
printf 'HUB_SECRET_STORE=file\nHUB_ONETIME_URL=https://ots.test\n' > hub.conf
T="$(mktemp -d)"; HA="$T/a"; HB="$T/b"; mkdir -p "$HA/.ssh" "$HB/.ssh" "$T/bin" "$T/gh" "$T/srv"
python3 "$REPO/tests/fake_onetime.py" "$T/srv/port" "$T/srv/log" ok > /dev/null 2>&1 & SRV=$!; trap 'kill $SRV 2>/dev/null' EXIT
for i in $(seq 1 50); do [ -s "$T/srv/port" ] && break; sleep 0.1; done; [ -s "$T/srv/port" ] || fail "the fake service did not start"
export AGENT_ONETIME_API="http://127.0.0.1:$(cat "$T/srv/port")"
unset GH_TOKEN GITHUB_TOKEN; export GH_CONFIG_DIR="$T/gh-none"
printf '#!/bin/sh\nexit 1\n' > "$T/bin/gh"; chmod +x "$T/bin/gh"; export PATH="$T/bin:$PATH" AGENT_GITHUB_KEYS_URL="$T/gh/{user}.keys"
ssh-keygen -q -t ed25519 -N '' -C b -f "$HB/.ssh/id_ed25519" && ssh-keygen -q -t ed25519 -N '' -C a -f "$HA/.ssh/id_ed25519" || fail "ssh-keygen"
cut -d' ' -f1,2 "$HB/.ssh/id_ed25519.pub" > "$T/gh/b.keys"; cut -d' ' -f1,2 "$HA/.ssh/id_ed25519.pub" > "$T/gh/a.keys"
FA="$(ssh-keygen -lf "$HA/.ssh/id_ed25519.pub" | cut -d' ' -f2)"
for t in deepseek glm gemini; do printf 'e2el-%s-value-%s\n' "$t" "$$" | HOME="$HA" bin/keys set "$t" >/dev/null 2>&1 || fail "A sets $t"; done
echo y | HOME="$HA" bin/keys share b --all --as a --link > "$T/link" 2> "$T/e0"; assert_eq "$?" 0 "A shares by link: $(cat "$T/e0")"
[[ "$(cat "$T/link")" =~ ^https://ots\.test/secret/[a-z0-9]+$ ]] || fail "A gets one https link: $(cat "$T/link")"
echo y | HOME="$HB" bin/keys receive "$(cat "$T/link")" > "$T/o1" 2> "$T/e1"; assert_eq "$?" 0 "B receives by the link: $(cat "$T/e1")"
grep -qF "from:    a (verified: signed by $FA)" "$T/e1" || fail "B sees A verified: $(cat "$T/e1")"
for t in deepseek glm gemini; do
  assert_eq "$(HOME="$HB" bin/secret "$(HOME="$HB" bash -c '. bin/lib.sh; key_secret "$1"' _ "$t")")" "e2el-$t-value-$$" "B holds A's $t key"; done
HOME="$HB" bin/keys > "$T/o2" 2>&1; grep -q "^deepseek .*stored" "$T/o2" || fail "B's bin/keys shows deepseek stored: $(cat "$T/o2")"
# the second receive: the link is gone; B's store is unchanged (nothing asked, nothing replaced)
echo y | HOME="$HB" bin/keys receive "$(cat "$T/link")" > "$T/o3" 2> "$T/e3"; assert_eq "$?" 1 "the second receive fails: $(cat "$T/e3")"
grep -q "already opened or expired" "$T/e3" || fail "says already opened or expired: $(cat "$T/e3")"
grep -q "store these?" "$T/e3" && fail "the second receive asked to store"
grep -c '/reveal' "$T/srv/log" | grep -qx 2 || fail "two reveals reached the service"
grep -rlF "e2el-" "$T" | grep -v "^$T/b/.config/ade/secrets/\|^$T/a/.config/ade/secrets/" | grep -q . && fail "a value outside the stores: $(grep -rlF "e2el-" "$T" | grep -v '/.config/ade/secrets/')"
echo ok
