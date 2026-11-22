#!/bin/bash
# bin/secret: the hub's own store (a stub `security`), and since story H2 the hand-off to ade-secrets when it is installed
# (contract v1, pinned in tests/fixtures/ade-secrets/). bash tests/test_secret.sh [check ...] runs only the named checks.
# Every ade-secrets here is a fake that records its arguments; the real one, the Keychain, pass and the clipboard are never
# reached (tests/helpers.sh drops a real ade-secrets from PATH).
. "$(dirname "$0")/helpers.sh"
make_hub; cd "$HUB"
S="$(mktemp -d)"; S="$(cd "$S" && pwd -P)"; mkdir -p "$S/home" "$S/fake" "$S/nosec"
export HOME="$S/home"; ORIG_PATH="$PATH"
# an agent session's markers never reach these checks unless a check sets them (the tests may run inside Claude Code)
unset CLAUDECODE CLAUDE_CODE_CHILD_SESSION CLAUDE_PID CLAUDE_CODE_SESSION_ID CLAUDE_CODE_BRIDGE_SESSION_ID CLAUDE_PROJECT_DIR \
  CLAUDE_PLUGIN_ROOT CLAUDE_CODE_EXECPATH CLAUDE_CODE_SSE_PORT CLAUDE_CODE_ENTRYPOINT HUB_SECRETS FAKE_RC
trap 'chmod -R u+rwx "$S" 2>/dev/null; rm -rf "$S" "$(dirname "$HUB")" "$CLAUDE_HOME" "$(dirname "$AGENT_SYNC_LOG")" "$(dirname "$AGENT_SYNC_LOCK")" "$(dirname "$METHOD_FIXTURE")"' EXIT
FIX="$REPO/tests/fixtures/ade-secrets"

# the fake ade-secrets: argv logged to $S/ade.log; entries are names in $S/ade.names; `get` prints an obvious fake value.
# Like the real one, every command but get and --version refuses (exit 3) when an agent session's markers are set.
# FAKE_RC=<n>: every command exits n (list still prints its names first).
{ printf '#!/bin/bash\nL=%q; N=%q\n' "$S/ade.log" "$S/ade.names"; cat <<'EOF'
echo "ade-secrets $*" >> "$L"; touch "$N"
agent() { [ -n "${CLAUDECODE:-}${CLAUDE_CODE_CHILD_SESSION:-}" ]; }
refuse() { echo "ade-secrets: refused: an agent context (run it in your own terminal)" >&2; exit 3; }
case "${1:-}" in --version|version) [ -n "${FAKE_RC:-}" ] && exit "$FAKE_RC"; echo 0.3.0; exit 0 ;; esac
[ -z "${FAKE_RC:-}" ] || { [ "${1:-}" = list ] && cat "$N"; exit "$FAKE_RC"; }
case "${1:-}" in
  get|helper) agent && refuse; grep -qxF -- "$2" "$N" || { echo "ade-secrets: no entry named $2" >&2; exit 1; }
    printf '%s\n' "fixture-value-$2" ;;
  list) agent && refuse; cat "$N" ;;
  set) agent && refuse; grep -qxF -- "$2" "$N" || echo "$2" >> "$N"; echo "ade-secrets: stored $2" >&2 ;;
  forget) agent && refuse; grep -qxF -- "$2" "$N" || exit 1; grep -vxF -- "$2" "$N" > "$N.t"; mv "$N.t" "$N" ;;
  *) exit 2 ;;
esac
EOF
} > "$S/fake/ade-secrets"; chmod +x "$S/fake/ade-secrets"
# a PATH with every command of this machine except security and ade-secrets (no Keychain tool installed)
python3 - "$S/nosec" "$ORIG_PATH" <<'PY'
import os, sys
out, seen = sys.argv[1], set()
for d in sys.argv[2].split(":"):
    if not d or not os.path.isdir(d): continue
    for n in sorted(os.listdir(d)):
        p = os.path.join(d, n)
        if n in ("security", "ade-secrets") or n in seen or os.path.isdir(p) or not os.access(p, os.X_OK): continue
        seen.add(n); os.symlink(p, os.path.join(out, n))
PY
with_ade() { export PATH="$S/fake:$ORIG_PATH"; unset HUB_SECRETS; }       # ade-secrets installed (the fake)
no_ade() { export PATH="$ORIG_PATH"; unset HUB_SECRETS; }                 # not installed (helpers.sh dropped any real one)
names() { printf '%s\n' "$@" | grep . > "$S/ade.names"; }
# ade <cmd...>: run it with a fresh ade-secrets log; RC, OUT (stdout), ERR (stderr) and LOGGED (the calls)
ade() { : > "$S/ade.log"; "$@" > "$S/out" 2> "$S/err"; RC=$?; OUT="$(cat "$S/out")"; ERR="$(cat "$S/err")"; LOGGED="$(cat "$S/ade.log")"; }
fake_unused() { [ ! -s "$S/ade.log" ] || fail "$1: ade-secrets was called [$(cat "$S/ade.log")]"; }

# the hub's own store, as before story H2 (the checks this file had, unchanged)
existing_secret_checks() {
stub_security
printf 'pat-123\n' | bin/secret --set api-token 2>err || fail "set failed"
grep -q "pat-123" err && fail "set echoed the value"
assert_eq "$(bin/secret api-token)" "pat-123" "get returns the value"
bin/secret --has api-token || fail "--has after set"
# the value goes to security on stdin, so no logged argv holds it
grep -q "pat-123" "$STORE.argv" && fail "the value reached a security argument"
V='sk "quoted" back\\slash $HOME `x`'; printf '%s\n' "$V" | bin/secret --set odd 2>/dev/null || fail "set with shell characters"
assert_eq "$(bin/secret odd)" "$V" "a value with quotes, backslashes and dollars survives"
SECURITY_FAIL=1 bash -c "printf 'nope\n' | bin/secret --set failed" 2>err; assert_eq "$?" "1" "a failed store exits 1"; assert_contains err "could not store" "a failed store says so"
bin/secret --forget api-token 2>/dev/null; bin/secret --has api-token && fail "--has after forget"
bin/secret nope 2>err; assert_eq "$?" "1" "missing secret exits 1"; assert_contains err "not stored" "says how to store it"
printf '\n' | bin/secret --set empty 2>/dev/null; assert_eq "$?" "1" "empty value refused"
bin/secret >/dev/null 2>&1; assert_eq "$?" "2" "no args exits 2"
}

secret_block_matches_contract() {   # AC1
  local pinned ours n
  head -1 "$FIX/delegation-block.sh" | grep -q "better-ade/ade-secrets tag v0.3.0" || fail "the pinned block says which ade-secrets tag it came from"
  grep -q "tag v0.3.0" "$FIX/README.md" || fail "the fixtures README names the ade-secrets tag"
  pinned="$(sed -n '/^# >>> ade-secrets delegation/,/^# <<< ade-secrets delegation/p' "$FIX/delegation-block.sh")"
  ours="$(sed -n '/^# >>> ade-secrets delegation/,/^# <<< ade-secrets delegation/p' bin/secret)"
  [ -n "$pinned" ] || fail "the pinned block is empty"
  [ "$ours" = "$pinned" ] || fail "bin/secret's delegation block differs from the contract's: $(diff <(printf '%s\n' "$pinned") <(printf '%s\n' "$ours"))"
  [ "$(grep -c '^# >>> ade-secrets delegation' bin/secret)" = 1 ] || fail "one delegation block"
  n="$(grep -n '^set -u$' bin/secret | head -1 | cut -d: -f1)"; [ -n "$n" ] || fail "bin/secret has a set -u line of its own"
  [ "$(sed -n "$((n + 1))p" bin/secret)" = "$(printf '%s\n' "$pinned" | head -1)" ] || fail "the block comes right after the set -u line"
}

secret_delegates() {   # AC2
  local c; with_ade; stub_security; names
  ade bin/secret --set alpha < /dev/null
  assert_eq "$LOGGED" "ade-secrets set alpha --helper --kind api-key --used-by hub" "--set"; assert_eq "$RC" 0 "--set exit"
  case "$ERR" in *"value for"*) fail "the hub prompted for the value itself [$ERR]" ;; esac
  ade bin/secret --has alpha; assert_eq "$LOGGED" "ade-secrets list --names" "--has"; assert_eq "$RC:$OUT" "0:" "--has a stored name: 0, prints nothing"
  ade bin/secret --has alph; assert_eq "$RC" 1 "--has a missing name (a prefix of a stored one)"
  ade bin/secret alpha; assert_eq "$LOGGED" "ade-secrets get alpha" "a plain name"; assert_eq "$RC:$OUT" "0:fixture-value-alpha" "get"
  ade bin/secret --list; assert_eq "$LOGGED" "ade-secrets list --names" "--list"; assert_eq "$OUT" "alpha" "--list names"
  ade bin/secret --forget alpha; assert_eq "$LOGGED" "ade-secrets forget alpha" "--forget"; assert_eq "$RC" 0 "--forget exit"
  ade bin/secret --forget alpha; assert_eq "$RC" 1 "--forget a missing name: the exit comes through"
  ade bin/secret beta; assert_eq "$RC:$OUT" "1:" "get of a missing name: 1, nothing on stdout"
  for c in "--set x" "--has x" "--forget x" "--list" "x"; do
    FAKE_RC=5 ade bin/secret $c < /dev/null; assert_eq "$RC" 5 "bin/secret $c passes ade-secrets' exit code on"
    FAKE_RC=4 ade bin/secret $c < /dev/null; assert_eq "$RC" 4 "bin/secret $c passes ade-secrets' exit code on"; done
  names alpha; CLAUDECODE=1 ade bin/secret --has alpha; assert_eq "$RC" 3 "--has inside an agent session is a refusal (3), not missing"
  for c in "--set" "--has" "--forget"; do ade bin/secret $c; assert_eq "$RC" 2 "$c without a name"; fake_unused "$c without a name"; done
  ade bin/secret; assert_eq "$RC" 2 "no argument: the hub's usage"; fake_unused "no argument"
  ade bin/secret --bogus; assert_eq "$RC" 2 "an unknown flag: the hub's usage"; fake_unused "an unknown flag"
  [ ! -s "$STORE.argv" ] || fail "the Keychain was used while ade-secrets is installed [$(cat "$STORE.argv")]"
}

secret_builtin_unchanged() {   # AC3
  local r
  # HUB_SECRETS=builtin with ade-secrets installed, then no ade-secrets at all: the hub's own store, as before
  ( with_ade; export HUB_SECRETS=builtin; : > "$S/ade.log"; existing_secret_checks; fake_unused "HUB_SECRETS=builtin" ) || exit 1
  ( no_ade; command -v ade-secrets >/dev/null && fail "an ade-secrets is on PATH"; existing_secret_checks ) || exit 1
  : > "$S/ade.log"
  r="$(ADE_SECRETS_FAKE_DIR="$S/fake" PATH="$S/fake:$ORIG_PATH" HUB_SECRETS=builtin bash "$REPO/tests/test_keys.sh" 2>&1 | tail -3)"
  assert_eq "$(printf '%s\n' "$r" | tail -1)" ok "tests/test_keys.sh with HUB_SECRETS=builtin and ade-secrets installed [$r]"
  fake_unused "tests/test_keys.sh with HUB_SECRETS=builtin"
  r="$(PATH="$ORIG_PATH" bash "$REPO/tests/test_keys.sh" 2>&1 | tail -3)"
  assert_eq "$(printf '%s\n' "$r" | tail -1)" ok "tests/test_keys.sh without ade-secrets [$r]"
  # hub.conf's HUB_SECRETS (the names bin/doctor checks) never defeats the switch, and the switch is not a name to check
  printf "HUB_SECRETS='grafana-token'\n" > hub.conf
  assert_eq "$(HUB_SECRETS=builtin bash -c '. bin/lib.sh; echo "$HUB_SECRET_NAMES|$HUB_SECRETS"')" "grafana-token|builtin" "hub.conf names, the environment's switch"
  assert_eq "$(bash -c '. bin/lib.sh; echo "$HUB_SECRET_NAMES|${HUB_SECRETS-unset}"')" "grafana-token|unset" "hub.conf names only"
  ( with_ade; stub_security; export HUB_SECRETS=builtin; : > "$S/ade.log"; bin/keys >/dev/null 2>&1 || fail "bin/keys with hub.conf HUB_SECRETS"
    fake_unused "HUB_SECRETS=builtin with HUB_SECRETS names in hub.conf"; [ -s "$STORE.argv" ] || fail "the hub's own store was not used" ) || exit 1
  rm -f hub.conf
  # a checkout's settings may not set the switch (it would move the secret store)
  case " $(bash -c '. bin/lib.sh; checkout_gate_vars') " in *" HUB_SECRETS "*) ;; *) fail "checkout_gate_vars lacks HUB_SECRETS" ;; esac
}

keys_through_secret() {   # AC4
  with_ade; export PATH="$S/fake:$S/nosec"; names
  command -v security >/dev/null && fail "the test PATH still has security"
  ade bin/keys; assert_eq "$RC" 0 "bin/keys without the security command, ade-secrets installed [$ERR]"
  case "$ERR$OUT" in *"macOS Keychain"*) fail "bin/keys checked for the security command [$ERR]" ;; esac
  printf '%s\n' "$OUT" | grep -Eq '^glm +missing' || fail "glm starts missing [$OUT]"
  [ -z "$(printf '%s\n' "$LOGGED" | grep -vx 'ade-secrets list --names')" ] || fail "the list made other calls [$LOGGED]"
  ade bash -c 'printf "typed-not-read\n" | bin/keys set glm'; assert_eq "$RC" 0 "bin/keys set"
  assert_eq "$LOGGED" "ade-secrets set zai-api-key --helper --kind api-key --used-by hub" "bin/keys set goes through bin/secret --set"
  ade bin/keys; printf '%s\n' "$OUT" | grep -Eq '^glm +stored' || fail "glm is stored [$OUT]"
  ade bin/keys forget glm; assert_eq "$RC" 0 "bin/keys forget"
  assert_eq "$LOGGED" "$(printf 'ade-secrets list --names\nade-secrets forget zai-api-key')" "forget checks presence, then forgets, through bin/secret"
  names zai-api-key
  CLAUDECODE=1 CLAUDE_CODE_CHILD_SESSION=1 ade bin/keys; assert_eq "$RC" 3 "a presence check inside an agent session exits 3"
  case "$OUT$ERR" in *"run this in your own terminal"*) ;; *) fail "it says to run it in your own terminal [$OUT|$ERR]" ;; esac
  case "$OUT$ERR" in *missing*) fail "a refusal was shown as missing [$OUT]" ;; esac
  CLAUDECODE=1 ade bin/keys forget glm; assert_eq "$RC" 3 "forget inside an agent session exits 3"
  case "$ERR" in *"run this in your own terminal"*) ;; *) fail "forget says to run it in your own terminal [$ERR]" ;; esac
  case "$ERR" in *"no key stored"*) fail "a refusal was shown as no key [$ERR]" ;; esac
  grep -q forget "$S/ade.log" && fail "forget went on after the refusal"
  # the only route to the store is bin/secret: bin/keys names no store command itself
  grep -v '^[[:space:]]*#' bin/keys | grep -Eq '(^|[;&|({]|then|do|exec)[[:space:]]*(security|ade-secrets|pass|secret_(get|put|has|forget|names))([[:space:]]|$)' && fail "bin/keys calls a store directly"
  ( with_ade; stub_security; names; bin/keys >/dev/null 2>&1; [ ! -s "$STORE.argv" ] || fail "bin/keys used the Keychain [$(cat "$STORE.argv")]" ) || exit 1
}

secret_helper_path() {   # AC5
  local h; with_ade; names anthropic-api-key
  ade bin/secret anthropic-api-key
  printf 'fixture-value-anthropic-api-key\n' > "$S/want"; cmp -s "$S/out" "$S/want" || fail "bin/secret <name> prints the value and a newline only [$(od -c "$S/out" | head -3)]"
  assert_eq "$ERR" "" "nothing on stderr"; assert_eq "$LOGGED" "ade-secrets get anthropic-api-key" "from ade-secrets get <name>"
  # the apiKeyHelper line the hub writes, run as Claude Code runs it (/bin/sh)
  bash -c '. bin/lib.sh; anthropic_settings_write "$1"' _ "$S/settings.json" || fail "anthropic_settings_write"
  h="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["apiKeyHelper"])' "$S/settings.json")"
  case "$h" in *"/bin/secret' anthropic-api-key") ;; *) fail "the helper line is unchanged [$h]" ;; esac
  ade /bin/sh -c "$h"; cmp -s "$S/out" "$S/want" || fail "the apiKeyHelper line gets the value and a newline only"
  assert_eq "$RC:$ERR" "0:" "the helper line exits 0, quietly"; assert_eq "$LOGGED" "ade-secrets get anthropic-api-key" "the helper line calls get"
}

doctor_names_store() {   # AC6
  local l want
  with_ade; names zai-api-key
  ade env DOCTOR_OFFLINE=1 bin/doctor; l="$(printf '%s\n' "$OUT" | grep -E '^OK +secrets ')"
  case "$l" in *"ade-secrets 0.3.0"*) ;; *) fail "bin/doctor names ade-secrets and its version [$OUT]" ;; esac
  case "$OUT" in *fixture-value*) fail "bin/doctor printed a value" ;; esac
  printf '%s\n' "$LOGGED" | grep -q 'ade-secrets get' && fail "bin/doctor read a value [$LOGGED]"
  case "$OUT" in *"macOS Keychain"*) fail "bin/doctor names the hub's own store while ade-secrets is in use [$OUT]" ;; esac
  FAKE_RC=1 ade env DOCTOR_OFFLINE=1 bin/doctor
  printf '%s\n' "$OUT" | grep -E '^OK +secrets ' | grep -q 'ade-secrets (version unknown)' || fail "an unreadable version [$OUT]"
  CLAUDECODE=1 ade env DOCTOR_OFFLINE=1 bin/doctor; printf '%s\n' "$OUT" | grep -E '^OK +secrets ' | grep -q 'ade-secrets 0.3.0' || fail "inside an agent session too [$OUT]"
  # a provider's key: stored, then (inside an agent session) not checked here, never "missing"
  printf 'HUB_PROVIDERS_ALLOWED="anthropic glm"\nHUB_OWNED_BY_OWNER=1\n' > hub.conf
  ade env DOCTOR_OFFLINE=1 bin/doctor; l="$(printf '%s\n' "$OUT" | grep 'zai-api-key')"
  case "$l" in OK*"zai-api-key in ade-secrets"*) ;; *) fail "a stored provider key, in ade-secrets [$l]" ;; esac
  CLAUDECODE=1 ade env DOCTOR_OFFLINE=1 bin/doctor; l="$(printf '%s\n' "$OUT" | grep 'zai-api-key')"
  case "$l" in *MISSING*) fail "a refused presence check was shown as missing [$l]" ;; *"own terminal"*) ;; *) fail "it says to check in your own terminal [$l]" ;; esac
  rm -f hub.conf
  # the hub's own store: the same line as before story H2, ade-secrets absent or switched off
  stub_security; no_ade; want="$(DOCTOR_OFFLINE=1 bin/doctor | grep -E '^OK +secrets ')"
  assert_eq "$want" "$(printf '%-8s %-22s %s' OK secrets "the macOS Keychain (service $(basename "$HUB"))")" "the hub's own store, named as before"
  with_ade; export HUB_SECRETS=builtin; ade env DOCTOR_OFFLINE=1 bin/doctor
  assert_eq "$(printf '%s\n' "$OUT" | grep -E '^OK +secrets ')" "$want" "HUB_SECRETS=builtin: the hub's own store"; fake_unused "doctor with HUB_SECRETS=builtin"
  unset HUB_SECRETS
}

settings_have_secret_rules() {   # AC7
  local f
  grep -q "tag v0.3.0" "$FIX/README.md" && grep -q 'claude-settings.json' "$FIX/README.md" || fail "the pinned settings name their ade-secrets tag"
  rules_ok() { python3 - "$FIX/claude-settings.json" "$1" <<'PY'
import json, sys
want, have = json.load(open(sys.argv[1]))["permissions"], json.load(open(sys.argv[2]))["permissions"]
for k, rules in want.items():
    miss = [r for r in rules if r not in have.get(k, [])]
    assert not miss, "%s: permissions.%s lacks %s" % (sys.argv[2], k, miss)
    assert len(have[k]) == len(set(have[k])), "%s: a rule twice in permissions.%s" % (sys.argv[2], k)
PY
  }
  for f in .claude/settings.json templates/folder-settings.json; do
    rules_ok "$f" || fail "$f has ade-secrets' permission rules"
    python3 - "$f" <<'PY' || fail "$f keeps the rules it had"
import json, sys
p = json.load(open(sys.argv[1]))["permissions"]
assert "Read(~/.config/ade/browser/**)" in p["deny"] and "Edit(~/.config/ade/browser/**)" in p["deny"]
assert "Bash(*bin/agent --live-test*)" in p["ask"] and "Bash(*hub.conf*)" in p["ask"]
PY
    # the check fails when one rule is missing
    python3 - "$f" "$S/one-less.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1])); s["permissions"]["deny"].remove("Bash(pass show*)"); json.dump(s, open(sys.argv[2], "w"))
PY
    rules_ok "$S/one-less.json" 2>/dev/null && fail "the check passes with a rule missing"; done
  # a folder made by bin/new gets them too
  bin/new projects/h2demo >/dev/null 2>&1 || fail "bin/new"; rules_ok projects/h2demo/.claude/settings.json || fail "a new folder's settings"
}

secret_linux() {   # AC8
  local d
  export AGENT_PLATFORM=linux; rm -f hub.conf
  d="$(bash -c '. bin/lib.sh; secret_file_root')/$(basename "$HUB")"
  case "$d" in "$HOME"/*) ;; *) fail "the file store is under the test's HOME [$d]" ;; esac
  with_ade; names
  ade bin/secret --set k1 < /dev/null; assert_eq "$LOGGED" "ade-secrets set k1 --helper --kind api-key --used-by hub" "--set on Linux"
  ade bin/secret k1; assert_eq "$RC:$OUT" "0:fixture-value-k1" "get on Linux"
  ade bin/secret --has k1; assert_eq "$RC" 0 "--has on Linux"
  [ ! -e "$(dirname "$d")" ] || fail "the hub's file store was made while ade-secrets is installed"
  # a loose ~/.config refuses the hub's own file store, which bin/keys does not need with ade-secrets
  mkdir -p "$HOME/.config"; chmod 777 "$HOME/.config"
  ade bin/keys; assert_eq "$RC" 0 "bin/keys on Linux with ade-secrets [$ERR]"
  ade env DOCTOR_OFFLINE=1 bin/doctor; printf '%s\n' "$OUT" | grep -E '^OK +secrets ' | grep -q 'ade-secrets 0.3.0' || fail "doctor on Linux [$OUT]"
  chmod 700 "$HOME/.config"
  # the 0600 file store only when ade-secrets is absent (or switched off)
  ( export HUB_SECRETS=builtin; : > "$S/ade.log"; printf 'fixture-linux-2\n' | bin/secret --set k2 2>/dev/null || fail "builtin --set"
    assert_eq "$(fmode "$d/k2")" 600 "the file store's 0600 file"; assert_eq "$(bin/secret k2)" fixture-linux-2 "builtin get"; fake_unused "HUB_SECRETS=builtin on Linux" ) || exit 1
  no_ade; printf 'fixture-linux-3\n' | bin/secret --set k3 2>/dev/null || fail "--set without ade-secrets"
  assert_eq "$(fmode "$d/k3")" 600 "0600 without ade-secrets"; assert_eq "$(bin/secret k3)" fixture-linux-3 "get without ade-secrets"
  rm -rf "$HOME/.config"; export AGENT_PLATFORM=macos
}

secret_docs() {   # AC9
  local f v c=.ade/context/ade-secrets.md
  for f in README.md templates/hub/README.md; do
    grep -q "ade-secrets" "$f" || fail "$f names ade-secrets"
    grep -qi "not moved" "$f" || fail "$f says keys in the hub's old store are not moved"
    grep -qi "your own terminal" "$f" || fail "$f says they are entered again in your own terminal"
    grep -q "Owner check" "$f" || fail "$f points at the contract's Owner check before a real key is stored"
    grep -q "HUB_SECRETS=builtin" "$f" || fail "$f names the switch"; done
  [ -f "$c" ] || fail "the contract the hub relies on is recorded in $c"
  for v in "v0.3.0" "contract.md" "HUB_SECRETS=builtin" "set <name> --helper --kind api-key --used-by hub" "list --names" "forget <name>" \
    "get <name>" "exit 3" "Owner check" "HUB_SECRET_NAMES" "tests/fixtures/ade-secrets"; do
    grep -qF -- "$v" "$c" || fail "$c lacks [$v]"; done
}

ALL="secret_block_matches_contract secret_delegates secret_builtin_unchanged keys_through_secret secret_helper_path doctor_names_store settings_have_secret_rules secret_linux secret_docs"
if [ $# -eq 0 ]; then ( existing_secret_checks ) || exit 1; fi
for t in ${@:-$ALL}; do ( "$t" ) || exit 1; done
echo ok
