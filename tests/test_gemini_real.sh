#!/bin/bash
# The real Gemini CLI, offline (story E1, .ade/context/engines.md "Gemini CLI engine"): proves the hub's restrictions
# apply in the CLI itself, not only in what bin/gemini-run passes. Opt-in: ADE_REAL_GEMINI=1 bash tests/test_gemini_real.sh
# (skipped otherwise, and when no gemini is installed). Offline: the CLI talks only to tests/fake_gemini_api.py on
# 127.0.0.1 (AGENT_GEMINI_LOOPBACK_URL), with a fake key; every other connection goes to a dead proxy (127.0.0.1:9).
. "$(dirname "$0")/helpers.sh"
if [ "${ADE_REAL_GEMINI:-}" != 1 ] || ! command -v gemini >/dev/null 2>&1; then echo "skipped (ADE_REAL_GEMINI=1 and an installed gemini run it)"; echo ok; exit 0; fi
make_hub; cd "$HUB"
S="$(mktemp -d)"; S="$(cd "$S" && pwd -P)"; mkdir -p "$S/home" "$S/ws/.ssh"; export HOME="$S/home"
SRV=""; trap '[ -z "$SRV" ] || kill "$SRV" 2>/dev/null; rm -rf "$S" "$(dirname "$HUB")" "$CLAUDE_HOME" "$(dirname "$AGENT_SYNC_LOG")" "$(dirname "$AGENT_SYNC_LOCK")"' EXIT
FAKEKEY="fake-$RANDOM$RANDOM"
printf '#!/bin/bash\ncase "$1" in --has) exit 0 ;; esac\nprintf %%s %s\n' "$FAKEKEY" > bin/secret; chmod +x bin/secret
printf '%s\n' 'HUB_PROVIDERS_ALLOWED="anthropic gemini"' 'HUB_OWNED_BY_OWNER=1' > hub.conf
W="$S/ws"; echo hello > "$W/notes.txt"; echo PEM-DUMMY > "$W/server.pem"; echo SSH-DUMMY > "$W/.ssh/id_test"; git -C "$W" init -q
export HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 NO_PROXY=127.0.0.1,localhost
# scen <mode> <plan json> [gemini args...]: one run against a fresh fake API; FR = the tool results the CLI sent back
scen() { local m="$1" plan="$2"; shift 2; rm -f "$S/log" "$S/port"; printf '%s\n' "$plan" > "$S/plan"
  python3 -I "$REPO/tests/fake_gemini_api.py" "$S/port" "$S/log" "$S/plan" & SRV=$!
  local i; for i in $(seq 1 50); do [ -s "$S/port" ] && break; sleep 0.1; done
  (cd "$W" && AGENT_GEMINI_LOOPBACK_URL="http://127.0.0.1:$(cat "$S/port")" "$HUB/bin/gemini-run" --auth key --mode "$m" -m gemini-2.5-flash -o text "$@" < /dev/null > "$S/out" 2> "$S/err"); rc=$?
  kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; SRV=""
  python3 -c 'import json, sys
for l in open(sys.argv[1]):
    for c in (json.loads(l).get("body", {}).get("contents") or [])[-1:]:
        for p in c.get("parts", []):
            if "functionResponse" in p: print(json.dumps(p["functionResponse"].get("response")))' "$S/log" > "$S/fr" 2>/dev/null; }
call() { printf '[{"call":"%s","args":%s},{"text":"DONE"}]' "$1" "$2"; }

agent_reads_only() {
  scen agent "$(call read_file '{"file_path":"notes.txt"}')" -p go -e none --approval-mode default; assert_eq "$rc" 0 "agent run: $(tail -3 "$S/err")"
  grep -q 'hello' "$S/fr" || fail "a read tool works: $(cat "$S/fr")"
  local t; for t in 'write_file {"file_path":"x.txt","content":"x"}' 'run_shell_command {"command":"touch proof.txt","description":"x"}'; do
    scen agent "$(call ${t%% *} "${t#* }")" -p go -e none --approval-mode default
    grep -q 'not found' "$S/fr" || fail "${t%% *} is not offered to a delegated run: $(cat "$S/fr")"; done
  [ ! -e "$W/x.txt" ] && [ ! -e "$W/proof.txt" ] || fail "a delegated run changed the checkout"
  for t in server.pem .ssh/id_test; do scen agent "$(call read_file "{\"file_path\":\"$t\"}")" -p go -e none --approval-mode default
    grep -q 'denied by policy' "$S/fr" || fail "$t is denied by the hub's policy: $(cat "$S/fr") $(grep -iv -e 256-color -e ripgrep "$S/err" | head -5)"; grep -q DUMMY "$S/fr" && fail "$t was read"; done
  grep -qi 'skipping' "$S/err" && fail "the CLI skipped a settings or policy file: $(grep -i skipping "$S/err")"
}
user_layer_applies() {
  scen focus '[{"text":"DONE"}]' -p go --skip-trust   # writes the hub's home
  (cd "$W" && GEMINI_CLI_HOME="$HUB/.local/engines/gemini-key" GEMINI_API_KEY=x gemini --yolo -p go < /dev/null > "$S/out" 2> "$S/err"); local r=$?
  [ "$r" != 0 ] && grep -qi 'yolo mode is disabled' "$S/err" || fail "the hub's settings layer turns yolo off in the CLI (exit $r): $(tail -3 "$S/err")"
}
tools_do_not_see_the_key() {
  printf '[[rule]]\ntoolName = "run_shell_command"\ncommandPrefix = "printenv"\ndecision = "allow"\nallowRedirection = true\npriority = 900\n' > "$S/allow.toml"
  scen focus "$(call run_shell_command '{"command":"printenv GEMINI_API_KEY > key.txt; printenv HOME > home.txt","description":"x"}')" -p go --skip-trust --policy "$S/allow.toml" --approval-mode default
  [ -s "$W/home.txt" ] || fail "the shell tool ran (else this check proves nothing): $(cat "$S/fr")"
  [ ! -s "$W/key.txt" ] || fail "a tool's child saw the key"; grep -qF "$FAKEKEY" "$S/fr" && fail "the key is in a tool result"
  rm -f "$W/key.txt" "$W/home.txt"
}

for t in ${@:-agent_reads_only user_layer_applies tools_do_not_see_the_key}; do "$t"; done
echo ok
