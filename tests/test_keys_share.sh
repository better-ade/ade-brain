#!/bin/bash
# bin/keys share / receive (story I4): a hub's keys sealed with age to one person, opened into their own store.
# A real age (behind a wrapper that records its argv), ssh-keygen keys, the file store, one HOME per person.
. "$(dirname "$0")/helpers.sh"
command -v age >/dev/null && command -v age-keygen >/dev/null || fail "age is needed for this test (brew install age / apt-get install age)"
command -v ssh-keygen >/dev/null || fail "ssh-keygen is needed for this test"
make_hub; cd "$HUB"; unset AGENT_SECRETS_DIR AGENT_KEYCHAIN_SERVICE AGENT_GITHUB_KEYS_URL AGENT_KEYS_NOW
printf 'HUB_SECRET_STORE=file\n' > hub.conf
T="$(mktemp -d)"; LOG="$T/age.argv"; : > "$LOG"
# AC6: a fake age earlier on PATH: it records its argv, then runs the real one
W="$T/wrap"; mkdir -p "$W"; REAL_AGE="$(command -v age)"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> %q\nexec %q "$@"\n' "$LOG" "$REAL_AGE" > "$W/age"; chmod +x "$W/age"; export PATH="$W:$PATH"
# I5 AC6: a fake ssh-keygen too: it records its argv and keeps a copy of every file it is given (the scan reads them)
SKLOG="$T/ssh-keygen.argv"; SEEN="$T/seen"; mkdir -p "$SEEN"; REAL_SK="$(command -v ssh-keygen)"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> %q\nfor a; do [ -f "$a" ] && cp "$a" %q/$RANDOM$RANDOM; done\nexec %q "$@"\n' "$SKLOG" "$SEEN" "$REAL_SK" > "$W/ssh-keygen"; chmod +x "$W/ssh-keygen"
# no real GitHub sign-in reaches bin/keys share (it asks gh for the sender's user): a gh stub first on PATH that is
# signed in as nobody, and no token; a curl that records its argv (a test never fetches from github.com)
unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN; export GH_CONFIG_DIR="$T/gh-none"
printf '#!/bin/sh\necho "gh: not signed in (test stub)" >&2; exit 1\n' > "$W/gh"; chmod +x "$W/gh"
CLOG="$T/curl.argv"; : > "$CLOG"; REAL_CURL="$(command -v curl)"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> %q\nexec %q "$@"\n' "$CLOG" "$REAL_CURL" > "$W/curl"; chmod +x "$W/curl"
person() { local h; h="$(mktemp -d)/home"; mkdir -p "$h"; echo "$h"; }
HA="$(person)"; HB="$(person)"; HC="$(person)"; HD="$(person)"; HE="$(person)"; HF="$(person)"; HG="$(person)"
as() { local h="$1"; shift; HOME="$h" "$@"; }
# no_tty <cmd…>: run it without a controlling terminal (its own session), so /dev/tty cannot be opened even when the
# suite runs from a terminal
no_tty() { python3 -c 'import os, sys
if os.getpid() == os.getpgrp():
    pid = os.fork()
    if pid: os._exit(os.waitstatus_to_exitcode(os.waitpid(pid, 0)[1]) & 255)
os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' "$@"; }
mkdir -p "$HB/.ssh"; ssh-keygen -q -t ed25519 -N '' -C b -f "$HB/.ssh/id_ed25519" || fail "ssh-keygen ed25519"
ssh-keygen -q -t rsa -b 2048 -N '' -C b -f "$T/b_rsa" && ssh-keygen -q -t ecdsa -N '' -C b -f "$T/b_ecdsa" || fail "ssh-keygen rsa/ecdsa"
# made-up values, built at run time so the test's own source (copied into the hub) never holds one
R="$$$RANDOM"; V1="sk-share-ONE-$R"; V2="graf ana TWO-$R"; V3="sk-share-THREE-$R"; V4="sk-share-NEW-$R"
printf '%s\n' "$V1" | as "$HA" bin/keys set deepseek >/dev/null 2>&1 || fail "A stores deepseek"
printf '%s\n' "$V2" | as "$HA" bin/secret --set grafana-token >/dev/null 2>&1 || fail "A stores grafana-token"
printf '%s\n' "$V3" | as "$HA" bin/keys set glm >/dev/null 2>&1 || fail "A stores glm"
# bob's "GitHub keys": ed25519, rsa and ecdsa lines (only the first two are usable)
KF="$T/bob.keys"; { cut -d' ' -f1,2 "$HB/.ssh/id_ed25519.pub"; cut -d' ' -f1,2 "$T/b_rsa.pub"; cut -d' ' -f1,2 "$T/b_ecdsa.pub"; } > "$KF"
# each GitHub user's keys in $GHK/<user>.keys ({user}: a test-only placeholder, story I5)
GHK="$T/gh"; mkdir -p "$GHK"; cp "$KF" "$GHK/bob.keys"; export AGENT_GITHUB_KEYS_URL="$GHK/{user}.keys"
armor_only() { awk 'NR==1 && $0!="-----BEGIN AGE ENCRYPTED FILE-----"{bad=1} {last=$0} END{exit (bad || last!="-----END AGE ENCRYPTED FILE-----")}' "$1"; }

# forge <file> <line…>: a block sealed straight with age to B's ssh key, its plaintext written by the test (not bin/keys)
forge() { local f="$1"; shift; printf '%s\n' "$@" | "$REAL_AGE" -a -R "$HB/.ssh/id_ed25519.pub" > "$f" || fail "forge $f"; }
iso() { python3 -c 'import sys, time; print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(int(sys.argv[1]))))' "$1"; }
HUBN="$(basename "$HUB")"
# on_pty <out> <cmd…>: run it on a pseudo-terminal (stdin and stderr there), send Ctrl-D, keep what it wrote
on_pty() { local o="$1"; shift; python3 -c 'import os, pty, sys, time
pid, fd = pty.fork()
if pid == 0: os.execvp(sys.argv[2], sys.argv[2:])
time.sleep(1); os.write(fd, b"\x04"); out = b""
while True:
    try: b = os.read(fd, 4096)
    except OSError: break
    if not b: break
    out += b
open(sys.argv[1], "wb").write(out); os.waitpid(pid, 0)' "$o" "$@"; }

ac1_share_receive_ssh() {
  echo y | as "$HA" bin/keys share bob deepseek grafana-token glm > "$T/b1" 2> "$T/e1"; assert_eq "$?" 0 "share to bob: $(cat "$T/e1")"
  armor_only "$T/b1" || fail "stdout is the armored block alone: $(cat "$T/b1")"
  echo y | as "$HB" bin/keys receive "$T/b1" > "$T/o1r" 2> "$T/e1r"; assert_eq "$?" 0 "receive: $(cat "$T/e1r")"
  assert_eq "$(as "$HB" bin/secret deepseek-api-key)" "$V1" "deepseek's value arrived"
  assert_eq "$(as "$HB" bin/secret grafana-token)" "$V2" "a secret with spaces arrived"
  assert_eq "$(as "$HB" bin/secret zai-api-key)" "$V3" "glm's value arrived"
  grep -q "deepseek-api-key" "$T/e1r" && grep -q "grafana-token" "$T/e1r" || fail "receive lists the names stored: $(cat "$T/e1r")"
}
ac2_github_user() {
  local f1 f2 f3 f4; f1="$(ssh-keygen -lf "$HB/.ssh/id_ed25519.pub" | cut -d' ' -f2)"; f2="$(ssh-keygen -lf "$T/b_rsa.pub" | cut -d' ' -f2)"; f3="$(ssh-keygen -lf "$T/b_ecdsa.pub" | cut -d' ' -f2)"
  grep -qF "$f1" "$T/e1" && grep -qF "$f2" "$T/e1" || fail "the ed25519 and rsa fingerprints are shown: $(cat "$T/e1")"
  grep -qF "$f3" "$T/e1" && fail "the ecdsa key is not used"
  grep -q -- "-r ecdsa-" "$LOG" && fail "an ecdsa key reached age"
  cut -d' ' -f1,2 "$T/b_ecdsa.pub" > "$T/ecdsa-only.keys"
  echo y | AGENT_GITHUB_KEYS_URL="$T/ecdsa-only.keys" as "$HA" bin/keys share bob deepseek > "$T/o2a" 2> "$T/e2a"; assert_eq "$?" 1 "a user with no usable key is refused"
  assert_eq "$(cat "$T/o2a")" "" "nothing printed for a user with no usable key"; grep -q "no ssh-ed25519 or ssh-rsa" "$T/e2a" || fail "says why: $(cat "$T/e2a")"
  : > "$T/none.keys"; echo y | AGENT_GITHUB_KEYS_URL="$T/none.keys" as "$HA" bin/keys share bob deepseek > "$T/o2b" 2> "$T/e2b"; assert_eq "$?" 1 "a user with no keys is refused"
  assert_eq "$(cat "$T/o2b")" "" "nothing printed for a user with no keys"
  echo n | as "$HA" bin/keys share bob deepseek > "$T/o2c" 2> "$T/e2c"; assert_eq "$?" 1 "no at the prompt seals nothing"; assert_eq "$(cat "$T/o2c")" "" "nothing printed after no"
  as "$HA" bin/keys share bob deepseek < /dev/null > "$T/o2d" 2> "$T/e2d"; assert_eq "$?" 1 "no answer seals nothing"; assert_eq "$(cat "$T/o2d")" "" "nothing printed without an answer"
  # a file:// URL goes through curl (https and file only)
  echo y | AGENT_GITHUB_KEYS_URL="file://$KF" as "$HA" bin/keys share bob deepseek > "$T/o2e" 2> "$T/e2e"; assert_eq "$?" 0 "a file:// keys URL: $(cat "$T/e2e")"
  echo y | AGENT_GITHUB_KEYS_URL="http://127.0.0.1:9/bob.keys" as "$HA" bin/keys share bob deepseek > "$T/o2f" 2> "$T/e2f"; assert_eq "$?" 1 "an http:// keys URL is refused"
  grep -qi 'protocol.*disabled\|not supported' "$T/e2f" || fail "curl refuses http itself (--proto =https,file): $(cat "$T/e2f")"
  # an ssh-rsa key under 2048 bits is skipped with a note; none left: refused
  ssh-keygen -q -t rsa -b 1024 -N '' -C weak -f "$T/b_rsa1024" || fail "ssh-keygen rsa 1024"; f4="$(ssh-keygen -lf "$T/b_rsa1024.pub" | cut -d' ' -f2)"
  { cut -d' ' -f1,2 "$HB/.ssh/id_ed25519.pub"; cut -d' ' -f1,2 "$T/b_rsa1024.pub"; } > "$T/weak.keys"
  : > "$LOG"; echo y | AGENT_GITHUB_KEYS_URL="$T/weak.keys" as "$HA" bin/keys share bob deepseek > "$T/o2g" 2> "$T/e2g"; assert_eq "$?" 0 "share with one weak key: $(cat "$T/e2g")"
  grep -q "1024" "$T/e2g" && grep -qi "skip" "$T/e2g" || fail "the weak rsa key is skipped with a note: $(cat "$T/e2g")"
  grep -qF "$(cut -d' ' -f2 "$T/b_rsa1024.pub")" "$LOG" && fail "the weak rsa key reached age"
  cut -d' ' -f1,2 "$T/b_rsa1024.pub" > "$T/weak-only.keys"
  echo y | AGENT_GITHUB_KEYS_URL="$T/weak-only.keys" as "$HA" bin/keys share bob deepseek > "$T/o2h" 2> "$T/e2h"; assert_eq "$?" 1 "only a weak rsa key: refused"
  assert_eq "$(cat "$T/o2h")" "" "nothing printed when only a weak key is left"
}
ac3_receive_new() {
  as "$HC" bin/keys receive --new > "$T/pub" 2> "$T/e3a"; assert_eq "$?" 0 "receive --new: $(cat "$T/e3a")"
  grep -qE '^age1[0-9a-z]+$' "$T/pub" || fail "--new prints an age1 public key: $(cat "$T/pub")"
  assert_eq "$(fmode "$HC/.config/ade/age")" 700 "the identity folder is 0700"; assert_eq "$(fmode "$HC/.config/ade/age/key.txt")" 600 "the identity is 0600"
  as "$HC" bin/keys receive --new > "$T/pub2" 2> "$T/e3b"; assert_eq "$(cat "$T/pub2")" "$(cat "$T/pub")" "a second --new keeps the identity"
  echo y | as "$HA" bin/keys share "$(cat "$T/pub")" deepseek > "$T/b3" 2> "$T/e3c"; assert_eq "$?" 0 "share to an age1 key: $(cat "$T/e3c")"
  echo y | as "$HC" bin/keys receive "$T/b3" > "$T/o3d" 2> "$T/e3d"; assert_eq "$?" 0 "the --new identity opens it: $(cat "$T/e3d")"
  assert_eq "$(as "$HC" bin/secret deepseek-api-key)" "$V1" "value arrived through the age identity"
  # only X25519 age1 keys: a plugin recipient (age1<plugin>1…) is refused
  echo y | as "$HA" bin/keys share "age1yubikey1q$(printf 'q%.0s' $(seq 1 57))" deepseek > "$T/o3e" 2> "$T/e3e"; assert_eq "$?" 2 "a plugin age1 recipient is refused"
  assert_eq "$(cat "$T/o3e")" "" "nothing sealed for a plugin recipient"
}
ac4_refusals() {
  as "$HD" bin/keys receive --new > "$T/o4a" 2> "$T/e4a"
  echo y | as "$HD" bin/keys receive "$T/b1" > "$T/o4b" 2> "$T/e4b"; assert_eq "$?" 1 "a block for someone else is refused"
  grep -q "not sealed to your keys" "$T/e4b" || fail "says it is not theirs: $(cat "$T/e4b")"; assert_eq "$(as "$HD" bin/secret --list)" "" "nothing stored (someone else's)"
  grep -q -- "-i <identity>" "$T/e4b" || fail "the refusal suggests -i <identity>: $(cat "$T/e4b")"
  echo y | AGENT_KEYS_NOW=$(( $(date -u +%s) - 8 * 86400 )) as "$HA" bin/keys share bob deepseek > "$T/old" 2> "$T/e4c" || fail "share with an old clock"
  mkdir -p "$HE/.ssh"; cp "$HB/.ssh/id_ed25519" "$HE/.ssh/"
  echo y | as "$HE" bin/keys receive "$T/old" > "$T/o4d" 2> "$T/e4d"; assert_eq "$?" 1 "an expired block is refused"
  grep -q "expired" "$T/e4d" || fail "says expired: $(cat "$T/e4d")"; assert_eq "$(as "$HE" bin/secret --list)" "" "nothing stored (expired)"
  echo y | as "$HA" bin/keys share bob deepseek --days 31 > "$T/o4e" 2> "$T/e4e"; assert_eq "$?" 2 "--days over 30 is refused"
  printf 'HUB_SECRET_STORE=file\nHUB_NAME=elsewhere\n' > hub.conf
  echo y | as "$HE" bin/keys receive "$T/b1" > "$T/o4f" 2> "$T/e4f"; assert_eq "$?" 1 "a block for another hub is refused"
  grep -q "another hub\|for hub" "$T/e4f" || fail "says which hub: $(cat "$T/e4f")"; assert_eq "$(as "$HE" bin/secret --list)" "" "nothing stored (other hub)"
  echo y | as "$HE" bin/keys receive --any-hub "$T/b1" > "$T/o4g" 2> "$T/e4g"; assert_eq "$?" 0 "--any-hub takes it: $(cat "$T/e4g")"
  assert_eq "$(as "$HE" bin/secret zai-api-key)" "$V3" "--any-hub stored it in this hub's store"
  printf 'HUB_SECRET_STORE=file\n' > hub.conf
  mkdir -p projects/x; cut -d' ' -f1,2 "$HB/.ssh/id_ed25519.pub" > projects/x/key.pub; cp projects/x/key.pub k
  for r in projects/x/key.pub ./k k projects; do echo y | as "$HA" bin/keys share "$r" deepseek > "$T/o4h" 2> "$T/e4h"; assert_eq "$?" 2 "a path recipient ($r) is refused"
    assert_eq "$(cat "$T/o4h")" "" "nothing sealed for a path ($r)"; done
  rm -rf projects/x k
  echo y | as "$HA" bin/keys share bob no-such-secret > "$T/o4i" 2> "$T/e4i"; assert_eq "$?" 1 "an unknown name is refused"; assert_eq "$(cat "$T/o4i")" "" "nothing sealed (unknown name)"
  echo y | as "$HB" bin/keys receive "$T/none.keys" > "$T/o4j" 2> "$T/e4j"; assert_eq "$?" 1 "a file that is no block is refused"
  # the block's times: expires over 30 days after time, time in the future, expires before time
  local now; now="$(date -u +%s)"
  forge "$T/f30" "ade-keys-share 1" "hub: $HUBN" "from: x" "to: bob" "time: $(iso "$now")" "expires: $(iso $((now + 31 * 86400)))" "secret forged-a $V4" end
  forge "$T/ffut" "ade-keys-share 1" "hub: $HUBN" "from: x" "to: bob" "time: $(iso $((now + 3600)))" "expires: $(iso $((now + 7200)))" "secret forged-a $V4" end
  forge "$T/fback" "ade-keys-share 1" "hub: $HUBN" "from: x" "to: bob" "time: $(iso "$now")" "expires: $(iso $((now - 60)))" "secret forged-a $V4" end
  forge "$T/fback2" "ade-keys-share 1" "hub: $HUBN" "from: x" "to: bob" "time: $(iso $((now + 200)))" "expires: $(iso $((now + 100)))" "secret forged-a $V4" end
  for f in f30 ffut fback2; do echo y | as "$HE" bin/keys receive "$T/$f" > "$T/o4$f" 2> "$T/e4$f"; assert_eq "$?" 1 "a block with bad times ($f) is refused: $(cat "$T/e4$f")"
    as "$HE" bin/secret --has forged-a && fail "a block with bad times ($f) stored a key"; done
  grep -q "30 days" "$T/e4f30" || fail "says the expiry is too far: $(cat "$T/e4f30")"
  grep -q "future" "$T/e4ffut" || fail "says the time is in the future: $(cat "$T/e4ffut")"
  grep -q "before" "$T/e4fback2" || fail "says it expires before it was sealed: $(cat "$T/e4fback2")"
  # default identities: ~/.ssh/id_rsa only with its id_rsa.pub
  cp "$T/b_rsa" "$HE/.ssh/id_rsa"; : > "$LOG"; echo y | as "$HE" bin/keys receive "$T/b1" > "$T/o4k" 2> "$T/e4k"
  grep -q "\.ssh/id_rsa" "$LOG" && fail "id_rsa without id_rsa.pub was tried: $(cat "$LOG")"
  cp "$T/b_rsa.pub" "$HE/.ssh/id_rsa.pub"; : > "$LOG"; echo y | as "$HE" bin/keys receive "$T/b1" > "$T/o4l" 2> "$T/e4l"
  grep -q "\.ssh/id_rsa" "$LOG" || fail "id_rsa with id_rsa.pub is tried: $(cat "$LOG")"
}
ac4b_confirm_before_storing() {
  # a forged block: any from:, a name the person never had; no answer stores nothing, y stores it
  local now; now="$(date -u +%s)"
  forge "$T/fnew" "ade-keys-share 1" "hub: $HUBN" "from: the-owner" "to: bob" "time: $(iso "$now")" "expires: $(iso $((now + 86400)))" "secret anthropic-api-key $V4" end
  as "$HB" bin/keys receive "$T/fnew" < /dev/null > "$T/o4m" 2> "$T/e4m"; assert_eq "$?" 1 "no answer: nothing stored, non-zero"
  as "$HB" bin/secret --has anthropic-api-key && fail "a forged block stored a new key without a yes"
  grep -q "not verified" "$T/e4m" || fail "the summary marks the sender not verified: $(cat "$T/e4m")"
  grep -q "anthropic-api-key.*new" "$T/e4m" || fail "the summary marks the name new: $(cat "$T/e4m")"
  grep -q "store these" "$T/e4m" || fail "asks once before storing: $(cat "$T/e4m")"
  echo n | as "$HB" bin/keys receive "$T/fnew" > "$T/o4n" 2> "$T/e4n"; assert_eq "$?" 1 "n: nothing stored, non-zero"
  as "$HB" bin/secret --has anthropic-api-key && fail "n stored a key"
  echo y | as "$HB" bin/keys receive "$T/fnew" > "$T/o4o" 2> "$T/e4o"; assert_eq "$?" 0 "y stores it: $(cat "$T/e4o")"
  assert_eq "$(as "$HB" bin/secret anthropic-api-key)" "$V4" "y stored the forged key"
  as "$HB" bin/secret --forget anthropic-api-key 2>/dev/null
  # an existing name is marked replace in the summary
  printf 'y\nn\n' | as "$HB" bin/keys receive "$T/b1" > "$T/o4p" 2> "$T/e4p"
  grep -q "deepseek-api-key.*replace" "$T/e4p" || fail "the summary marks a stored name replace: $(cat "$T/e4p")"
}
ac5_replace_asks() {
  printf '%s\n' "$V4" | as "$HA" bin/keys set deepseek >/dev/null 2>&1
  echo y | as "$HA" bin/keys share bob deepseek > "$T/b5" 2> "$T/e5a" || fail "share the new value"
  printf 'y\nn\n' | as "$HB" bin/keys receive "$T/b5" > "$T/o5b" 2> "$T/e5b"; assert_eq "$?" 0 "receive, answering no to the replace"
  grep -q "replace it" "$T/e5b" || fail "asks before replacing: $(cat "$T/e5b")"; assert_eq "$(as "$HB" bin/secret deepseek-api-key)" "$V1" "no keeps the old value"
  as "$HB" bin/keys receive "$T/b5" < /dev/null > "$T/o5c" 2> "$T/e5c"; assert_eq "$(as "$HB" bin/secret deepseek-api-key)" "$V1" "no answer keeps the old value"
  HOME="$HB" no_tty bin/keys receive < "$T/b5" > "$T/o5d" 2> "$T/e5d"; assert_eq "$(as "$HB" bin/secret deepseek-api-key)" "$V1" "a block on stdin, no terminal: keeps the old value"
  printf 'y\ny\n' | as "$HB" bin/keys receive "$T/b5" > "$T/o5e" 2> "$T/e5e"; assert_eq "$(as "$HB" bin/secret deepseek-api-key)" "$V4" "yes replaces it"
}
# --- story I5: the block is signed by its sender (ssh-keygen -Y sign, namespace ade-keys); receive checks it ---
fpr() { ssh-keygen -lf "$1" | cut -d' ' -f2; }
# sforge <out> <key> <namespace> <signed> <shown>: a v2 block signed by the test (not bin/keys) over <signed>, holding
# <shown> before the signature, sealed to B (both printf %b strings: \n, \0000)
sforge() { local sig; sig="$(printf '%b' "$4" | "$REAL_SK" -Y sign -f "$2" -n "$3" 2>/dev/null)" || fail "sign $1"
  { printf '%b' "$5"; printf '%s\n' "$sig"; } | "$REAL_AGE" -a -R "$HB/.ssh/id_ed25519.pub" > "$1" || fail "seal $1"; }
# vhead <signer>: a v2 header, sealed now to bob, for a day
vhead() { local now; now="$(date -u +%s)"; printf 'ade-keys-share 2\\nhub: %s\\nfrom: x\\nsigner: %s\\nto: bob\\ntime: %s\\nexpires: %s\\n' "$HUBN" "$1" "$(iso "$now")" "$(iso $((now + 86400)))"; }
i5_hermetic() {
  # fix 3: under AGENT_PLATFORM_TEST=1 with no AGENT_GITHUB_KEYS_URL, nothing is fetched
  : > "$CLOG"; echo n | env -u AGENT_GITHUB_KEYS_URL HOME="$HA" bin/keys share bob deepseek > "$T/oh1" 2> "$T/eh1"; assert_eq "$?" 1 "no keys URL in a test: refused"
  grep -q "github.com" "$CLOG" && fail "a test run fetched from github.com: $(cat "$CLOG")"
  # fix 4: a keys file over 1 MiB is refused by curl; redirects only to https
  head -c 1100000 /dev/zero | tr '\0' 'a' > "$T/big.keys"
  echo y | AGENT_GITHUB_KEYS_URL="file://$T/big.keys" as "$HA" bin/keys share bob deepseek > "$T/oh2" 2> "$T/eh2"; assert_eq "$?" 1 "a keys file over 1 MiB is refused"
  grep -q -- "--max-filesize 1048576" "$CLOG" && grep -q -- "--proto-redir =https" "$CLOG" || fail "curl gets --max-filesize and --proto-redir: $(cat "$CLOG")"
}
i5_ac1_signed() {
  mkdir -p "$HA/.ssh"; ssh-keygen -q -t ed25519 -N '' -C a -f "$HA/.ssh/id_ed25519" || fail "ssh-keygen alice"
  cut -d' ' -f1,2 "$HA/.ssh/id_ed25519.pub" > "$GHK/alice.keys"; FA="$(fpr "$HA/.ssh/id_ed25519.pub")"
  ssh-keygen -q -t ed25519 -N '' -C c -f "$T/c_ed25519" || fail "ssh-keygen carol"; cut -d' ' -f1,2 "$T/c_ed25519.pub" > "$GHK/carol.keys"
  mkdir -p "$HF/.ssh" "$HG/.ssh"; cp "$HB/.ssh/id_ed25519" "$HB/.ssh/id_ed25519.pub" "$HF/.ssh/"; cp "$HB/.ssh/id_ed25519" "$HB/.ssh/id_ed25519.pub" "$HG/.ssh/"
  echo y | as "$HA" bin/keys share bob deepseek grafana-token --as alice > "$T/s1" 2> "$T/es1"; assert_eq "$?" 0 "signed share: $(cat "$T/es1")"
  armor_only "$T/s1" || fail "a signed share prints the armored block alone: $(cat "$T/s1")"
  grep -qF "$FA" "$T/es1" || fail "share shows the signing key's fingerprint: $(cat "$T/es1")"
  echo y | as "$HF" bin/keys receive "$T/s1" > "$T/os1" 2> "$T/ers1"; assert_eq "$?" 0 "signed receive: $(cat "$T/ers1")"
  grep -qF "from:    alice (verified: signed by $FA)" "$T/ers1" || fail "B sees verified with A's fingerprint: $(cat "$T/ers1")"
  assert_eq "$(as "$HF" bin/secret deepseek-api-key)" "$V4" "a signed block's value arrived"
  assert_eq "$(as "$HF" bin/secret grafana-token)" "$V2" "a signed block's value with spaces arrived"
  # the sender's user from gh when --as is not given
  local G="$T/fake-gh"; mkdir -p "$G"; printf '#!/bin/sh\n[ "$1 $2" = "api user" ] && echo alice\n' > "$G/gh"; chmod +x "$G/gh"
  echo y | PATH="$G:$PATH" as "$HA" bin/keys share bob deepseek > "$T/s1g" 2> "$T/es1g"; assert_eq "$?" 0 "signed share, user from gh: $(cat "$T/es1g")"
  echo n | as "$HG" bin/keys receive "$T/s1g" > "$T/os1g" 2> "$T/ers1g"
  grep -qF "from:    alice (verified: signed by $FA)" "$T/ers1g" || fail "the user came from gh: $(cat "$T/ers1g")"
}
i5_share_checks_key() {
  # fix 2: share signs only with a key the signer publishes; -i a key alice does not publish: refused, says which
  ssh-keygen -q -t ed25519 -N '' -C other -f "$T/a_other" || fail "ssh-keygen other"
  echo y | as "$HA" bin/keys share bob deepseek -i "$T/a_other" --as alice > "$T/ok1" 2> "$T/ek1"; assert_eq "$?" 1 "-i with a key alice does not publish: refused"
  assert_eq "$(cat "$T/ok1")" "" "nothing sealed (-i not published)"
  grep -qF "$(fpr "$T/a_other.pub")" "$T/ek1" && grep -q "alice" "$T/ek1" || fail "says which key and user: $(cat "$T/ek1")"
  echo y | as "$HA" bin/keys share bob deepseek -i "$T/a_other" --as nobody-here > "$T/ok1b" 2> "$T/ek1b"; assert_eq "$?" 1 "-i and the signer's keys unreadable: refused"
  # the default key, not published by the user: a warning, sealed unsigned
  echo y | as "$HA" bin/keys share bob deepseek --as carol > "$T/sk2" 2> "$T/ek2"; assert_eq "$?" 0 "default key not published: sealed: $(cat "$T/ek2")"
  grep -q "unsigned" "$T/ek2" || fail "warns it is unsigned: $(cat "$T/ek2")"
  echo n | as "$HG" bin/keys receive "$T/sk2" > "$T/okr2" 2> "$T/ekr2"; grep -q "not verified" "$T/ekr2" || fail "shows not verified: $(cat "$T/ekr2")"
  # --unsigned: no signature, no gh, no key check
  : > "$SKLOG"; echo y | as "$HA" bin/keys share bob deepseek --unsigned > "$T/sk3" 2> "$T/ek3"; assert_eq "$?" 0 "--unsigned: $(cat "$T/ek3")"
  grep -q -- "-Y sign" "$SKLOG" && fail "--unsigned signed"
  echo n | as "$HG" bin/keys receive "$T/sk3" > "$T/okr3" 2> "$T/ekr3"; grep -q "not verified" "$T/ekr3" || fail "--unsigned shows not verified: $(cat "$T/ekr3")"
  # a passphrase key with no agent and no terminal: signing fails, the error names --unsigned
  ssh-keygen -q -t ed25519 -N 'pass-phrase-x' -C d -f "$T/d_ed25519" || fail "ssh-keygen dave"; cut -d' ' -f1,2 "$T/d_ed25519.pub" > "$GHK/dave.keys"
  echo y | no_tty env -u SSH_AUTH_SOCK -u SSH_ASKPASS -u DISPLAY HOME="$HA" bin/keys share bob deepseek -i "$T/d_ed25519" --as dave > "$T/ok4" 2> "$T/ek4"; assert_eq "$?" 1 "a passphrase key with no agent: nothing sealed"
  assert_eq "$(cat "$T/ok4")" "" "nothing printed (passphrase)"; grep -q -- "--unsigned" "$T/ek4" || fail "the error names --unsigned: $(cat "$T/ek4")"
  # fix 4: a gh that hangs is cut off; the block is sealed unsigned
  local G="$T/slow-gh" t0; mkdir -p "$G"; printf '#!/bin/sh\nsleep 60\n' > "$G/gh"; chmod +x "$G/gh"; t0="$(date +%s)"
  echo y | PATH="$G:$PATH" as "$HA" bin/keys share bob deepseek > "$T/sk5" 2> "$T/ek5"; assert_eq "$?" 0 "a hanging gh: $(cat "$T/ek5")"
  [ $(( $(date +%s) - t0 )) -lt 30 ] || fail "gh api user is cut off by a timeout"
}
i5_ac2_tampered() {
  "$REAL_AGE" -d -i "$HB/.ssh/id_ed25519" "$T/s1" | sed "s/^secret grafana-token .*/secret grafana-token $V4/" | "$REAL_AGE" -a -R "$HB/.ssh/id_ed25519.pub" > "$T/s2" || fail "re-seal a changed block"
  "$REAL_AGE" -d -i "$HB/.ssh/id_ed25519" "$T/s1" | sed "s/^to: bob$/to: eve/" | "$REAL_AGE" -a -R "$HB/.ssh/id_ed25519.pub" > "$T/s2b" || fail "re-seal a changed header"
  for f in s2 s2b; do echo y | as "$HG" bin/keys receive "$T/$f" > "$T/o$f" 2> "$T/e$f"; assert_eq "$?" 1 "a block changed after signing ($f) is refused"
    grep -q "refused" "$T/e$f" || fail "says refused ($f): $(cat "$T/e$f")"; assert_eq "$(as "$HG" bin/secret --list)" "" "nothing stored ($f)"; done
}
i5_ac3_unpublished_key() {
  local D; D="$(vhead alice)secret forged-b forged-$R\nend\n"
  sforge "$T/s3" "$T/a_other" ade-keys "$D" "$D"
  echo y | as "$HG" bin/keys receive "$T/s3" > "$T/os3" 2> "$T/ers3"; assert_eq "$?" 1 "a key alice does not publish is refused"
  grep -q "refused" "$T/ers3" || fail "says refused: $(cat "$T/ers3")"; assert_eq "$(as "$HG" bin/secret --list)" "" "nothing stored (unpublished key)"
  echo y | AGENT_GITHUB_KEYS_URL="$T/no-such.keys" as "$HG" bin/keys receive "$T/s1" > "$T/os3b" 2> "$T/ers3b"; assert_eq "$?" 1 "the signer's keys cannot be read: refused"
  assert_eq "$(as "$HG" bin/secret --list)" "" "nothing stored (keys unreadable)"
  echo y | as "$HA" bin/keys share bob deepseek -i "$T/no-such-key" --as alice > "$T/os3c" 2> "$T/es3c"; assert_eq "$?" 1 "share with a missing -i key: nothing sealed"
  assert_eq "$(cat "$T/os3c")" "" "nothing printed for a missing -i key"
}
i5_ac4_from() {
  echo y | as "$HA" bin/keys share bob deepseek -i "$T/c_ed25519" --as carol > "$T/s4" 2> "$T/es4"; assert_eq "$?" 0 "carol signs: $(cat "$T/es4")"
  echo n | as "$HG" bin/keys receive "$T/s4" > "$T/os4a" 2> "$T/ers4a"
  grep -qF "from:    carol (verified: signed by $(fpr "$T/c_ed25519.pub"))" "$T/ers4a" || fail "carol's block verifies as carol: $(cat "$T/ers4a")"
  echo y | as "$HG" bin/keys receive --from alice "$T/s4" > "$T/os4" 2> "$T/ers4"; assert_eq "$?" 1 "--from alice refuses carol's block"
  grep -q "refused.*alice" "$T/ers4" || fail "says it is not from alice: $(cat "$T/ers4")"; assert_eq "$(as "$HG" bin/secret --list)" "" "nothing stored (--from)"
  echo y | as "$HG" bin/keys receive --from alice "$T/b1" > "$T/os4b" 2> "$T/ers4b"; assert_eq "$?" 1 "--from alice refuses an unsigned block"
  assert_eq "$(as "$HG" bin/secret --list)" "" "nothing stored (--from, unsigned)"
  echo y | as "$HG" bin/keys receive --from alice "$T/s1" > "$T/os4c" 2> "$T/ers4c"; assert_eq "$?" 0 "--from alice takes alice's block: $(cat "$T/ers4c")"
  as "$HG" bin/secret --forget deepseek-api-key 2>/dev/null; as "$HG" bin/secret --forget grafana-token 2>/dev/null
}
i5_forwarded() {
  # fix 1: bob reseals alice's block (to: bob) to carol's age key; carol is refused even with --from alice
  "$REAL_AGE" -d -i "$HB/.ssh/id_ed25519" "$T/s1" | "$REAL_AGE" -a -r "$(cat "$T/pub")" > "$T/s1fwd" || fail "reseal to carol"
  echo y | as "$HC" bin/keys receive --from alice "$T/s1fwd" > "$T/ofw" 2> "$T/efw"; assert_eq "$?" 1 "a block forwarded to carol is refused"
  grep -q "refused.*bob" "$T/efw" || fail "says it was sent to bob: $(cat "$T/efw")"
  as "$HC" bin/secret --has grafana-token && fail "a forwarded block stored a key"
  assert_eq "$(as "$HC" bin/secret deepseek-api-key)" "$V1" "a forwarded block left carol's key alone"
  echo n | as "$HC" bin/keys receive --from alice --any-to "$T/s1fwd" > "$T/ofw2" 2> "$T/efw2"; assert_eq "$?" 1 "--any-to, then no: nothing stored"
  grep -q "sent to bob, not you" "$T/efw2" || fail "--any-to warns before the confirm: $(cat "$T/efw2")"
  as "$HC" bin/secret --has grafana-token && fail "--any-to and no stored a key"
  # an age1 to: is the receiver when an identity's public key is that key; the summary says how old the block is
  echo y | AGENT_KEYS_NOW=$(( $(date -u +%s) - 3 * 86400 - 60 )) as "$HA" bin/keys share "$(cat "$T/pub")" glm --as alice > "$T/s1age" 2> "$T/es1age"; assert_eq "$?" 0 "signed share to an age key: $(cat "$T/es1age")"
  echo n | as "$HC" bin/keys receive "$T/s1age" > "$T/oag" 2> "$T/eag"
  grep -q "verified" "$T/eag" && grep -q "store these" "$T/eag" || fail "an age1 to: that is carol's opens: $(cat "$T/eag")"
  grep -q "not you" "$T/eag" && fail "carol's own age key is not 'not you': $(cat "$T/eag")"
  grep -q "sealed 3 day(s) ago" "$T/eag" || fail "the summary says the block's age: $(cat "$T/eag")"
}
i5_strict_bytes() {
  # fix 5: what is shown is what was signed: an empty line or a NUL added after signing is refused
  local H D; H="$(vhead alice)"; D="${H}secret forged-b forged-$R\nend\n"
  sforge "$T/f5ok" "$HA/.ssh/id_ed25519" ade-keys "$D" "$D"
  echo n | as "$HG" bin/keys receive "$T/f5ok" > "$T/of5" 2> "$T/ef5"; grep -q "verified" "$T/ef5" || fail "a test-signed block verifies: $(cat "$T/ef5")"
  sforge "$T/f5blank" "$HA/.ssh/id_ed25519" ade-keys "$D" "${H}\nsecret forged-b forged-$R\nend\n"
  sforge "$T/f5nul" "$HA/.ssh/id_ed25519" ade-keys "$D" "${H}secret forged-b forged-\0000$R\nend\n"
  # fix 7: another namespace is refused; a v1 block with a signer: line is refused
  sforge "$T/f7ns" "$HA/.ssh/id_ed25519" git "$D" "$D"
  local now; now="$(date -u +%s)"
  forge "$T/f7v1" "ade-keys-share 1" "hub: $HUBN" "from: x" "signer: alice" "to: bob" "time: $(iso "$now")" "expires: $(iso $((now + 86400)))" "secret forged-b forged-$R" end
  for f in f5blank f5nul f7ns f7v1; do echo y | as "$HG" bin/keys receive "$T/$f" > "$T/o$f" 2> "$T/e$f"; assert_eq "$?" 1 "$f is refused: $(cat "$T/e$f")"
    as "$HG" bin/secret --has forged-b && fail "$f stored a key"; done
  # fix 7: allowed_signers binds the signer, by name, to each key (the files ssh-keygen was given)
  grep -h 'namespaces=' "$SEEN"/* | grep -q '^alice namespaces="ade-keys" ssh-ed25519 ' || fail "allowed_signers names alice: $(grep -h 'namespaces=' "$SEEN"/* | head -3)"
  grep -h 'namespaces=' "$SEEN"/* | grep -vE '^[A-Za-z0-9][A-Za-z0-9-]* namespaces="ade-keys" (ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)) [A-Za-z0-9+/]+=*$' | grep -q . &&
    fail "an allowed_signers line binds anything but one signer: $(grep -h 'namespaces=' "$SEEN"/* | head -3)"
}
i5_trap() {
  # fix 6: a TERM during the check leaves no temp folder (an ssh-keygen that kills bin/keys while verifying)
  local K="$T/killer" TT="$T/trap-tmp"; mkdir -p "$K" "$TT"
  printf '#!/bin/bash\ncase "$*" in *"-Y verify"*) p=$PPID; top=""; while [ "$p" -gt 1 ]; do c="$(ps -o command= -p "$p")"; case "$c" in *"bin/keys receive"*) top=$p ;; esac; p="$(ps -o ppid= -p "$p" | tr -d " ")"; done; kill -TERM "$top"; sleep 1; exit 1 ;; esac\nexec %q "$@"\n' "$REAL_SK" > "$K/ssh-keygen"; chmod +x "$K/ssh-keygen"
  echo y | TMPDIR="$TT" PATH="$K:$PATH" as "$HG" bin/keys receive "$T/s1" > "$T/otr" 2> "$T/etr"; assert_eq "$?" 143 "TERM during the check: killed"
  [ -z "$(ls "$TT")" ] || fail "a TERM left a temp folder: $(ls "$TT")"
  assert_eq "$(as "$HG" bin/secret --list)" "" "nothing stored (TERM)"
}
i5_ac5_unsigned() {
  # $T/b1 was sealed by bin/keys before A had a key: unsigned, as I4
  as "$HG" bin/keys receive "$T/b1" < /dev/null > "$T/os5" 2> "$T/ers5"; assert_eq "$?" 1 "an unsigned block, no answer: nothing stored"
  grep -q "not verified" "$T/ers5" && grep -q "store these" "$T/ers5" || fail "an unsigned block shows not verified and asks: $(cat "$T/ers5")"
  echo y | as "$HG" bin/keys receive "$T/b1" > "$T/os5b" 2> "$T/ers5b"; assert_eq "$?" 0 "an unsigned block still opens: $(cat "$T/ers5b")"
  # A has a key but no GitHub user (no --as, gh not signed in): sealed unsigned, with a note
  echo y | as "$HA" bin/keys share bob deepseek > "$T/s5" 2> "$T/es5"; assert_eq "$?" 0 "share with no user: $(cat "$T/es5")"
  grep -q "unsigned" "$T/es5" || fail "share says the block is unsigned: $(cat "$T/es5")"
  echo n | as "$HG" bin/keys receive "$T/s5" > "$T/os5c" 2> "$T/ers5c"; grep -q "not verified" "$T/ers5c" || fail "shows not verified: $(cat "$T/ers5c")"
}
i5_ac6_signing_tools() {
  grep -q -- "-Y sign .*-n ade-keys" "$SKLOG" && grep -q -- "-Y verify .*-n ade-keys" "$SKLOG" || fail "ssh-keygen signed and verified (namespace ade-keys): $(cat "$SKLOG")"
  ls "$SEEN" | grep -q . || fail "the ssh-keygen wrapper kept the files it was given"
}
ac6_hygiene() {
  # an inherited xtrace never prints a value; a block pasted on a terminal gets a prompt
  printf 'y\ny\n' | env SHELLOPTS=xtrace HOME="$HB" bin/keys receive "$T/b5" > "$T/o6a" 2> "$T/e6a"
  echo y | env SHELLOPTS=xtrace HOME="$HA" bin/keys share bob deepseek > "$T/o6b" 2> "$T/e6b"
  grep -q "keys: sealed 1 key" "$T/e6b" || fail "share runs under an inherited xtrace: $(head -c 300 "$T/e6b")"
  leaks "$T" && fail "an inherited xtrace printed a value"
  on_pty "$T/o6c" env HOME="$HB" bin/keys receive
  grep -q "paste the block, then Ctrl-D" "$T/o6c" || fail "on a terminal receive says how to paste: $(cat "$T/o6c")"
}
# leaks <dir>: the files under it that hold a value (exit 0 when any)
leaks() { local v; for v in "$V1" "$V2" "$V3" "$V4"; do grep -rlF -- "$v" "$1" 2>/dev/null; done | grep -q .; }
ac6_no_value_leaks() {
  local v h
  [ -s "$LOG" ] || fail "the fake age was used"
  grep -q -- "-a -r ssh-ed25519" "$LOG" && grep -q -- "-d -i " "$LOG" || fail "the fake age saw share and receive: $(cat "$LOG")"
  # every captured stdout and stderr (blocks are age armor), and the recorded argv
  leaks "$T" && fail "a value in output or argv: $(for v in "$V1" "$V2" "$V3" "$V4"; do grep -rlF -- "$v" "$T"; done)"
  for h in "$HA" "$HB" "$HC" "$HD" "$HE"; do for v in "$V1" "$V2" "$V3" "$V4"; do
    grep -rlF -- "$v" "$h" 2>/dev/null | grep -v "^$h/.config/ade/secrets/" | grep -q . && fail "a value in a file under $h outside the store"; done; done
  for v in "$V1" "$V2" "$V3" "$V4"; do git grep --untracked -qF -- "$v" && fail "a value in the hub (git grep)"; done
  # the scan catches a value printed after the replace prompt (a leaky copy of bin/keys, outputs outside $T)
  local M; M="$(mktemp -d)"
  sed 's/^\( *ask || { kept="\$kept \$n"; continue; }; fi\)$/\1; printf "%s\\n" "${vals[$i]}" >\&2/' bin/keys > bin/keys-leaky; chmod +x bin/keys-leaky
  grep -q 'vals\[\$i\]}" >&2' bin/keys-leaky || { rm -f bin/keys-leaky; fail "could not make the leaky copy"; }
  printf 'y\ny\n' | as "$HB" bin/keys-leaky receive "$T/b5" > "$M/o" 2> "$M/e"; rm -f bin/keys-leaky
  leaks "$M" || fail "the scan misses a value printed after the replace prompt: $(cat "$M/e")"; rm -rf "$M"
}
ac7_doctor_and_setup() {
  local NS c; NS="$T/noage"; mkdir -p "$NS"
  for c in bash sh dirname basename sed grep awk tr cat cut head tail date uname id python3 git stat readlink ls mkdir chmod sort wc ln rm env mktemp find; do
    command -v "$c" >/dev/null && ln -sf "$(command -v "$c")" "$NS/$c"; done
  PATH="$NS" DOCTOR_OFFLINE=1 bin/doctor > "$T/d" 2>&1; grep -E '^MISSING +age ' "$T/d" | grep -q "brew install age" || fail "doctor (macOS): age missing, with the brew line: $(cat "$T/d")"
  PATH="$NS" AGENT_PLATFORM=linux DOCTOR_OFFLINE=1 bin/doctor > "$T/d" 2>&1; grep -E '^MISSING +age ' "$T/d" | grep -q "apt-get install age" || fail "doctor (Linux): the apt line: $(grep age "$T/d")"
  DOCTOR_OFFLINE=1 bin/doctor > "$T/d" 2>&1; grep -qE '^OK +age ' "$T/d" || fail "doctor: age OK when installed: $(grep age "$T/d")"
  PATH="$NS" bin/setup > /dev/null 2> "$T/e7"; grep -q "age.*brew install age" "$T/e7" || fail "setup warns that age is missing: $(cat "$T/e7")"
  PATH="$NS" as "$HA" bin/keys share bob deepseek < /dev/null > "$T/o7" 2> "$T/e7b"; assert_eq "$?" 1 "share without age"; grep -q "brew install age" "$T/e7b" || fail "share says how to install age"
  grep -q '^server_packages() { echo "git python3 tmux gh age ' bin/server || fail "bin/server install installs age"
}
i5_hermetic
ac1_share_receive_ssh; ac2_github_user; ac3_receive_new; ac4_refusals; ac4b_confirm_before_storing; ac5_replace_asks
i5_ac1_signed; i5_share_checks_key; i5_ac2_tampered; i5_ac3_unpublished_key; i5_ac4_from; i5_forwarded; i5_strict_bytes; i5_trap
i5_ac5_unsigned; i5_ac6_signing_tools
ac6_hygiene; ac6_no_value_leaks; ac7_doctor_and_setup
assert_contains README.md "bin/keys share" "README documents bin/keys share"; assert_contains docs/index.html "bin/keys share" "the docs page documents bin/keys share"
assert_contains .ade/context/keys-share.md "bin/keys share <new person>" "the I2 adopt text is recorded (AC8, deferred to I2)"
for d in README.md .ade/context/keys-share.md; do assert_contains "$d" "--from <github-user>" "$d documents receive --from (I5)"; done
assert_contains docs/index.html "--from &lt;github-user&gt;" "the docs page documents receive --from (I5)"
assert_contains .ade/context/keys-share.md "ade-keys-share 2" "the contract records the signed format (I5)"
for f in README.md .ade/context/keys-share.md; do assert_contains "$f" "--any-to" "$f names --any-to (I5)"; assert_contains "$f" "--unsigned" "$f names --unsigned (I5)"
  assert_contains "$f" "proves who signed it and for whom, not that it is the latest" "$f states the replay limit (I5)"; done
for d in README.md .ade/context/keys-share.md; do assert_contains "$d" "not verified" "$d says the sender is not verified"
  assert_contains "$d" "What this does not protect" "$d has the limits section"; done
echo ok
