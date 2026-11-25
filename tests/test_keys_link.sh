#!/bin/bash
# bin/keys share --link / receive <link> (story I6): the sealed block travels as a one-time Onetime Secret link.
# A local fake of the service's anonymous v3 guest API (tests/fake_onetime.py), never the internet: with
# AGENT_PLATFORM_TEST=1 bin/keys sends requests only to AGENT_ONETIME_API; HUB_ONETIME_URL (https://ots.test) is the
# instance the links name. Wrappers on PATH record the argv of curl, age, ssh-keygen and python3 (AC4).
. "$(dirname "$0")/helpers.sh"
command -v age >/dev/null && command -v ssh-keygen >/dev/null || fail "age and ssh-keygen are needed for this test"
make_hub; cd "$HUB"; unset AGENT_SECRETS_DIR AGENT_KEYCHAIN_SERVICE AGENT_KEYS_NOW AGENT_ONETIME_API AGENT_ONETIME_TIMEOUT HUB_ONETIME_URL
printf 'HUB_SECRET_STORE=file\nHUB_ONETIME_URL=https://ots.test\n' > hub.conf
T="$(mktemp -d)"; W="$T/wrap"; mkdir -p "$W" "$T/gh" "$T/tmp"
export TMPDIR="$T/tmp"   # bin/keys's temp files land in $T, which AC4 scans
# three fake services: ok, error (500) and hang; started with the real python3, before the wrappers
REAL_PY="$(command -v python3)"; SRV=""
fake() { local d="$T/srv-$1"; mkdir -p "$d"; "$REAL_PY" "$REPO/tests/fake_onetime.py" "$d/port" "$d/log" "$1" > /dev/null 2>&1 & SRV="$SRV $!"
  for i in $(seq 1 300); do [ -s "$d/port" ] && break; sleep 0.1; done; [ -s "$d/port" ] || fail "fake $1 did not start"; : >> "$d/log"; }
trap 'kill $SRV 2>/dev/null' EXIT
fake ok; fake error; fake hang; fake badid; url() { echo "http://127.0.0.1:$(cat "$T/srv-$1/port")"; }
OK="$(url ok)"; ERR="$(url error)"; HANG="$(url hang)"; LOG="$T/srv-ok/log"
export AGENT_ONETIME_API="$OK"
# argv recorders: each logs its argv, then runs the real tool
ARGV="$T/argv"; : > "$ARGV"
for tool in curl age ssh-keygen python3; do real="$(command -v "$tool")"
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> %q\nexec %q "$@"\n' "$ARGV" "$real" > "$W/$tool"; chmod +x "$W/$tool"; done
# no real GitHub: gh signed in as nobody; each user's keys in $T/gh/<user>.keys
unset GH_TOKEN GITHUB_TOKEN; export GH_CONFIG_DIR="$T/gh-none"
printf '#!/bin/sh\nexit 1\n' > "$W/gh"; chmod +x "$W/gh"; export PATH="$W:$PATH" AGENT_GITHUB_KEYS_URL="$T/gh/{user}.keys"
person() { local h; h="$(mktemp -d)/home"; mkdir -p "$h/.ssh"; echo "$h"; }
HA="$(person)"; HB="$(person)"; HC="$(person)"
ssh-keygen -q -t ed25519 -N '' -C a -f "$HA/.ssh/id_ed25519" && ssh-keygen -q -t ed25519 -N '' -C b -f "$HB/.ssh/id_ed25519" || fail "ssh-keygen"
# C holds B's key too (a second machine of B's): a second receive there must find the link gone and store nothing
cp "$HB/.ssh/id_ed25519" "$HB/.ssh/id_ed25519.pub" "$HC/.ssh/"
cut -d' ' -f1,2 "$HA/.ssh/id_ed25519.pub" > "$T/gh/a.keys"; cut -d' ' -f1,2 "$HB/.ssh/id_ed25519.pub" > "$T/gh/b.keys"
as() { local h="$1"; shift; HOME="$h" "$@"; }
# made-up values, built at run time so the test's own source never holds one
R="$$$RANDOM"; V1="sk-link-ONE-$R"; V2="sk-link-TWO-$R"
printf '%s\n' "$V1" | as "$HA" bin/keys set deepseek >/dev/null 2>&1 || fail "A stores deepseek"
printf '%s\n' "$V2" | as "$HA" bin/keys set glm >/dev/null 2>&1 || fail "A stores glm"
stored() { find "$1/.config/ade/secrets" -type f 2>/dev/null; }
lines() { wc -l < "$1" | tr -d ' '; }
armor_only() { awk 'NR==1 && $0!="-----BEGIN AGE ENCRYPTED FILE-----"{bad=1} {last=$0} END{exit (bad || last!="-----END AGE ENCRYPTED FILE-----")}' "$1"; }
# body <n>: the "secret" field of the n-th logged conceal body
body() { "$REAL_PY" -c 'import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if "/conceal" in l]
print(json.loads(rows[int(sys.argv[2]) - 1]["body"])["secret"][sys.argv[3]])' "$LOG" "$1" "$2"; }

# --- AC1: --link uploads only the armored, sealed block and prints one https link
echo y | as "$HA" bin/keys share b deepseek glm --as a --link > "$T/o1" 2> "$T/e1"; assert_eq "$?" 0 "share --link: $(cat "$T/e1")"
assert_eq "$(lines "$T/o1")" 1 "stdout is one line: $(cat "$T/o1")"
LINK="$(cat "$T/o1")"
[[ "$LINK" =~ ^https://ots\.test/secret/[a-z0-9]{62}$ ]] || fail "stdout is one https link on HUB_ONETIME_URL: $LINK"
assert_eq "$(grep -c '/conceal' "$LOG")" 1 "one create request"
"$REAL_PY" -c 'import json, sys; r = json.loads(open(sys.argv[1]).readline()); assert r["path"] == "/api/v3/guest/secret/conceal" and r["type"] == "application/json", r' "$LOG" || fail "create is a JSON POST to the guest conceal route"
body 1 secret > "$T/sent1"; armor_only "$T/sent1" || fail "the body holds the armored block alone: $(cat "$T/sent1")"
grep -q "ade-keys-share\|secret deepseek\|$V1\|$V2" "$LOG" && fail "the service saw a plain header or a value"
assert_eq "$(body 1 ttl)" 604800 "the link expires in 7 days, as the block"
grep -q "one-time link" "$T/e1" || fail "share says it made a one-time link: $(cat "$T/e1")"
# a shorter block: the link expires with it; a longer one: the link stops at the service's 7 days, and says so
echo y | as "$HA" bin/keys share b deepseek --as a --link --days 3 > /dev/null 2> "$T/e1b" || fail "share --days 3 --link: $(cat "$T/e1b")"
assert_eq "$(body 2 ttl)" 259200 "--days 3: the link expires in 3 days"
echo y | as "$HA" bin/keys share b deepseek --as a --link --days 20 > /dev/null 2> "$T/e1c" || fail "share --days 20 --link: $(cat "$T/e1c")"
assert_eq "$(body 3 ttl)" 604800 "--days 20: the link stops at 7 days"
grep -q "7 days" "$T/e1c" || fail "says the link stops at 7 days: $(cat "$T/e1c")"
# a non-https HUB_ONETIME_URL (or one with a path, a user or a query) is refused before any request, before the prompt
n0="$(lines "$LOG")"; c0="$(grep -c '127.0.0.1' "$ARGV")"
for u in http://ots.test ftp://ots.test https://ots.test/x https://u@ots.test 'https://ots.test?x' https:// 'https://ots test'; do
  sed -i.bak "s#^HUB_ONETIME_URL=.*#HUB_ONETIME_URL='$u'#" hub.conf
  echo y | as "$HA" bin/keys share b deepseek --as a --link > "$T/o2" 2> "$T/e2"; assert_eq "$?" 2 "$u is refused: $(cat "$T/e2")"
  [ -s "$T/o2" ] && fail "$u: nothing on stdout"; grep -q "HUB_ONETIME_URL" "$T/e2" || fail "$u: the message names HUB_ONETIME_URL: $(cat "$T/e2")"
  grep -q "seal.*\[y/N\]" "$T/e2" && fail "$u: refused before the prompt"
  # receive with the same bad HUB_ONETIME_URL: exit 2, before any request
  as "$HB" bin/keys receive "https://ots.test/secret/abcdefghijklmnopqrstuvwxyz0123456789" > /dev/null 2> "$T/e2r"; assert_eq "$?" 2 "$u: receive refuses: $(cat "$T/e2r")"
  grep -q "HUB_ONETIME_URL" "$T/e2r" || fail "$u: receive names HUB_ONETIME_URL: $(cat "$T/e2r")"
done
sed -i.bak "s#^HUB_ONETIME_URL=.*#HUB_ONETIME_URL=https://ots.test#" hub.conf
assert_eq "$(lines "$LOG")" "$n0" "no request for a refused HUB_ONETIME_URL"
assert_eq "$(grep -c '127.0.0.1' "$ARGV")" "$c0" "curl never ran for a refused HUB_ONETIME_URL"
grep -q "deepseek.*\[y/N\]" "$T/e1" && ! grep -q "goes to ots.test as a one-time link" "$T/e1" && fail "the prompt says where the block goes: $(cat "$T/e1")"
# HUB_ONETIME_URL unset (a hub made before I6): the public instance's API host names the link, and receive takes it
# (requests still go only to the local fake)
printf 'HUB_SECRET_STORE=file\n' > hub.conf
echo y | as "$HA" bin/keys share b deepseek --as a --link > "$T/od" 2> "$T/ed" || fail "share --link with the default: $(cat "$T/ed")"
[[ "$(cat "$T/od")" =~ ^https://us\.onetimesecret\.com/secret/[a-z0-9]{62}$ ]] || fail "the default HUB_ONETIME_URL names the link: $(cat "$T/od")"
echo n | as "$HB" bin/keys receive "$(cat "$T/od")" > /dev/null 2> "$T/ed2"; grep -q "store these?" "$T/ed2" || fail "receive takes a link on the default host: $(cat "$T/ed2")"
printf 'HUB_SECRET_STORE=file\nHUB_ONETIME_URL=https://ots.test\n' > hub.conf

# --- AC3: a link on another host than HUB_ONETIME_URL's is refused before any request
n0="$(lines "$LOG")"; ID="${LINK##*/}"
for l in "https://evil.test/secret/$ID" "http://ots.test/secret/$ID" "https://ots.test.evil.test/secret/$ID" "https://ots.test@evil.test/secret/$ID" \
         "https://ots.test:8443/secret/$ID" "https://ots.test/private/$ID" "https://ots.test/secret/../x/$ID" "https://ots.test/secret/$ID?x=1"; do
  echo y | as "$HB" bin/keys receive "$l" > "$T/o3" 2> "$T/e3"; assert_eq "$?" 1 "$l is refused: $(cat "$T/e3")"
  grep -q "ots.test" "$T/e3" || fail "$l: the message names the instance taken: $(cat "$T/e3")"
done
assert_eq "$(lines "$LOG")" "$n0" "no request for a link on another host"
[ -z "$(stored "$HB")" ] || fail "a refused link stored something"

# --- AC2: receive <link> opens the block, checks it as I5 does and asks; y stores; the second fetch finds it gone
echo y | as "$HB" bin/keys receive "$LINK" > "$T/o4" 2> "$T/e4"; assert_eq "$?" 0 "receive <link>: $(cat "$T/e4")"
FA="$(ssh-keygen -lf "$HA/.ssh/id_ed25519.pub" | cut -d' ' -f2)"
grep -qF "from:    a (verified: signed by $FA)" "$T/e4" || fail "the signature is checked as I5 does: $(cat "$T/e4")"
grep -q "store these? \[y/N\]" "$T/e4" || fail "receive asks before storing: $(cat "$T/e4")"
assert_eq "$(as "$HB" bin/secret deepseek-api-key)" "$V1" "B has A's deepseek key"
assert_eq "$(as "$HB" bin/secret zai-api-key)" "$V2" "B has A's glm key"
"$REAL_PY" -c 'import json, sys
r = [json.loads(l) for l in open(sys.argv[1])][-1]
assert r["path"] == "/api/v3/guest/secret/%s/reveal" % sys.argv[2] and json.loads(r["body"]) == {"continue": True}, r' "$LOG" "$ID" || fail "the fetch is a reveal of that secret"
echo y | as "$HC" bin/keys receive "$LINK" > "$T/o5" 2> "$T/e5"; assert_eq "$?" 1 "a second fetch fails: $(cat "$T/e5")"
grep -q "already opened or expired" "$T/e5" || fail "says already opened or expired: $(cat "$T/e5")"
[ -z "$(stored "$HC")" ] || fail "the second receive stored something"
# a "no" stores nothing, and the link is used up all the same (it says so)
echo y | as "$HA" bin/keys share b deepseek --as a --link > "$T/o6" 2>/dev/null || fail "share for the no case"
echo n | as "$HC" bin/keys receive "$(cat "$T/o6")" > /dev/null 2> "$T/e6"; assert_eq "$?" 1 "no stores nothing"
grep -q "opens once" "$T/e6" || fail "says the link is used up: $(cat "$T/e6")"
[ -z "$(stored "$HC")" ] || fail "a no stored something"
# no identity to open it: refused before the fetch, so the link still opens for B afterwards
HN="$(person)"; echo y | as "$HA" bin/keys share b deepseek --as a --link > "$T/oi" 2>/dev/null || fail "share for the no-identity case"
n0="$(grep -c '/reveal' "$LOG")"
echo y | as "$HN" bin/keys receive "$(cat "$T/oi")" > /dev/null 2> "$T/ei"; assert_eq "$?" 1 "no identity: refused: $(cat "$T/ei")"
grep -q "no identity to open it" "$T/ei" || fail "says there is no identity: $(cat "$T/ei")"
assert_eq "$(grep -c '/reveal' "$LOG")" "$n0" "no fetch without an identity"
echo n | as "$HB" bin/keys receive "$(cat "$T/oi")" > /dev/null 2> "$T/ei2"; grep -q "store these?" "$T/ei2" || fail "the link still opens for B: $(cat "$T/ei2")"
# a service error or timeout on receive: could not fetch, nothing asked, nothing stored
for case in "error|$ERR|" "hang|$HANG|2"; do IFS='|' read -r name api to <<< "$case"
  echo y | AGENT_ONETIME_API="$api" AGENT_ONETIME_TIMEOUT="$to" as "$HC" bin/keys receive "$LINK" > /dev/null 2> "$T/ef"
  assert_eq "$?" 1 "$name: receive fails: $(cat "$T/ef")"
  grep -q "could not fetch the link" "$T/ef" || fail "$name: says it could not fetch: $(cat "$T/ef")"
  grep -q "store these?" "$T/ef" && fail "$name: asked to store"
  [ -z "$(stored "$HC")" ] || fail "$name: stored something"
done
grep -q '/reveal' "$T/srv-error/log" || fail "the error service was asked to reveal"
# a link and a file together: usage
as "$HB" bin/keys receive "$LINK" "$T/o1" > /dev/null 2>&1; assert_eq "$?" 2 "a link and a file is a usage error"
# with no AGENT_ONETIME_API a test run fetches nothing
echo y | AGENT_ONETIME_API= as "$HB" bin/keys receive "$LINK" > /dev/null 2> "$T/e7"; assert_eq "$?" 1 "no test API: refused"
grep -q "AGENT_ONETIME_API" "$T/e7" || fail "names AGENT_ONETIME_API: $(cat "$T/e7")"
echo y | AGENT_ONETIME_API=https://example.com as "$HB" bin/keys receive "$LINK" > /dev/null 2> "$T/e7b"; assert_eq "$?" 1 "a non-local test API: refused"

# --- AC5: a service error or timeout on share prints the block as before and says the link failed
for case in "error|$ERR|" "hang|$HANG|2" "none||"; do IFS='|' read -r name api to <<< "$case"
  echo y | AGENT_ONETIME_API="$api" AGENT_ONETIME_TIMEOUT="$to" as "$HA" bin/keys share b deepseek --as a --link > "$T/o8" 2> "$T/e8"
  assert_eq "$?" 1 "$name: share says the link failed (exit 1): $(cat "$T/e8")"
  armor_only "$T/o8" || fail "$name: the block is printed as before: $(cat "$T/o8")"
  grep -q "link failed" "$T/e8" || fail "$name: says the link failed: $(cat "$T/e8")"
  grep -q "https://" "$T/o8" && fail "$name: no link printed"
done
grep -q '/conceal' "$T/srv-error/log" || fail "the error service was asked"
# the printed block still opens
echo y | as "$HB" bin/keys receive "$T/o8" > /dev/null 2> "$T/e9" || fail "the fallback block opens: $(cat "$T/e9")"

# --- fix round: a block refused after the fetch is kept (sealed, 0600) so the right receiver can retry from it
# D has an ssh identity, but the block is sealed to B: the fetch burns the link, the refusal names the kept file
HD="$(person)"; ssh-keygen -q -t ed25519 -N '' -C d -f "$HD/.ssh/id_ed25519" || fail "ssh-keygen d"
echo y | as "$HA" bin/keys share b deepseek --as a --link > "$T/ok1" 2>/dev/null || fail "share for the kept-block case"
echo y | as "$HD" bin/keys receive "$(cat "$T/ok1")" > /dev/null 2> "$T/ek1"; assert_eq "$?" 1 "D cannot open it: $(cat "$T/ek1")"
grep -q "not sealed to your keys" "$T/ek1" || fail "the refusal says why: $(cat "$T/ek1")"
KEPT="$(sed -n 's/^keys: the link is used up; its sealed block is kept in \(.*\) (only.*$/\1/p' "$T/ek1")"
[ -n "$KEPT" ] && [ -f "$KEPT" ] || fail "the refusal names the kept block: $(cat "$T/ek1")"
case "$KEPT" in "$HD"/*) ;; *) fail "the kept block is in D's home: $KEPT" ;; esac
assert_eq "$(fmode "$KEPT")" 600 "the kept block is 0600"; assert_eq "$(fmode "${KEPT%/*}")" 700 "its folder is 0700"
armor_only "$KEPT" || fail "the kept file is the armored block alone"
echo y | as "$HB" bin/keys receive "$KEPT" > /dev/null 2> "$T/ek2"; assert_eq "$?" 0 "B opens the kept block: $(cat "$T/ek2")"
assert_eq "$(as "$HB" bin/secret deepseek-api-key)" "$V1" "B stored it from the kept block"
# --- fix round: whitespace or a control character in a link or HUB_ONETIME_URL is refused before any request
n0="$(lines "$LOG")"
for l in "https://ots.test"$'\n'"/secret/$ID" "https://ots.test/secret/$ID"$'\n' "https://ots.test /secret/$ID" "https://ots.test"$'\t'"/secret/$ID" "https://ots.test"$'\r'"/secret/$ID"; do
  echo y | as "$HB" bin/keys receive "$l" > /dev/null 2> "$T/ew"; assert_eq "$?" 1 "a link with whitespace is refused: $(cat "$T/ew")"; done
printf 'HUB_SECRET_STORE=file\nHUB_ONETIME_URL="https://ots.test\n"\n' > hub.conf
echo y | as "$HA" bin/keys share b deepseek --as a --link > /dev/null 2> "$T/ew2"; assert_eq "$?" 2 "HUB_ONETIME_URL with a newline is refused: $(cat "$T/ew2")"
printf 'HUB_SECRET_STORE=file\nHUB_ONETIME_URL=https://ots.test\n' > hub.conf
assert_eq "$(lines "$LOG")" "$n0" "no request for a link or base with whitespace"
# --- fix round: the JSON charset guard: an armor line with a quote or backslash is never sent
W2="$T/wrap2"; mkdir -p "$W2"; REAL_AGE="$(cd "$W" && PATH="${PATH#"$W:"}" command -v age)"
printf '#!/bin/bash\nfor a in "$@"; do [ "$a" = -a ] && { %q "$@" | sed '"'"'2s/^/x\\"\\\\\\\\/'"'"'; exit "${PIPESTATUS[0]}"; }; done\nexec %q "$@"\n' "$REAL_AGE" "$REAL_AGE" > "$W2/age"; chmod +x "$W2/age"
n0="$(lines "$LOG")"
echo y | PATH="$W2:$PATH" as "$HA" bin/keys share b deepseek --as a --link > "$T/oj" 2> "$T/ej"; assert_eq "$?" 1 "a block with a quote is not sent: $(cat "$T/ej")"
grep -q '"' "$T/oj" || fail "the tampered age output reached the guard: $(cat "$T/oj")"
grep -q "link failed" "$T/ej" || fail "says the link failed: $(cat "$T/ej")"
assert_eq "$(lines "$LOG")" "$n0" "no request for a block with a quote or backslash"
# --- fix round: an id that is not letters and digits (x/../..) gives the fallback, never a printed link
echo y | AGENT_ONETIME_API="$(url badid)" as "$HA" bin/keys share b deepseek --as a --link > "$T/ob" 2> "$T/eb"; assert_eq "$?" 1 "a bad id: $(cat "$T/eb")"
armor_only "$T/ob" || fail "a bad id prints the block: $(cat "$T/ob")"
grep -q "link failed" "$T/eb" || fail "a bad id says the link failed: $(cat "$T/eb")"
grep -q '/conceal' "$T/srv-badid/log" || fail "the badid service was asked"
# --- fix round: outside test mode curl gets -q first, --proto =https, --tlsv1.2, no -L, HUB_ONETIME_URL as the base
# (hermetic: a curl stub records its argv and answers 404; nothing leaves the machine)
W3="$T/wrap3"; mkdir -p "$W3"; PA="$T/prod.argv"; : > "$PA"
printf '#!/bin/bash\nprintf "%%s\\n" "$@" > %q; cat > /dev/null; printf "{}\\n404"\n' "$PA" > "$W3/curl"; chmod +x "$W3/curl"
echo y | PATH="$W3:$PATH" HOME="$HB" env -u AGENT_PLATFORM_TEST -u AGENT_PLATFORM bin/keys receive "https://ots.test/secret/$ID" > /dev/null 2> "$T/ep"
grep -q "already opened or expired" "$T/ep" || fail "the production path reached the stubbed curl: $(cat "$T/ep")"
assert_eq "$(head -1 "$PA")" "-q" "curl's first argument is -q (no ~/.curlrc)"
grep -qx -- "--proto" "$PA" && grep -A1 -x -- "--proto" "$PA" | grep -qx '=https' || fail "--proto =https: $(tr '\n' ' ' < "$PA")"
grep -qx -- "--tlsv1.2" "$PA" || fail "--tlsv1.2: $(tr '\n' ' ' < "$PA")"
grep -qxE -- "-L|--location" "$PA" && fail "no redirects followed: $(tr '\n' ' ' < "$PA")"
assert_eq "$(tail -1 "$PA")" "https://ots.test/api/v3/guest/secret/$ID/reveal" "the request goes to HUB_ONETIME_URL"

# --- AC4: no value on stdout or stderr, in files outside the stores, in process arguments or in the service's log
grep -lF -e "$V1" -e "$V2" "$T"/o* "$T"/e* "$ARGV" "$T"/srv-*/log 2>/dev/null | grep -q . && fail "a value in output, argv or the service log: $(grep -lF -e "$V1" -e "$V2" "$T"/o* "$T"/e* "$ARGV" "$T"/srv-*/log)"
grep -rlF -e "$V1" -e "$V2" "$T" "$HA" "$HB" "$HC" 2>/dev/null | grep -v '/.config/ade/secrets/' | grep -q . &&
  fail "a value outside the stores: $(grep -rlF -e "$V1" -e "$V2" "$T" "$HA" "$HB" "$HC" 2>/dev/null | grep -v '/.config/ade/secrets/')"
grep -q -- "--data-binary @-" "$ARGV" || fail "curl reads the body from stdin"
echo ok
