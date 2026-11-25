# A stand-in for a Onetime Secret instance's anonymous v3 guest API (story I6, .ade/context/onetime-secret.md), so
# tests never reach the internet. argv: <port file> <log file> [ok|error|hang]. Every request is logged as one JSON
# line (method, path, content type, body). ok: conceal stores, reveal returns once then 404; error: 500 to everything;
# hang: answers nothing for 30 s (the client's timeout fires first); badid: conceal answers 200 with an id "x/../..".
import json, secrets, string, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
MODE = sys.argv[3] if len(sys.argv) > 3 else "ok"
STORE = {}
ALNUM = string.ascii_lowercase + string.digits
def new_id(): return "".join(secrets.choice(ALNUM) for _ in range(62))
class H(BaseHTTPRequestHandler):
    def reply(self, code, obj):
        out = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out))); self.end_headers(); self.wfile.write(out)
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0); raw = self.rfile.read(n).decode("utf-8", "replace")
        with open(sys.argv[2], "a") as f:
            f.write(json.dumps({"method": "POST", "path": self.path, "type": self.headers.get("Content-Type"), "body": raw}) + "\n")
        if MODE == "hang": time.sleep(30); return
        if MODE == "error": return self.reply(500, {"message": "Internal error (fake)"})
        try: body = json.loads(raw)
        except ValueError: return self.reply(422, {"message": "Incorrect payload format"})
        p = self.path.split("/")
        if self.path == "/api/v3/guest/secret/conceal":
            s = body.get("secret") if isinstance(body, dict) else None
            if not isinstance(s, dict) or not s.get("secret"): return self.reply(422, {"message": "You did not provide anything to share"})
            ttl = int(s.get("ttl") or 604800); sid = new_id(); STORE[sid] = s["secret"]
            if MODE == "badid": sid = "x/../.."
            return self.reply(200, {"success": True, "record": {"receipt": {"identifier": new_id(), "secret_ttl": ttl},
                "secret": {"identifier": sid, "key": sid, "secret_ttl": ttl, "state": "new"}}, "details": {"kind": "conceal"}})
        if len(p) == 7 and p[1:5] == ["api", "v3", "guest", "secret"] and p[6] == "reveal":
            if p[5] in STORE and body.get("continue") is True:
                v = STORE.pop(p[5])
                return self.reply(200, {"record": {"secret": {"identifier": p[5], "state": "revealed"}, "secret_value": v},
                    "details": {"continue": True, "show_secret": True}})
            return self.reply(404, {"message": "Unknown secret"})
        return self.reply(404, {"message": "Not Found"})
    def do_GET(self):
        with open(sys.argv[2], "a") as f: f.write(json.dumps({"method": "GET", "path": self.path}) + "\n")
        self.reply(404, {"message": "Not Found"})
    def log_message(self, *a): pass
s = ThreadingHTTPServer(("127.0.0.1", 0), H); s.daemon_threads = True
open(sys.argv[1], "w").write(str(s.server_port)); s.serve_forever()
