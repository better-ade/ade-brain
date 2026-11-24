#!/bin/bash
# Story C9: Telegram as the console for the focus agents (bin/chat board|act|shots|menu|thread, ADR 0007). A stand-in
# for the Bot API on 127.0.0.1 records every call; a fake security; fake agents (sleep processes) behind a stubbed
# bin/sessions. Never the network, a real bot or a real token: every token, key and id is made up here at runtime.
. "$(dirname "$0")/helpers.sh"
make_hub; cd "$HUB"; stub_security; export AGENT_STATE="$(mktemp -d)"; export HOME="$(mktemp -d)"
unset TELEGRAM_BOT_TOKEN TELEGRAM_STATE_DIR HUB_CHAT HUB_CHANNELS HUB_CHAT_MODE CLAUDE_CONFIG_DIR AGENT_CHAT_SEND
S="$AGENT_STATE"; W="$(mktemp -d)"; W="$(cd "$W" && pwd -P)"; CH="$S/channels/telegram"; FAKE="$(mktemp -d)"; mkdir -p "$FAKE/bin"
OWNER="$(printf '%s%s' 5544 3322)"; OTHER="$(printf '%s%s' 1112 2233)"
K="$(printf '%s:%s' 100000002 "$(printf 'made-up-%s-' console test token only)")"
KEY="$(printf 'sk-%s' "$(printf 'q%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14)")"
access() { mkdir -p "$CH"; chmod 700 "$CH"; printf '%s\n' "$1" > "$CH/access.json"; chmod 600 "$CH/access.json"; }
locked() { access "{\"dmPolicy\": \"allowlist\", \"allowFrom\": [\"$OWNER\"], \"groups\": {}}"; }
wait_for() { local i=0; while ! eval "$1"; do i=$((i+1)); [ $i -lt 100 ] || return 1; sleep 0.1; done; }
locked; printf '%s\n' "$K" | bin/keys set telegram >/dev/null 2>&1 || fail "bin/keys set telegram"

# the stand-in Bot API: each request to $SRV/req.<n> (path, content type, body) and one line per call to $SRV/all
# (kept for the whole file). $SRV/ans.<method> ("<code> <json>") sets that method's answer; sendMessage and friends
# answer with a fresh message_id. It ends itself after 300 s and is killed when the test exits.
SRV="$(mktemp -d)"
cat > "$SRV/api.py" <<'PYS'
import http.server, json, os, signal, socketserver, sys
signal.alarm(300); d = sys.argv[1]; mid = [700]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        b = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        n = len([f for f in os.listdir(d) if f.startswith("req.")]) + 1
        open("%s/req.%d" % (d, n), "wb").write((self.path + "\n" + self.headers.get("Content-Type", "") + "\n").encode() + b)
        with open(d + "/all", "ab") as f: f.write(self.path.encode() + b"\t" + b.replace(b"\n", b" ") + b"\n")
        m = self.path.rsplit("/", 1)[-1]; mid[0] += 1
        code, body = 200, json.dumps({"ok": True, "result": {"message_id": mid[0]}}).encode()
        if os.path.exists("%s/ans.%s" % (d, m)):
            code, _, text = open("%s/ans.%s" % (d, m)).read().partition(" "); code = int(code); body = text.encode()
        self.send_response(code); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
s = socketserver.TCPServer(("127.0.0.1", 0), H); open(d + "/port", "w").write(str(s.server_address[1])); s.serve_forever()
PYS
python3 "$SRV/api.py" "$SRV" </dev/null >/dev/null 2>"$SRV/err" & srv=$!
AGENTS=""; trap 'kill $srv $AGENTS 2>/dev/null' EXIT
wait_for "[ -s '$SRV/port' ]" || fail "the stand-in API did not start [$(tail -n 5 "$SRV/err")]"
export AGENT_TELEGRAM_API="http://127.0.0.1:$(cat "$SRV/port")"
reset() { rm -f "$SRV"/req.* "$SRV"/ans.* "$W/out" "$W/err"; }
reqs() { ls "$SRV" | grep -c '^req\.'; }
# methods: the methods called since the last reset, in order, one per line
methods() { local i; for i in $(ls "$SRV" | sed -n 's/^req\.//p' | sort -n); do head -1 "$SRV/req.$i" | sed 's|.*/||'; done; }
# req_of <method> [nth]: the file of that method's nth call (default the last)
req_of() { local i f="" k="${2:-}"; for i in $(ls "$SRV" | sed -n 's/^req\.//p' | sort -n); do
  [ "$(head -1 "$SRV/req.$i" | sed 's|.*/||')" = "$1" ] && f="$f $SRV/req.$i"; done; set -- $f; [ $# -gt 0 ] || return 1
  if [ -n "$k" ]; then eval "echo \${$k}"; else eval "echo \${$#}"; fi; }
# field <request file> <python expression on d, the JSON body>: for JSON requests
field() { python3 - "$1" "$2" <<'PY'
import json, sys
raw = open(sys.argv[1], "rb").read().split(b"\n", 2)[2]; d = json.loads(raw); v = eval(sys.argv[2])
print(v if isinstance(v, str) else json.dumps(v))
PY
}
# part <request file> <field>: a multipart field's value (a file field: its length and file name)
part() { python3 - "$1" "$2" <<'PY'
import re, sys
raw = open(sys.argv[1], "rb").read(); path, ctype, body = raw.split(b"\n", 2); b = b"--" + ctype.split(b"boundary=")[1]
for p in body.split(b)[1:-1]:
    head, _, val = p.partition(b"\r\n\r\n"); val = val[:-2]
    m = re.search(rb'name="([^"]*)"(?:; filename="([^"]*)")?', head)
    if m.group(1).decode() == sys.argv[2]:
        print("%d %s" % (len(val), m.group(2).decode()) if m.group(2) is not None else val.decode("utf-8", "replace"))
PY
}
# file_bytes <request file> <field>: a multipart file field's bytes, printed as text
file_bytes() { python3 - "$1" "$2" <<'PY'
import re, sys
raw = open(sys.argv[1], "rb").read(); path, ctype, body = raw.split(b"\n", 2); b = b"--" + ctype.split(b"boundary=")[1]
for p in body.split(b)[1:-1]:
    head, _, val = p.partition(b"\r\n\r\n")
    if re.search(rb'name="%s"' % sys.argv[2].encode(), head): sys.stdout.write(val[:-2].decode("utf-8", "replace"))
PY
}

# fake agents: each one a sleep process (its engine), listed by a stubbed bin/sessions while it lives, with its registry
# entry (cwd, session id) as bin/work writes it. agent <name> <folder> <role> <status>; ended <name>
mkdir -p projects/api projects/web ops/infra "$S/sessions"; : > "$FAKE/sessions.txt"
cat > bin/sessions <<'STUB'
#!/bin/bash
printf '%-16s %-26s %-8s %-8s %-21s %-10s %-6s %-20s %s\n' NAME FOLDER PID PARENT STARTED ROLE STATUS LAST ENGINE
while read -r n f p st ro s la; do [ -n "$n" ] && kill -0 "$p" 2>/dev/null || continue
  printf '%-16s %-26s %-8s %-8s %-21s %-10s %-6s %-20s %s\n' "$n" "$f" "$p" - "$st" "$ro" "$s" "$la" claude; done < "$FAKE_SESSIONS"
STUB
printf '#!/bin/bash\nfor a in "$@"; do printf "[%%s]" "$a"; done >> "$FAKE_NOTIFY"; echo >> "$FAKE_NOTIFY"\n' > bin/notify
chmod +x bin/sessions bin/notify; export FAKE_SESSIONS="$FAKE/sessions.txt" FAKE_NOTIFY="$FAKE/notify.log"; : > "$FAKE_NOTIFY"
STARTED="$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-1H +%Y-%m-%dT%H:%M:%SZ)"
agent() { local p; sleep 600 & p=$!; AGENTS="$AGENTS $p"; trap 'kill $srv $AGENTS 2>/dev/null' EXIT
  echo "$1 $2 $p $STARTED $3 $4 $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$FAKE_SESSIONS"
  printf 'name=%s\nfolder=%s\nlauncher=%s\nstarted=%s\ncwd=%s\nrole=%s\nengine=claude\nticket=-\nconfig_dir=-\nsession_id=sid-%s\n' \
    "$1" "$2" "$p" "$STARTED" "$HUB/$2" "$3" "$1" > "$S/sessions/$1.$p"; }
pid_of() { awk -v n="$1" '$1==n {print $3}' "$FAKE_SESSIONS" | tail -1; }
ended() { kill "$(pid_of "$1")" 2>/dev/null; wait "$(pid_of "$1")" 2>/dev/null; true; }
set_status() { python3 - "$FAKE_SESSIONS" "$1" "$2" <<'PY'
import sys
f, n, s = sys.argv[1:]; ls = [l.split() for l in open(f) if l.strip()]
open(f, "w").write("".join(" ".join(l[:5] + [s] + l[6:]) + "\n" if l[0] == n else " ".join(l) + "\n" for l in ls))
PY
}
# the board's last edit, moved back past the 5 s gap
age_board() { python3 -c 'import json, sys; p = sys.argv[1]; d = json.load(open(p)); d["edited"] = d.get("edited", 0) - 10; json.dump(d, open(p, "w"))' "$S/chat/board.json"; }
# act <from> <reply-to> <text>: bin/chat act, the text on stdin; RC, $W/out, $W/err
act() { printf '%s\n' "$3" | bin/chat act --from "$1" --reply-to "$2" > "$W/out" 2> "$W/err"; RC=$?; }
ev() { H="$HUB" ST="$S" python3 -I bin/events.py write "$@" || fail "event write $*"; }
agent api projects/api builder busy; agent web projects/web - idle

board_edited_in_place() {   # AC1
  reset; rm -f "$S/chat/board.json"; bin/chat board > "$W/out" 2> "$W/err" || fail "the first board [$(cat "$W/err")]"
  assert_eq "$(methods | tr '\n' ' ')" "sendMessage pinChatMessage " "posted once, then pinned"
  assert_eq "$(fmode "$S/chat/board.json")" 600 "board.json is 0600"
  local id; id="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["message_id"])' "$S/chat/board.json")"
  assert_eq "$(field "$(req_of pinChatMessage)" 'd["message_id"]')" "$id" "the posted message is the one pinned"
  assert_eq "$(field "$(req_of pinChatMessage)" 'd["disable_notification"]')" true "pinned without a notification"
  field "$(req_of sendMessage)" 'd["text"]' > "$W/board"
  grep -q '^● api · projects/api · builder · ' "$W/board" || fail "api's row [$(cat "$W/board")]"
  grep -q '^○ web · projects/web · - · - · ' "$W/board" || fail "web's row"
  reset; bin/chat board || fail "board, unchanged"; assert_eq "$(reqs)" 0 "nothing changed: no call"
  # a change within 5 s of the last edit waits; past it, one edit of the same message
  set_status web busy; reset; bin/chat board || fail "board, coalesced"; assert_eq "$(reqs)" 0 "a second edit within 5 s waits"
  age_board; reset; bin/chat board || fail "board, edited"; assert_eq "$(methods | tr '\n' ' ')" "editMessageText " "one edit, no new post"
  assert_eq "$(field "$(req_of editMessageText)" 'd["message_id"]')" "$id" "the same message is edited"
  field "$(req_of editMessageText)" 'd["text"]' | grep -q '^● web' || fail "the edit shows web busy"
  # "not modified" is success; an agent's end edits it to done; a start adds a row
  ended web; age_board; reset; printf '400 {"ok":false,"description":"Bad Request: message is not modified"}' > "$SRV/ans.editMessageText"
  bin/chat board || fail "not modified counts as success"; assert_eq "$(methods | tr '\n' ' ')" "editMessageText " "no re-post on not modified"
  agent infra ops/infra ops idle; age_board; reset; bin/chat board || fail "board after a start"
  field "$(req_of editMessageText)" 'd["text"]' > "$W/board"
  grep -q '^✓ web · projects/web · done' "$W/board" || fail "an ended agent shows done [$(cat "$W/board")]"
  grep -q '^○ infra · ops/infra · ops · ' "$W/board" || fail "a new agent has a row"
  # only "message to edit not found" posts and pins a new board; another failure posts nothing
  set_status api idle; age_board; reset; printf '500 {"ok":false,"description":"Internal Server Error"}' > "$SRV/ans.editMessageText"
  bin/chat board 2> "$W/err"; assert_eq "$?" 1 "a failed edit"; assert_eq "$(methods | tr '\n' ' ')" "editMessageText " "nothing re-posted"
  age_board; reset; printf '400 {"ok":false,"description":"Bad Request: message to edit not found"}' > "$SRV/ans.editMessageText"
  bin/chat board || fail "board after the message was deleted"
  assert_eq "$(methods | tr '\n' ' ')" "editMessageText sendMessage pinChatMessage " "a deleted board is posted and pinned again"
  [ "$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["message_id"])' "$S/chat/board.json")" != "$id" ] || fail "the new id is kept"
  ended infra
}

links_owner_only() {   # AC2
  agent My.Web-App projects/web - idle; age_board; reset; bin/chat board || fail "board"
  field "$(req_of editMessageText)" 'd["text"]' > "$W/board"
  grep -qx '/update_api /log_api /shot_api /stop_api' "$W/board" || fail "api's links [$(cat "$W/board")]"
  grep -qx '/update_my_web_app /log_my_web_app /shot_my_web_app /stop_my_web_app' "$W/board" || fail "a name normalised"
  reset; act "$OWNER" 801 "/log_my_web_app 5"; assert_eq "$RC" 0 "a normalised link resolves [$(cat "$W/err")]"
  # each command at most 32 characters
  local long=abcdefghij-abcdefghij-abcdefghij-abc; agent "$long" projects/web - idle; age_board; reset; bin/chat board || fail "board, long name"
  field "$(req_of editMessageText)" 'd["text"]' | tr ' ' '\n' | grep '^/' | while read -r c; do [ "${#c}" -le 33 ] || fail "a command over 32 characters: $c"; done
  ended "$long"; ended My.Web-App
  # two agents whose links collide: the link gets the listing
  agent a-b projects/web - idle; agent a.b ops/infra - idle; reset; act "$OWNER" 802 "/log_a_b"; assert_eq "$RC" 2 "a collision"
  field "$(req_of sendMessage)" 'd["text"]' | grep -q "no single agent" || fail "the collision gets the listing"
  ended a-b; ended a.b
  # anyone but the paired, locked owner: nothing done, one log line without the id
  local n0; n0="$({ wc -l < "$S/logs/chat.log"; } 2>/dev/null || echo 0)"; reset; : > "$FAKE_NOTIFY"
  act "$OTHER" 803 "/update_api"; assert_eq "$RC" 2 "another sender"; assert_eq "$(reqs)" 0 "nothing sent"
  assert_eq "$(wc -c < "$FAKE_NOTIFY" | tr -d ' ')" 0 "nothing notified"
  assert_eq "$(( $(wc -l < "$S/logs/chat.log") - n0 ))" 1 "one log line"; grep -q "$OTHER" "$S/logs/chat.log" && fail "the log names the sender"
  act "" 803 "/update_api"; assert_eq "$RC" 2 "no sender"; assert_eq "$(reqs)" 0 "nothing sent"
  access "{\"dmPolicy\": \"pairing\", \"allowFrom\": [\"$OWNER\"], \"groups\": {}}"; act "$OWNER" 803 "/update_api"
  assert_eq "$RC" 2 "a channel not locked"; assert_eq "$(reqs)" 0 "nothing sent"; locked
}

update_round_trip() {   # AC3
  for t in "/update_api" "/update api" "/update_api@some_bot"; do reset; : > "$FAKE_NOTIFY"; act "$OWNER" 810 "$t"
    assert_eq "$RC" 0 "$t [$(cat "$W/err")]"; assert_eq "$(grep -c . "$FAKE_NOTIFY")" 1 "$t: one notify"
    grep -q '^\[--from\]\[main\]\[projects/api\]\[.*bin/notify main' "$FAKE_NOTIFY" || fail "$t: to api, saying how to answer [$(cat "$FAKE_NOTIFY")]"
    assert_eq "$(field "$(req_of sendMessage)" 'd["reply_parameters"]["message_id"]')" 810 "$t: the reply threads on the request"; done
  # the agent's reply comes back through the forwarder, tagged with its folder
  rm -f "$S/events.jsonl" "$S/chat/forward.cursor"; ev --from projects/api --to main --kind note --text "doing: the login form. next: its tests"
  reset; bin/chat forward > "$W/out" 2>&1 || fail "forward [$(cat "$W/out")]"
  field "$(req_of sendMessage)" 'd["text"]' | grep -q '^\[projects/api, claimed\] note: "doing: the login form' || fail "the reply is posted tagged [projects/api]"
  # bare /update: the agents' links
  reset; act "$OWNER" 811 "/update"; field "$(req_of sendMessage)" 'd["text"]' | grep -q '^/update_api' || fail "a bare /update lists the links"
}

log_redacted_and_sized() {   # AC4
  local d="$CLAUDE_HOME/projects/$(printf '%s' "$HUB/projects/api" | sed 's/[^A-Za-z0-9]/-/g')"; mkdir -p "$d"
  python3 - "$d/sid-api.jsonl" "$KEY" "$K" <<'PY'
import json, sys
p, key, tok = sys.argv[1:]; pad = " and some padding words to make the line longer" * 2
with open(p, "w") as f:
    for i in range(60):
        who = "user" if i % 2 else "assistant"
        text = "line %d%s" % (i, pad)
        if i == 55: text = "the key is %s and the token %s" % (key, tok)
        f.write(json.dumps({"type": who, "timestamp": "2026-11-24T10:%02d:00Z" % i, "message": {"role": who, "content": [{"type": "text", "text": text}]}}) + "\n")
PY
  reset; act "$OWNER" 820 "/log api 20"; assert_eq "$RC" 0 "/log api 20 [$(cat "$W/err")]"
  field "$(req_of sendMessage)" 'd["text"]' > "$W/log"
  assert_eq "$(grep -c ': line [0-9]* and some' "$W/log")" 19 "the last 20 lines (one of them the key's)"
  grep -q 'line 59 and' "$W/log" || fail "the newest line"; grep -q 'line 39 and' "$W/log" && fail "older than 20 lines"
  grep -qF "$KEY" "$W/log" && fail "the planted key reached the chat"; grep -qF "$K" "$W/log" && fail "the token reached the chat"
  grep -q '<hidden key>' "$W/log" || fail "the key is hidden by redact"
  # the default, 50 lines, is over 4096 characters: a .txt document
  reset; act "$OWNER" 821 "/log_api"; assert_eq "$RC" 0 "/log_api [$(cat "$W/err")]"
  assert_eq "$(methods | tr '\n' ' ')" "sendDocument " "a long log goes as a document"
  part "$(req_of sendDocument)" document | grep -q ' api-log.txt$' || fail "a .txt file"
  file_bytes "$(req_of sendDocument)" document > "$W/doc"; assert_eq "$(grep -c ': line [0-9]* and some' "$W/doc")" 49 "50 lines"
  grep -qF "$KEY" "$W/doc" && fail "the key in the document"; grep -qF "$K" "$W/doc" && fail "the token in the document"
  assert_eq "$(part "$(req_of sendDocument)" reply_parameters | python3 -c 'import json,sys; print(json.load(sys.stdin)["message_id"])')" 821 "threaded"
  # a key across the 300-character cut of a line: redact runs first, so no piece of it survives (review, fix round)
  local KEY40; KEY40="$(printf 'w%.0s' $(seq 40))"
  python3 - "$d/sid-api.jsonl" "$KEY40" <<'PY2'
import json, sys
p, key = sys.argv[1:]; text = "word " * 52 + "ab " + key + " and the rest of the line"
open(p, "a").write(json.dumps({"type": "assistant", "timestamp": "2026-11-24T11:00:00Z", "message": {"role": "assistant", "content": [{"type": "text", "text": text}]}}) + "\n")
PY2
  reset; act "$OWNER" 823 "/log api 1"; assert_eq "$RC" 0 "/log api 1 [$(cat "$W/err")]"; field "$(req_of sendMessage)" 'd["text"]' > "$W/log"
  grep -q 'wwwww' "$W/log" && fail "a piece of a key across the cut reached the chat [$(tail -c 60 "$W/log")]"
  grep -q "word word" "$W/log" || fail "the line is shown"
  agent web projects/web - idle; reset; act "$OWNER" 822 "/log web"; assert_eq "$RC" 0 "an agent with no transcript [$(cat "$W/err")]"
  field "$(req_of sendMessage)" 'd["text"]' | grep -q "no log" || fail "it says so"; ended web
}

screenshots_posted() {   # AC5
  local B="projects/api/reports/browser"; mkdir -p "$B"
  png() { python3 -c 'import sys; open(sys.argv[1], "wb").write(b"\x89PNG\r\n\x1a\n" + b"px" * 50)' "$1"; }
  png "$B/old.png"; touch -t 202001010000 "$B/old.png"
  reset; bin/chat shots 2> "$W/err" || fail "shots, none new [$(cat "$W/err")]"; assert_eq "$(reqs)" 0 "a file from before the agent started is not posted"
  png "$B/checkout.png"; reset; bin/chat shots 2> "$W/err" || fail "shots [$(cat "$W/err")]"
  assert_eq "$(methods | tr '\n' ' ')" "sendPhoto " "one new screenshot, one photo"
  assert_eq "$(part "$(req_of sendPhoto)" caption)" "[api] checkout" "captioned with the agent"
  assert_eq "$(part "$(req_of sendPhoto)" chat_id)" "$OWNER" "to the owner"
  reset; bin/chat shots; assert_eq "$(reqs)" 0 "never posted twice"
  png "$B/step-1.png"; png "$B/step-2.png"; png "$B/step-3.png"; reset; bin/chat shots || fail "shots, three"
  assert_eq "$(methods | tr '\n' ' ')" "sendMediaGroup " "three from one step: one album"
  part "$(req_of sendMediaGroup)" media | python3 -c 'import json, sys
m = json.load(sys.stdin); assert len(m) == 3 and all(x["type"] == "photo" for x in m), m
assert m[0]["caption"] == "[api] step-1, step-2, step-3" and all("caption" not in x for x in m[1:]), m' || fail "the album's media and caption"
  # refused files (C8): not an image, a link, a .env name, a hard link to a key folder's file: never posted
  printf 'not an image\n' > "$B/fake.png"; ln -s "$W/../x.png" "$B/link.png"; png "$W/real.png"; ln -s "$W/real.png" "$B/real-link.png"
  png "$B/.env.png"; cp "$B/checkout.png" "$B/prod.env"; mkdir -p "$HOME/.ssh"; png "$HOME/.ssh/k.png"; ln "$HOME/.ssh/k.png" "$B/hard.png" 2>/dev/null
  reset; bin/chat shots; assert_eq "$(reqs)" 0 "refused files are never posted"
  # a key-shaped file name never reaches a caption
  png "$B/$KEY.png"; reset; bin/chat shots || fail "shots, key name"; part "$(req_of sendPhoto)" caption | grep -qF "$KEY" && fail "a key in a caption"
  # a backlog: 520 new files, at most 30 a run, every one posted exactly once, then nothing (review, fix round)
  rm -rf "$B"; mkdir -p "$B"; python3 - "$B" <<'PY2'
import os, sys, time
b = sys.argv[1]; t = time.time_ns() + 10**9
for i in range(520):
    p = os.path.join(b, "s%03d.png" % i); open(p, "wb").write(b"\x89PNG\r\n\x1a\n" + b"px" * 50); os.utime(p, ns=(t + i * 10**6, t + i * 10**6))
PY2
  : > "$W/posted"; local runs=0
  while :; do reset; bin/chat shots 2> "$W/err" || fail "shots, backlog [$(cat "$W/err")]"; [ "$(reqs)" -gt 0 ] || break
    runs=$((runs + 1)); [ "$runs" -le 20 ] || fail "the backlog never ends"
    for i in $(ls "$SRV" | sed -n 's/^req\.//p'); do grep -ao 'filename="s[0-9]*\.png"' "$SRV/req.$i"; done >> "$W/posted"
    [ "$(grep -c . "$W/posted")" -le $((runs * 30)) ] || fail "over 30 in one run"; done
  assert_eq "$(sort -u "$W/posted" | grep -c .)" 520 "every file of the backlog posted"
  assert_eq "$(grep -c . "$W/posted")" 520 "each exactly once"
  reset; bin/chat shots; assert_eq "$(reqs)" 0 "a later run posts nothing old"
  rm -rf "$B"
}

stop_needs_confirmation() {   # AC6
  agent doomed projects/web - busy; local p n; p="$(pid_of doomed)"
  reset; act "$OWNER" 830 "/stop_doomed"; assert_eq "$RC" 0 "/stop_doomed [$(cat "$W/err")]"
  n="$(field "$(req_of sendMessage)" 'd["reply_markup"]["keyboard"][0][0]["text"]')"
  [[ "$n" =~ ^/stop_doomed_[0-9]{4}$ ]] || fail "a one-time keyboard with the confirmation [$n]"
  assert_eq "$(field "$(req_of sendMessage)" '[b["text"] for b in d["reply_markup"]["keyboard"][0]][1]')" /cancel "and /cancel"
  assert_eq "$(field "$(req_of sendMessage)" 'd["reply_markup"]["one_time_keyboard"]')" true "one time"
  kill -0 "$p" || fail "the agent is not stopped before the confirmation"
  act "$OWNER" 831 "/stop_doomed_$(printf '%04d' $(( (10#${n##*_} + 1) % 10000 )))"; kill -0 "$p" || fail "a wrong nonce stopped it"
  act "$OTHER" 832 "$n"; assert_eq "$RC" 2 "another sender's confirmation"; kill -0 "$p" || fail "another sender stopped it"
  # expired after 120 s
  for f in "$S"/chat/stops/*; do python3 -c 'import json, sys; p = sys.argv[1]; d = json.load(open(p)); d["time"] -= 121; json.dump(d, open(p, "w"))' "$f"; done
  reset; act "$OWNER" 833 "$n"; kill -0 "$p" || fail "an expired nonce stopped it"; field "$(req_of sendMessage)" 'd["text"]' | grep -q "expired" || fail "it says expired"
  # a fresh one, from the owner, in time: stopped once, the keyboard removed, the board shows it
  reset; act "$OWNER" 834 "/stop doomed"; n="$(field "$(req_of sendMessage)" 'd["reply_markup"]["keyboard"][0][0]["text"]')"
  age_board; reset; act "$OWNER" 835 "$n"; assert_eq "$RC" 0 "the confirmation [$(cat "$W/err")]"
  wait_for "! kill -0 $p 2>/dev/null" || fail "the agent was not stopped"
  assert_eq "$(field "$(req_of sendMessage)" 'd["reply_markup"]["remove_keyboard"]')" true "the keyboard is removed"
  field "$(req_of editMessageText)" 'd["text"]' | grep -q "^✓ doomed · projects/web · done" || fail "the board shows it stopped [$(field "$(req_of editMessageText)" 'd["text"]')]"
  grep -q "stopped doomed" journal/*.md || fail "the stop is journaled"
  agent doomed projects/web - busy; p="$(pid_of doomed)"; reset; act "$OWNER" 836 "$n"; kill -0 "$p" || fail "a used nonce stopped it again"
  # a nonce made for one agent never stops another (review, fix round)
  agent other projects/api - busy; local q; q="$(pid_of other)"; reset; act "$OWNER" 839 "/stop_other"
  n="$(field "$(req_of sendMessage)" 'd["reply_markup"]["keyboard"][0][0]["text"]')"
  act "$OWNER" 840 "/stop_doomed_${n##*_}"; kill -0 "$p" || fail "another agent's nonce stopped doomed"; kill -0 "$q" || fail "a nonce under another name stopped its agent"
  ended other
  # a new nonce never replaces a pending one: with all but one number taken, the free one is handed out
  rm -rf "$S/chat/stops"; mkdir -p "$S/chat/stops"; python3 - "$S/chat/stops" <<'PY2'
import json, os, sys, time
for i in range(10000):
    if i != 4321: open(os.path.join(sys.argv[1], "%04d" % i), "w").write(json.dumps({"name": "x", "folder": "projects/x", "link": "x", "time": int(time.time())}))
PY2
  reset; act "$OWNER" 841 "/stop_doomed"; assert_eq "$(field "$(req_of sendMessage)" 'd["reply_markup"]["keyboard"][0][0]["text"]')" /stop_doomed_4321 "the one free number"
  assert_eq "$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["link"])' "$S/chat/stops/0000")" x "a pending stop is kept"
  rm -rf "$S/chat/stops"
  reset; act "$OWNER" 837 "/stop_doomed"; act "$OWNER" 838 "/cancel"; assert_eq "$(ls "$S/chat/stops" | grep -c .)" 0 "/cancel drops the pending stop"
  assert_eq "$(field "$(req_of sendMessage)" 'd["reply_markup"]["remove_keyboard"]')" true "and removes the keyboard"
  ended doomed
}

command_menu() {   # AC7
  printf '#!/bin/bash\necho $$ > "${TELEGRAM_STATE_DIR}/bot.pid"\nexit 0\n' > "$FAKE/bin/claude"
  printf '#!/bin/bash\nexit 0\n' > "$FAKE/bin/bun"; printf '#!/bin/bash\nexit 0\n' > "$FAKE/bin/launchctl"; chmod +x "$FAKE"/bin/*
  # start runs bin/recover, which clears registry entries that no bin/work launcher holds (the fake agents'): kept aside
  rm -rf "$W/sessions"; cp -Rp "$S/sessions" "$W/sessions"
  reset; PATH="$FAKE/bin:$PATH" AGENT_LAUNCHAGENTS="$(mktemp -d)" AGENT_CHAT_FORWARD_EVERY=0 bin/chat start </dev/null > "$W/out" 2>&1 || fail "start [$(cat "$W/out")]"
  wait_for "req_of setMyCommands >/dev/null" || fail "start set no menu [$(methods)]"
  assert_eq "$(field "$(req_of setMyCommands)" '" ".join(c["command"] for c in d["commands"])')" "agents update log shot to" "the five commands"
  assert_eq "$(field "$(req_of setMyCommands)" 'd["scope"]["type"]')" chat "scope chat"
  assert_eq "$(field "$(req_of setMyCommands)" 'str(d["scope"]["chat_id"])')" "$OWNER" "the owner's chat"
  grep -Eq '"command": ?"(start|help|status)"' "$(req_of setMyCommands)" && fail "a plugin command in the menu"
  access "{\"dmPolicy\": \"pairing\", \"allowFrom\": [\"$OWNER\"], \"groups\": {}}"; reset; bin/chat menu 2>/dev/null; assert_eq "$?" 2 "no menu unless locked"
  assert_eq "$(reqs)" 0 "nothing sent"; locked; rm -f "$S/chat/chat.pid"; rm -rf "$S/chat/lock"
  rm -rf "$S/sessions"; cp -Rp "$W/sessions" "$S/sessions"
}

task_thread() {   # AC8
  rm -f "$S/events.jsonl" "$S/chat/forward.cursor"; reset
  bin/chat thread api 4242 || fail "thread"; ev --from projects/api --to main --kind note --text "halfway"
  bin/chat forward >/dev/null 2>&1 || fail "forward"
  assert_eq "$(field "$(req_of sendMessage)" 'd["reply_parameters"]["message_id"]')" 4242 "the agent's message replies to the request"
  ev --from projects/api --to main --kind idle --text "finished"; reset; bin/chat done --agent api "Done: the login works" > "$W/out" 2>&1 || fail "done [$(cat "$W/out")]"
  assert_eq "$(methods | tr '\n' ' ')" "sendMessage sendMessage " "the queued event, then the Done"
  local last; last="$(req_of sendMessage 2)"
  assert_eq "$(field "$last" 'd["text"]')" "$(printf 'Done: the login works\n/log_api /shot_api /diff_api')" "Done is last, with the links"
  assert_eq "$(field "$last" 'd["reply_parameters"]["message_id"]')" 4242 "Done replies to the request"
  ev --from projects/api --to main --kind note --text "after"; reset; bin/chat forward >/dev/null 2>&1
  assert_eq "$(field "$(req_of sendMessage)" '"reply_parameters" in d')" false "the thread ends with its Done"
  reset; bin/chat done --reply-to 77 "Not done: blocked" >/dev/null 2>&1 || fail "done --reply-to"
  assert_eq "$(field "$(req_of sendMessage)" 'd["reply_parameters"]["message_id"]')" 77 "done --reply-to"
  bin/chat thread api 12x >/dev/null 2>&1; assert_eq "$?" 2 "a message id is digits"
  # /diff: the agent's diff stat as a document
  git -C projects/api init -q 2>/dev/null; echo a > projects/api/f.txt; git -C projects/api add f.txt; git -C projects/api -c user.name=t -c user.email=t@t commit -qm a
  echo b >> projects/api/f.txt; reset; act "$OWNER" 840 "/diff_api"; assert_eq "$RC" 0 "/diff_api [$(cat "$W/err")]"
  file_bytes "$(req_of sendDocument)" document | grep -q 'f.txt' || fail "the diff stat [$(field "$(req_of sendMessage)" 'd["text"]')]"
}

no_poller_no_callbacks() {   # AC9
  [ -s "$SRV/all" ] || fail "the stand-in saw nothing"
  grep -Eq '/(getUpdates|setWebhook|deleteWebhook)	' "$SRV/all" && fail "a poller or webhook call [$(grep -E 'getUpdates|Webhook' "$SRV/all" | cut -c1-80)]"
  grep -q 'callback_data' "$SRV/all" && fail "a hub message carried callback_data"; grep -q '"perm:' "$SRV/all" && fail "a perm: prefix"
  grep -nE 'setWebhook|deleteWebhook' bin/* && fail "a webhook call in bin/"
  assert_eq "$(grep -l getUpdates bin/* | tr '\n' ' ')" "bin/chat " "getUpdates only in bin/chat (its stopped-only test, story H1)"
  grep -q 'getUpdates' bin/console.py && fail "the console polls"
  assert_eq "$(bash -c '. bin/lib.sh; channel_buttons telegram')" permission "Telegram never gets callback buttons"
  true
}

nothing_leaks() {   # AC10
  mkdir -p "$W/ps"; cat > "$W/watch.py" <<'PY'
import subprocess, sys, time
p = subprocess.Popen(["bin/chat", "act", "--from", sys.argv[1], "--reply-to", "850"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
p.stdin.write(b"/log_api\n"); p.stdin.close(); seen = b""
while p.poll() is None:
    seen += subprocess.run(["ps", "-A", "-o", "command="], capture_output=True).stdout; time.sleep(0.01)
open(sys.argv[2], "wb").write(seen); sys.exit(p.returncode)
PY
  reset; python3 "$W/watch.py" "$OWNER" "$W/ps/list" || fail "act under watch"
  grep -qF "$K" "$W/ps/list" && fail "the token in a process argument"; grep -qF "$KEY" "$W/ps/list" && fail "the key in a process argument"
  grep -F "$OWNER" "$W/ps/list" | grep -v -e 'chat act --from' -e 'watch.py' | grep -q . && fail "the owner's id in an argument the hub made [$(grep -F "$OWNER" "$W/ps/list" | grep -v -e 'chat act' -e watch.py | head -2)]"
  grep -qF "$K" "$STORE.argv" && fail "the token in a security argument"
  grep -rqF -e "$K" -e "$KEY" -e "$OWNER" -e "$OTHER" "$S/logs" journal 2>/dev/null && fail "a token, key or id in a log or the journal"
  grep -qF -e "$K" -e "$OWNER" "$S/chat/board.json" && fail "a token or id in board.json"
  grep -F "$K" "$SRV"/all | grep -qv "^/bot$K/" && fail "the token outside a request's address"
  grep -qF "$KEY" "$SRV/all" && fail "the key reached the chat"
  grep -q "$OWNER" "$W/out" "$W/err" 2>/dev/null && fail "the id printed"
  true
}

documented() {
  for s in "bin/chat act" "board.json" "/log_<agent>" "sendMediaGroup" "setMyCommands" "bin/chat thread" "0007"; do
    assert_contains .ade/context/chat.md "$s" "the contract"; done
  assert_contains templates/hub/CLAUDE.md "bin/chat act --from <user_id>" "the hub rule routes commands to act"
  ls .ade/context/decisions/0007-*.md >/dev/null 2>&1 || fail "the ADR"; grep -q "Status: Accepted" .ade/context/decisions/0007-*.md || fail "accepted"
  assert_contains docs/stories/C9-telegram-agent-console.md "tests/test_console.sh" "the story names its tests"
  bin/chat 2>&1 | grep -q 'act --from <id>' || fail "the usage names act"
}

# bash tests/test_console.sh <check>: run one check
ALL="board_edited_in_place links_owner_only update_round_trip log_redacted_and_sized screenshots_posted stop_needs_confirmation command_menu task_thread no_poller_no_callbacks nothing_leaks documented"
if [ $# -gt 0 ]; then for c in "$@"; do "$c"; done; echo ok; exit 0; fi
for c in $ALL; do "$c"; done
echo ok
