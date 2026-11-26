#!/bin/bash
# story K2: a key pasted into a Claude prompt is stopped before it is sent (bin/paste-guard, UserPromptSubmit hook)
. "$(dirname "$0")/helpers.sh"
make_hub; cd "$HUB"; export AGENT_STATE="$(mktemp -d)"
G="$HUB/bin/paste-guard"
# Every fake key is built at run time from parts, so no key-shaped literal sits in this file (the pre-commit gitleaks
# scan and push protection would flag it). body <n> [alphabet]: n characters, deterministic, with digits and letters.
body() { python3 -c 'import sys; n=int(sys.argv[1]); a=sys.argv[2]; print("".join(a[(i*7+3)%len(a)] for i in range(n)))' \
  "$1" "${2:-AbCdEfGhJkLmNpQrStUvWxYz0123456789aBcDeFgHiJkMnPqRsTuVwXy}"; }
HEX=0123456789abcdef; UP=ABCDEFGHIJKLMNOPQRSTUVWXYZ234567
# the hook's input, as Claude Code sends it (python, so any text is quoted right)
inp() { python3 -c 'import json, sys; print(json.dumps({"session_id": "s1", "hook_event_name": "UserPromptSubmit", "prompt": sys.argv[1]}))' "$1"; }
# guard <prompt> [env...]: runs the hook; OUT, ERR, RC
guard() { local p="$1" e; shift; e="$(mktemp)"; OUT="$(inp "$p" | env "$@" "$G" 2>"$e")"; RC=$?; ERR="$(cat "$e")"; rm -f "$e"; }
# blocked <prompt> <kind> <what>: a block decision (exit 0, JSON on stdout) whose reason names the kind, never the prompt
blocked() {
  guard "$1"; [ "$RC" = 0 ] || fail "$3: exit $RC"
  python3 - "$OUT" "$2" <<'PY' || fail "$3: not blocked as $2: [$OUT]"
import json, sys
d = json.loads(sys.argv[1]); r = d["reason"]
assert d["decision"] == "block"
assert d["hookSpecificOutput"] == {"hookEventName": "UserPromptSubmit", "suppressOriginalPrompt": True}, d
assert "That looks like a key (" + sys.argv[2] in r, r
assert "so it was not sent. Store it at a hidden prompt: ade keys set " in r and "(or bin/keys set " in r, r
assert "If it was real and already shared somewhere, rotate it." in r, r
PY
}
passes() { guard "$1"; [ "$RC" = 0 ] && [ -z "$OUT" ] && [ -z "$ERR" ] || fail "$2: not passed untouched (exit $RC) [$OUT] [$ERR]"; }

# the fake keys, one per kind
K_ANT="sk-""ant-api03-$(body 93)"; K_PROJ="sk-""proj-$(body 64)"; K_SK="sk-""$(body 32 $HEX)"
K_GHP="ghp""_$(body 36)"; K_GHO="gho""_$(body 36)"; K_GHU="ghu""_$(body 36)"; K_GHS="ghs""_$(body 36)"; K_GHR="ghr""_$(body 36)"
K_PAT="github""_pat_$(body 22)_$(body 59)"; K_GL="glpat""-$(body 20)"
K_SLB="xox""b-$(body 12 0123456789)-$(body 13 0123456789)-$(body 24)"; K_SLA="xox""a-2-$(body 30)"; K_SLP="xox""p-$(body 40)"
K_SLR="xox""r-$(body 40)"; K_SLS="xox""s-$(body 40)"
K_AKIA="AK""IA$(body 16 $UP)"; K_ASIA="AS""IA$(body 16 $UP)"; K_GOO="AI""za$(body 35)"
K_TG="$(body 10 123456789):$(body 35)"; K_GLM="$(body 32 $HEX).$(body 16)"
PEM1="-----BEGIN ""RSA PRIVATE KEY-----"; PEM2="-----BEGIN ""OPENSSH PRIVATE KEY-----"; PEM3="-----BEGIN ""PRIVATE KEY-----"
PEM4="-----BEGIN ""EC PRIVATE KEY-----"; PEM5="-----BEGIN ""PGP PRIVATE KEY BLOCK-----"
ALL="$K_ANT $K_PROJ $K_SK $K_GHP $K_GHO $K_GHU $K_GHS $K_GHR $K_PAT $K_GL $K_SLB $K_SLA $K_SLP $K_SLR $K_SLS $K_AKIA $K_ASIA $K_GOO $K_TG $K_GLM"

# --- 1. guard_blocks_known: each kind, alone and inside a sentence, is blocked with its kind named
while IFS='|' read -r k kind; do
  blocked "$k" "$kind" "guard_blocks_known: alone ($kind)"
  blocked "can you set this up, here is the key: $k thanks" "$kind" "guard_blocks_known: in a sentence ($kind)"
done <<EOF
$K_ANT|Anthropic key
$K_PROJ|OpenAI-style key
$K_SK|OpenAI-style key
$K_GHP|GitHub token
$K_GHO|GitHub token
$K_GHU|GitHub token
$K_GHS|GitHub token
$K_GHR|GitHub token
$K_PAT|GitHub token
$K_GL|GitLab token
$K_SLB|Slack token
$K_SLA|Slack token
$K_SLP|Slack token
$K_SLR|Slack token
$K_SLS|Slack token
$K_AKIA|AWS access key
$K_ASIA|AWS access key
$K_GOO|Google API key
$K_TG|Telegram bot token
$K_GLM|GLM key
EOF
for p in "$PEM1" "$PEM2" "$PEM3" "$PEM4" "$PEM5"; do
  blocked "$p" "private key" "guard_blocks_known: PEM header alone"
  blocked "$(printf 'my deploy key:\n%s\n%s\n-----END' "$p" "$(body 64)")" "private key" "guard_blocks_known: PEM block"; done
# the ways a pasted key arrives: in a URL, quoted, in an env line, wrapped over two lines, with lookalike characters
blocked "curl https://api.telegram.org/bot$K_TG/getMe" "Telegram bot token" "guard_blocks_known: token in a URL"
blocked "fetch https://maps.example.test/api?key=$K_GOO&q=1" "Google API key" "guard_blocks_known: key in a query string"
blocked "export ANTHROPIC_API_KEY=\"$K_ANT\"" "Anthropic key" "guard_blocks_known: quoted env line"
blocked "$(printf 'key:\n%s\n%s\nthanks' "${K_ANT:0:40}" "${K_ANT:40}")" "Anthropic key" "guard_blocks_known: key wrapped over two lines"
blocked "$(printf 'key: %s\r\n%s' "${K_GHP:0:20}" "${K_GHP:20}")" "GitHub token" "guard_blocks_known: key wrapped with CRLF"
FW="$(python3 -c 'import sys; print("".join(chr(ord(c) + 0xFEE0) if "!" <= c <= "~" else c for c in sys.argv[1]))' "$K_GHP")"
blocked "key $FW" "GitHub token" "guard_blocks_known: fullwidth lookalike characters"
ZW="$(python3 -c 'import sys; k=sys.argv[1]; print(k[:10] + "​" + k[10:20] + "⁠" + k[20:])' "$K_AKIA")"
blocked "aws $ZW" "AWS access key" "guard_blocks_known: zero-width characters inside the key"
blocked "$(printf 'k=\033[1m%s\033[0m' "$K_GL")" "GitLab token" "guard_blocks_known: key inside terminal colour codes"
blocked "$(printf '%s\n%s' "$K_ANT" "$K_TG")" "Anthropic key, Telegram bot token" "guard_blocks_known: two kinds named"
blocked "AK""IA$(body 16 ABCDEFGHIJKLMNOPQRSTUVWXYZ)" "AWS access key" "guard_blocks_known: an AWS key id with no digit"
blocked "API Key${K_ANT}" "Anthropic key" "guard_blocks_known: key glued to the text before it (a copied table row)"
blocked "xox""e.xoxp-1-$(body 40)" "Slack token" "guard_blocks_known: Slack refresh token"
# the scan stays linear: many prefixes before a key are answered within seconds, not past Claude Code's 30 s timeout
s=$SECONDS; blocked "$(python3 -c 'print("sk-" * 20000 + " xoxb-" * 20000)') $K_GL" "GitLab token" "guard_blocks_known: many prefixes"
[ $((SECONDS - s)) -lt 5 ] || fail "guard_blocks_known: many prefixes took $((SECONDS - s)) s"
# the tool, where the kind names one the hub stores keys for
guard "$K_TG"; echo "$OUT" | grep -qF "ade keys set telegram (or bin/keys set telegram)" || fail "guard_blocks_known: telegram tool [$OUT]"
guard "$K_GLM"; echo "$OUT" | grep -qF "ade keys set glm (or bin/keys set glm)" || fail "guard_blocks_known: glm tool [$OUT]"
guard "$K_ANT"; echo "$OUT" | grep -qF "ade keys set anthropic (or bin/keys set anthropic)" || fail "guard_blocks_known: anthropic tool [$OUT]"
guard "$K_GHP"; echo "$OUT" | grep -qF "ade keys set <tool> (or bin/keys set <tool>)" || fail "guard_blocks_known: generic tool [$OUT]"

# --- 2. guard_passes_normal: ordinary prompts and key-like engineering text pass untouched
SHA="$(body 40 $HEX)"; SHA256="$(body 64 $HEX)"; B64="$(body 120 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/')"
while IFS= read -r p; do passes "$p" "guard_passes_normal: [$p]"; done <<EOF
fix the login bug in api/auth.py and add a test
deploy to staging after the tests pass, then check the logs at 10:30
revert commit $SHA please
the short sha ${SHA:0:7} broke the build
request id 123e4567-e89b-12d3-a456-426614174000 failed at 12:34:56
pip install scikit-learn; we use sk-learn for the model
the sk- prefix marks OpenAI keys and sk-ant- marks Anthropic ones
AKIA keys are AWS access keys; store them with ade keys set
use the ghp_ prefix check in the scanner, and xoxb- for Slack bots
docker run -p 8080:8080 -v /data:/data app:latest
the task-runner-for-nightly-builds-and-backups job timed out
our risk-assessment-documentation-v2 is in the wiki
git checkout -b feature/sk-1234-fix-the-login-bug-on-ios
pod sk-worker-7d9f8b6c5d-x2k4p restarted after the OOM at 03:12
use the sk-sweep-2024-11-26-config profile for the nightly job
the AWS docs example key AKIAIOSFODNN7EXAMPLE is not real
EOF
passes "$(printf 'the image digest:\n```\nsha256:%s\n%s\n```\nis that right?' "$SHA256" "$B64")" "guard_passes_normal: code block with a long hash"
passes "$(printf 'see\n```\nAKIA\n%s\n```' "$(body 50 $HEX)")" "guard_passes_normal: a prefix on its own line before a hash"
passes "" "guard_passes_normal: an empty prompt"

# --- 3. guard_never_echoes: no key in stdout, stderr, or any file the hook could write
GH="$(mktemp -d)"; GT="$(mktemp -d)"; GS="$(mktemp -d)"
for k in $ALL "$PEM1"; do
  OUT="$(inp "please use $k" | HOME="$GH" TMPDIR="$GT" AGENT_STATE="$GS" "$G" 2>"$GT/err.$$")"; ERR="$(cat "$GT/err.$$")"; rm -f "$GT/err.$$"
  tail="${k: -12}"
  case "$OUT$ERR" in *"$k"*|*"$tail"*) fail "guard_never_echoes: the key is in the hook's output";; esac
  echo "$OUT" | grep -q '"decision": *"block"' || fail "guard_never_echoes: not blocked"
done
for d in "$GH" "$GT" "$GS" "$HUB" "$CLAUDE_HOME"; do
  for k in $ALL; do grep -rqF -- "${k: -12}" "$d" 2>/dev/null && fail "guard_never_echoes: a key was written under $d"; done; done
# a malformed input that holds a key is not echoed either
for raw in "{\"prompt\": \"$K_ANT" "$K_ANT" "{\"prompt\": [\"$K_ANT\"]}"; do
  OUT="$(printf '%s' "$raw" | "$G" 2>&1)"; RC=$?
  case "$OUT" in *"${K_ANT: -12}"*) fail "guard_never_echoes: malformed input echoed";; esac; done

# --- 4. guard_installed: the root and folder settings run it on UserPromptSubmit before bin/changes; init and setup keep it
order() {  # order <settings.json>: the UserPromptSubmit commands, one per line, in order
  python3 -c 'import json, sys
for g in json.load(open(sys.argv[1]))["hooks"]["UserPromptSubmit"]:
    for h in g["hooks"]: print(h["command"])' "$1"; }
first_guard() {  # first_guard <settings.json> <what>
  local o; o="$(order "$1")" || fail "guard_installed: $2 has no UserPromptSubmit hooks"
  echo "$o" | sed -n 1p | grep -qE '/bin/paste-guard"?$' || fail "guard_installed: $2 does not run bin/paste-guard first: [$o]"
  echo "$o" | grep -q '/bin/changes' || fail "guard_installed: $2 lost bin/changes: [$o]"; }
[ -x "$G" ] || fail "guard_installed: bin/paste-guard is not executable"
first_guard .claude/settings.json "the template's root settings"; first_guard templates/folder-settings.json "templates/folder-settings.json"
grep -q '"\\"$CLAUDE_PROJECT_DIR\\"/bin/paste-guard"' .claude/settings.json || fail "guard_installed: root command form"
grep -q '"\\"$CLAUDE_PROJECT_DIR\\"/../../bin/paste-guard"' templates/folder-settings.json || fail "guard_installed: folder command form"
D="$(mktemp -d)/acme"
bin/init --persona devops-sre --client "Acme Corp" --owner "Sam Lee" --dest "$D" --auto-sync off >/dev/null 2>&1 || fail "guard_installed: init failed"
first_guard "$D/.claude/settings.json" "a hub made by bin/init (root)"
for f in "$D"/ops/*/.claude/settings.json; do first_guard "$f" "a hub made by bin/init ($f)"; done
(cd "$D" && HUB="$D" bin/new projects/web >/dev/null && HUB="$D" bin/setup >/dev/null 2>&1) || fail "guard_installed: new or setup failed"
first_guard "$D/.claude/settings.json" "the root after bin/setup"
for f in "$D"/ops/*/.claude/settings.json "$D/projects/web/.claude/settings.json"; do first_guard "$f" "$f after bin/setup"; done
# the guard runs in an initialised hub, with its own hub.conf
OUT="$(inp "$K_ANT" | HUB="$D" "$D/bin/paste-guard" 2>/dev/null)"; echo "$OUT" | grep -q '"decision": *"block"' || fail "guard_installed: not blocking in the new hub"
# the hooks run in parallel: a prompt the guard blocks uses up none of bin/changes's notices (they come with the next one)
CI='{"session_id":"sess-k2","prompt":"hello"}'; echo "$CI" | bin/changes projects/web >/dev/null 2>&1
bin/journal . "rotated the staging certs" >/dev/null
o="$(inp "$K_ANT" | python3 -c 'import json,sys; d=json.load(sys.stdin); d["session_id"]="sess-k2"; print(json.dumps(d))' | bin/changes projects/web 2>&1)"
[ -z "$o" ] || fail "guard_installed: bin/changes answered a blocked prompt [$o]"
o="$(echo "$CI" | bin/changes projects/web 2>&1)"; [ -n "$o" ] || fail "guard_installed: the change was used up by the blocked prompt"
case "$o" in *"${K_ANT: -12}"*) fail "guard_installed: bin/changes echoed the key";; esac
# a folder from before story K2 (no paste guard) is named by bin/doctor
python3 - "$D/projects/web/.claude/settings.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
for g in d["hooks"]["UserPromptSubmit"]: g["hooks"] = [h for h in g["hooks"] if "paste-guard" not in h["command"]]
json.dump(d, open(p, "w"), indent=2)
PY
(cd "$D" && HUB="$D" bin/doctor 2>&1) | grep -q "settings projects/web.*no paste guard.*bin/new --settings projects/web" || fail "guard_installed: doctor does not name a folder without the guard"
(cd "$D" && HUB="$D" bin/new --settings projects/web >/dev/null) || fail "guard_installed: new --settings failed"
first_guard "$D/projects/web/.claude/settings.json" "a folder re-rendered by bin/new --settings"

# --- 5. guard_off: HUB_PASTE_GUARD=off in hub.conf lets prompts through; in the environment (or .local/hub.conf) it does not
blocked "$K_ANT" "Anthropic key" "guard_off: on by default"
guard "$K_ANT" HUB_PASTE_GUARD=off; echo "$OUT" | grep -q '"decision": *"block"' || fail "guard_off: the environment turned it off"
mkdir -p .local
for l in 'HUB_PASTE_GUARD=off' 'readonly HUB_PASTE_GUARD=off' 'hub_policy_vars() { echo X; }; HUB_PASTE_GUARD=off' 'unset() { :; }; HUB_PASTE_GUARD=off'; do
  echo "$l" > .local/hub.conf
  guard "$K_ANT"; echo "$OUT" | grep -q '"decision": *"block"' || fail "guard_off: .local/hub.conf turned it off ($l)"; done
H2="$(mktemp -d)"; echo 'HUB_PASTE_GUARD=off' > "$H2/hub.conf"
guard "$K_ANT" HUB="$H2"; echo "$OUT" | grep -q '"decision": *"block"' || fail "guard_off: \$HUB naming another hub.conf turned it off"
rm .local/hub.conf; echo 'HUB_PASTE_GUARD=off' >> hub.conf
passes "$K_ANT" "guard_off: hub.conf off"
sed -i.bak 's/^HUB_PASTE_GUARD=off$/HUB_PASTE_GUARD=on/' hub.conf; rm -f hub.conf.bak
blocked "$K_ANT" "Anthropic key" "guard_off: hub.conf on"
rm hub.conf

# --- 6. guard_fails_open_safely: malformed input or no python: exit 0, no block, nothing about a key
for raw in "" "not json" "{" "[]" '{"prompt": 5}' '{"session_id": "s1"}' "{\"prompt\": \"$K_ANT"; do
  e="$(mktemp)"; OUT="$(printf '%s' "$raw" | "$G" 2>"$e")"; RC=$?; ERR="$(cat "$e")"; rm -f "$e"
  [ "$RC" = 0 ] && [ -z "$OUT" ] || fail "guard_fails_open_safely: malformed input [${raw:0:12}] exit $RC [$OUT]"
  case "$ERR" in *"${K_ANT: -12}"*|*key*) fail "guard_fails_open_safely: says something about a key [$ERR]";; esac; done
# no python3 on PATH: every other command the shell needs, linked into one directory
NP="$(mktemp -d)"; for d in /bin /usr/bin; do for c in "$d"/*; do n="${c##*/}"
  case "$n" in python*) continue;; esac; [ -e "$NP/$n" ] || ln -s "$c" "$NP/$n"; done; done
e="$(mktemp)"; OUT="$(inp "$K_ANT" | env PATH="$NP" "$G" 2>"$e")"; RC=$?; ERR="$(cat "$e")"; rm -f "$e"
[ "$RC" = 0 ] && [ -z "$OUT" ] || fail "guard_fails_open_safely: no python: exit $RC [$OUT]"
case "$ERR" in *"${K_ANT: -12}"*) fail "guard_fails_open_safely: no python echoed the key";; esac
# a hook that never gets EOF on stdin still answers in time (Claude Code's own hook timeout is 30 s)
o="$(mktemp)"; f="$(mktemp -u)"; mkfifo "$f"; "$G" < "$f" > "$o" 2>/dev/null & exec 9>"$f"; inp "$K_ANT" >&9
n=0; until grep -q '"decision": *"block"' "$o" || [ $n -ge 100 ]; do sleep 0.1; n=$((n + 1)); done
exec 9>&-; rm -f "$f"; grep -q '"decision": *"block"' "$o" || fail "guard_fails_open_safely: open stdin: no answer within 10 s [$(cat "$o")]"
echo ok
