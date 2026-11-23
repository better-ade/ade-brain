#!/bin/bash
# bin/chat send: one image or file to the paired, locked owner (.ade/context/chat.md). A stand-in for the Bot API on
# 127.0.0.1, a fake security; never the network, a real bot or a real token.
. "$(dirname "$0")/helpers.sh"
make_hub; cd "$HUB"; stub_security; export AGENT_STATE="$(mktemp -d)"; export HOME="$(mktemp -d)"
unset TELEGRAM_BOT_TOKEN TELEGRAM_STATE_DIR HUB_CHAT HUB_CHANNELS HUB_CHAT_MODE CLAUDE_CONFIG_DIR AGENT_CHAT_SEND
W="$(mktemp -d)"; W="$(cd "$W" && pwd -P)"; CH="$AGENT_STATE/channels/telegram"; OWNER=99887766
# a made-up token, put together here so that no file of the repository holds its text
K="$(printf '%s:%s' 100000001 "$(printf 'made-up-%s-' not a real bot token at all)")"
access() { mkdir -p "$CH"; printf '%s\n' "$1" > "$CH/access.json"; }
locked() { access "{\"dmPolicy\": \"allowlist\", \"allowFrom\": [\"$OWNER\"], \"groups\": {}}"; }
wait_for() { local i=0; while ! eval "$1"; do i=$((i+1)); [ $i -lt 100 ] || return 1; sleep 0.1; done; }
# files: a PNG and a JPEG by their first bytes, a text file, and one over each cap (sparse past the header)
python3 - "$W" <<'PY'
import os, sys
w = sys.argv[1]; png = b"\x89PNG\r\n\x1a\n" + b"pixels" * 20
open(w + "/shot.png", "wb").write(png); open(w + "/photo.jpg", "wb").write(b"\xff\xd8\xff\xe0" + b"jfif" * 20)
open(w + "/notes.txt", "w").write("a report\n"); open(w + "/fake.png", "w").write("not an image\n"); open(w + "/empty.png", "w").close()
for n, size in (("big.png", 10 * 1024 * 1024 + 1), ("big.bin", 20 * 1024 * 1024 + 1)):
    with open(w + "/" + n, "wb") as f: f.write(png); f.truncate(size)
with open(w + "/ten.png", "wb") as f: f.write(png); f.truncate(10 * 1024 * 1024)
PY
# the stand-in Bot API: each request's path, content type and body to $SRV/req.<n>; FAKE_API_ANSWER sets the reply.
# It ends itself after 120 s and is killed when the test exits, passed or failed.
SRV="$(mktemp -d)"
cat > "$SRV/api.py" <<'PYS'
import http.server, os, signal, socketserver, sys
signal.alarm(120); d = sys.argv[1]; n = [0]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        b = self.rfile.read(int(self.headers.get("Content-Length", 0))); n[0] = len([f for f in os.listdir(d) if f.startswith("req.")]) + 1
        open("%s/req.%d" % (d, n[0]), "wb").write((self.path + "\n" + self.headers.get("Content-Type", "") + "\n").encode() + b)
        code, body = 200, b'{"ok":true}'
        if os.path.exists(d + "/answer"):
            code, _, text = open(d + "/answer").read().partition(" "); code = int(code); body = text.encode()
        self.send_response(code); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
s = socketserver.TCPServer(("127.0.0.1", 0), H); open(d + "/port", "w").write(str(s.server_address[1])); s.serve_forever()
PYS
python3 "$SRV/api.py" "$SRV" </dev/null >/dev/null 2>"$SRV/err" & srv=$!; trap 'kill "$srv" 2>/dev/null' EXIT
wait_for "[ -s '$SRV/port' ]" || fail "the stand-in API did not start [$(tail -n 5 "$SRV/err")]"
export AGENT_TELEGRAM_API="http://127.0.0.1:$(cat "$SRV/port")"
reqs() { ls "$SRV" | grep -c '^req\.'; }
reset() { rm -f "$SRV"/req.* "$SRV/answer" "$W/out" "$W/err"; }
# send <stdin text or ""> <args...>: bin/chat send with the caption on stdin; RC, $W/out and $W/err
send() { local cap="$1"; shift; printf '%s' "$cap" | bin/chat send "$@" > "$W/out" 2> "$W/err"; RC=$?; }
# part <request file> <field>: that multipart field's value (the file field: its bytes' length and file name)
part() { python3 - "$1" "$2" <<'PY'
import re, sys
raw = open(sys.argv[1], "rb").read(); path, ctype, body = raw.split(b"\n", 2)
b = b"--" + ctype.split(b"boundary=")[1]
for p in body.split(b)[1:-1]:
    head, _, val = p.partition(b"\r\n\r\n"); val = val[:-2]
    m = re.search(rb'name="([^"]*)"(?:; filename="([^"]*)")?', head)
    if m.group(1).decode() == sys.argv[2]:
        if m.group(2) is not None: print(len(val), m.group(2).decode(), re.search(rb"Content-Type: (\S+)", head).group(1).decode())
        else: print(val.decode())
PY
}
printf '%s\n' "$K" | bin/keys set telegram >/dev/null 2>&1 || fail "bin/keys set telegram"

send_photo_to_locked_owner() {
  locked; reset; send "the checkout page after the fix" "$W/shot.png"
  assert_eq "$RC" 0 "a PNG to the locked owner [$(cat "$W/err")]"; assert_eq "$(reqs)" 1 "one request"
  assert_eq "$(head -1 "$SRV/req.1")" "/bot$K/sendPhoto" "sendPhoto, the token in the path only"
  assert_eq "$(part "$SRV/req.1" chat_id)" "$OWNER" "to the paired owner"
  assert_eq "$(part "$SRV/req.1" caption)" "the checkout page after the fix" "the caption"
  assert_eq "$(part "$SRV/req.1" photo)" "$(wc -c < "$W/shot.png" | tr -d ' ') shot.png image/png" "the file's bytes, name and type"
  assert_contains "$W/out" "sent shot.png to the paired owner" "it says so"
  grep -q "chat: sent a photo to the owner (shot.png, " journal/*.md || fail "the send is journaled"
  reset; send "" "$W/photo.jpg"; assert_eq "$RC" 0 "a JPEG [$(cat "$W/err")]"; assert_eq "$(part "$SRV/req.1" photo | awk '{print $3}')" "image/jpeg" "its type"
  assert_eq "$(part "$SRV/req.1" caption)" "" "no caption field without a caption"
  reset; send "" "$W/ten.png"; assert_eq "$RC" 0 "an image of exactly 10 MB"
}

send_document() {
  locked; reset; send "the report" --document "$W/notes.txt"; assert_eq "$RC" 0 "a document [$(cat "$W/err")]"
  assert_eq "$(head -1 "$SRV/req.1")" "/bot$K/sendDocument" "sendDocument"
  assert_eq "$(part "$SRV/req.1" document)" "9 notes.txt application/octet-stream" "the file"
  reset; send "" --document "$W/big.bin"; assert_eq "$RC" 2 "over 20 MB"; assert_contains "$W/err" "over 20 MB" "it says why"
  assert_eq "$(reqs)" 0 "nothing sent"
}

only_images_as_photos() {
  locked; local f
  for f in fake.png notes.txt; do reset; send "" "$W/$f"; assert_eq "$RC" 2 "$f is not an image"
    assert_contains "$W/err" "not a PNG or JPEG image" "it says why"; assert_eq "$(reqs)" 0 "nothing sent ($f)"; done
  reset; send "" "$W/big.png"; assert_eq "$RC" 2 "an image over 10 MB"; assert_contains "$W/err" "over 10 MB" "it says why"
  reset; send "" "$W/empty.png"; assert_eq "$RC" 2 "an empty file"; assert_eq "$(reqs)" 0 "nothing sent"
  reset; send "" "$W/none.png"; assert_eq "$RC" 2 "a missing file"; assert_contains "$W/err" "no such file" "it says why"
  bin/chat send >/dev/null 2>&1; assert_eq "$?" 2 "no file named"
  bin/chat send "$W/shot.png" extra >/dev/null 2>&1 </dev/null; assert_eq "$?" 2 "two files"; assert_eq "$(reqs)" 0 "nothing sent"
}

refused_unless_locked() {
  local a
  for a in '{"dmPolicy": "pairing", "allowFrom": ["99887766"], "groups": {}}' \
           '{"dmPolicy": "allowlist", "allowFrom": ["99887766", "111"], "groups": {}}' \
           '{"dmPolicy": "allowlist", "allowFrom": ["99887766"], "groups": {"-100123": {}}}' \
           '{"dmPolicy": "allowlist", "allowFrom": [99887766], "groups": {}}' \
           '{"policy": "allowlist", "allowFrom": ["99887766"]}' 'not json'; do
    access "$a"; reset; send "x" "$W/shot.png"; assert_eq "$RC" 2 "not locked [$a]"
    assert_contains "$W/err" "is not locked to you" "it says so"; assert_eq "$(reqs)" 0 "nothing sent [$a]"; done
  rm -f "$CH/access.json"; reset; send "x" "$W/shot.png"; assert_eq "$RC" 2 "not paired"
  assert_contains "$W/err" "not paired yet" "it says so"; assert_eq "$(reqs)" 0 "nothing sent, not paired"
  # a link in place of access.json, and an access file others may write: not locked
  locked; mv "$CH/access.json" "$W/real.json"; ln -s "$W/real.json" "$CH/access.json"; reset; send "" "$W/shot.png"; assert_eq "$RC" 2 "access.json is a link"
  rm -f "$CH/access.json"; locked; chmod 666 "$CH/access.json"; reset; send "" "$W/shot.png"; assert_eq "$RC" 2 "access.json writable by others"
  assert_eq "$(reqs)" 0 "nothing sent"; rm -f "$CH/access.json"; locked
}

never_sent_files() {
  locked; local f d
  for d in .ssh .config/gh .aws .gnupg .claude .agent-hub/other/logs; do mkdir -p "$HOME/$d"; cp "$W/shot.png" "$HOME/$d/key.png"
    reset; send "" --document "$HOME/$d/key.png"; assert_eq "$RC" 2 "a file under ~/$d"; assert_eq "$(reqs)" 0 "nothing sent (~/$d)"
    reset; send "" "$HOME/$d/key.png"; assert_eq "$RC" 2 "an image under ~/$d"; done
  mkdir -p "$AGENT_STATE/logs"; cp "$W/shot.png" "$AGENT_STATE/logs/chat.png"; cp "$W/shot.png" "$CH/x.png"
  for f in "$AGENT_STATE/logs/chat.png" "$CH/x.png" "$CH/access.json"; do reset; send "" --document "$f"; assert_eq "$RC" 2 "a file under the state folder"
    assert_contains "$W/err" "never sent" "it says why ($f: $(cat "$W/err"))"; assert_eq "$(reqs)" 0 "nothing sent ($f)"; done
  for f in .env .env.local prod.env; do cp "$W/shot.png" "$W/$f"; reset; send "" --document "$W/$f"; assert_eq "$RC" 2 "$f"
    assert_contains "$W/err" ".env file is never sent" "it says why"; assert_eq "$(reqs)" 0 "nothing sent ($f)"; done
  # not a regular file: a link (to an image, and to a key folder's file), a folder, a pipe; a path through a linked folder
  ln -s "$W/shot.png" "$W/link.png"; ln -s "$HOME/.ssh/key.png" "$W/tokey.png"; mkdir -p "$W/dir.png"; mkfifo "$W/pipe.png"; ln -s "$HOME/.ssh" "$W/sshdir"
  for f in link.png tokey.png dir.png pipe.png sshdir/key.png; do reset; send "" --document "$W/$f"; assert_eq "$RC" 2 "$f is not sent"; assert_eq "$(reqs)" 0 "nothing sent ($f)"; done
  assert_contains "$W/err" "never sent" "a file reached through a linked folder is judged where it really is"
}

token_never_shown() {
  locked; reset; : > "$STORE.argv"; mkdir -p "$W/ps"
  # the process list while a send waits on a slow answer: no argument and no child's environment carries the token
  printf '200 {"ok":true}' > "$SRV/answer"
  cat > "$W/slow.py" <<'PY'
import os, subprocess, sys, time
p = subprocess.Popen(["bin/chat", "send", sys.argv[1]], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
seen = b""
while p.poll() is None:
    seen += subprocess.run(["ps", "-A", "-o", "command="], capture_output=True).stdout; time.sleep(0.02)
out = p.stdout.read(); open(sys.argv[2], "wb").write(seen); open(sys.argv[3], "wb").write(out); sys.exit(p.returncode)
PY
  python3 "$W/slow.py" "$W/shot.png" "$W/ps/list" "$W/out" || fail "the send [$(cat "$W/out")]"
  grep -qF "$K" "$W/ps/list" && fail "the token was in an argument of a process"
  grep -qF "$K" "$W/out" && fail "the token was printed"
  grep -qF "$K" "$STORE.argv" && fail "the token is in a security argument"
  # a failed send says the Bot API's reason, never the address (which holds the token), and keeps nothing
  reset; printf '400 {"ok":false,"description":"Bad Request: wrong file %s"}' "$K" > "$SRV/answer"
  send "cap" "$W/shot.png"; assert_eq "$RC" 1 "the API refused"; assert_contains "$W/err" "HTTP 400: Bad Request: wrong file" "the API's reason"
  grep -qF "$K" "$W/err" "$W/out" && fail "the token was printed with the failure"
  reset; printf '200 {"ok":false}' > "$SRV/answer"; send "" "$W/shot.png"; assert_eq "$RC" 1 "an answer that is not ok"
  reset; AGENT_TELEGRAM_API=http://127.0.0.1:9 send "" "$W/shot.png"; assert_eq "$RC" 1 "the API is down"
  grep -qF "$K" "$W/err" "$W/out" && fail "the token was printed when the API was down"
  reset; AGENT_TELEGRAM_API=http://192.0.2.1 send "" "$W/shot.png"; assert_eq "$RC" 1 "a plain http address is not used"
  assert_contains "$W/err" "not an https address" "it says why"
  [ -z "$(ls "$AGENT_STATE/chat/pending" 2>/dev/null)" ] || fail "a failed file send was kept"
  grep -rqF "$K" "$AGENT_STATE/logs" journal 2>/dev/null && fail "the token reached a log or the journal"
  # no token stored: exit 1, nothing sent
  reset; mv "$STORE" "$STORE.kept"; : > "$STORE"; send "" "$W/shot.png"; assert_eq "$RC" 1 "no token"; assert_contains "$W/err" "no telegram bot token" "it says how"
  mv "$STORE.kept" "$STORE"; assert_eq "$(reqs)" 0 "nothing sent without a token"
}

caption_cleaned() {
  locked; reset; local key; key="sk-$(printf 'x%.0s' 1 2 3 4 5 6 7 8 9 10 11 12)"
  send "$(printf 'line one\nline\ttwo \033[31m%s\r\n--boundary' "$key")" "$W/shot.png"; assert_eq "$RC" 0 "a caption with control characters"
  assert_eq "$(part "$SRV/req.1" caption)" "line one line two <hidden key> --boundary" "one line, no control characters, keys hidden"
  reset; send "$(python3 -c 'print("word " * 400)')" "$W/shot.png"; assert_eq "$RC" 0 "a long caption"
  [ "$(part "$SRV/req.1" caption | wc -c)" -le 1025 ] || fail "the caption is cut to 1024"
  # a file name that is not plain: sent under a plain one
  cp "$W/shot.png" "$W/a\"b c;.png"; reset; send "" "$W/a\"b c;.png"; assert_eq "$RC" 0 "an odd file name [$(cat "$W/err")]"
  assert_eq "$(part "$SRV/req.1" photo | awk '{print $2}')" "a_b_c_.png" "its name in the request"
}

fake_channel() {
  # AGENT_CHAT_SEND (the suite's fake channel): the file's path and caption as JSON, no token read
  locked; reset; printf '#!/bin/bash\ncat >> "%s/fake.sent"\n' "$W" > "$W/fakesend"; chmod +x "$W/fakesend"
  AGENT_CHAT_SEND="$W/fakesend" send "hello" "$W/shot.png"; assert_eq "$RC" 0 "through the fake channel [$(cat "$W/err")]"
  assert_contains "$W/fake.sent" "\"file\": \"$W/shot.png\"" "the file"; assert_contains "$W/fake.sent" '"caption": "hello"' "the caption"
  assert_contains "$W/fake.sent" "\"chat_id\": \"$OWNER\"" "the owner"; assert_eq "$(reqs)" 0 "no Bot API call"
}

needs_owner_permission() {
  # an agent's send, and a capture of the whole screen, wait for the owner's own Allow: the hub root and every focus folder
  for f in .claude/settings.json templates/folder-settings.json; do
    python3 - "$f" "$HUB" <<'PY' || fail "$f: permissions.ask does not cover bin/chat send and ade shot screen"
import fnmatch, json, sys
ask = json.load(open(sys.argv[1]))["permissions"]["ask"]
pats = [r[5:-1] for r in ask if r.startswith("Bash(") and r.endswith(")")]
hit = lambda c: any(fnmatch.fnmatchcase(c, p) for p in pats)
for c in ["bin/chat send shot.png", sys.argv[2] + "/bin/chat send --document /tmp/x <<'EOF'\ncap\nEOF", "ade chat send x.png",
          "cd /x && ade shot screen --yes-screen", "ade shot screen --name desk --yes-screen --tg", "env -u CLAUDECODE ade shot screen",
          "ade shot url https://example.com --tg 'done'", "ade shot agent api --tg"]:
    assert hit(c), c
for c in ["bin/chat status", "bin/chat say hello", "ade shot url https://example.com", "ade shot agent api --name x", "bin/chat forward"]:
    assert not hit(c), c
PY
  done
}

documented() {
  for s in "bin/chat send" "sendPhoto" "sendDocument" "10 MB" "20 MB" "locked" ".env" "ade shot screen"; do
    assert_contains .ade/context/chat.md "$s" "the contract"; done
  assert_contains README.md "bin/chat send" "the README"
  bin/chat 2>&1 | grep -q 'send \[--document\] <file>' || fail "the usage names send"
}

# bash tests/test_chat_send.sh <check>: run one check
ALL="send_photo_to_locked_owner send_document only_images_as_photos refused_unless_locked never_sent_files token_never_shown caption_cleaned fake_channel needs_owner_permission documented"
if [ $# -gt 0 ]; then "$1"; echo ok; exit 0; fi
for c in $ALL; do "$c"; done
echo ok
