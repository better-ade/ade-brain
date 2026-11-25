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
person() { local h; h="$(mktemp -d)/home"; mkdir -p "$h"; echo "$h"; }
HA="$(person)"; HB="$(person)"; HC="$(person)"; HD="$(person)"; HE="$(person)"
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
export AGENT_GITHUB_KEYS_URL="$KF"
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
ac1_share_receive_ssh; ac2_github_user; ac3_receive_new; ac4_refusals; ac4b_confirm_before_storing; ac5_replace_asks; ac6_hygiene; ac6_no_value_leaks; ac7_doctor_and_setup
assert_contains README.md "bin/keys share" "README documents bin/keys share"; assert_contains docs/index.html "bin/keys share" "the docs page documents bin/keys share"
assert_contains .ade/context/keys-share.md "bin/keys share <new person>" "the I2 adopt text is recorded (AC8, deferred to I2)"
for d in README.md .ade/context/keys-share.md; do assert_contains "$d" "not verified" "$d says the sender is not verified"
  assert_contains "$d" "What this does not protect" "$d has the limits section"; done
echo ok
