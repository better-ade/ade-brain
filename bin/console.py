#!/usr/bin/env python3
"""bin/chat's console for the focus agents (story C9, ADR 0007; contract in .ade/context/chat.md). Called by bin/chat,
never by a person. Every Bot API call goes from here to the one owner the channel is locked to (bin/chat checked
lock_of first; chat.locked_owner reads it again), at chat.api_base. The bot token is the first line of stdin, never an
argument or the environment. Never a poll, a webhook or callback data: actions are command links (/log_api).
Env: H (hub root), S (state dir), ACCESS (access.json), STATE (= S, for chat.read_file), CLAUDE_DIR (claude_home).

  console.py board                 post, pin and edit in place the "Agents" board (<S>/chat/board.json)
  console.py act [REPLY_TO]        one owner command (the rest of stdin; the sender in FROM): /agents, /update, /log, /shot, /diff, /stop
  console.py shots                 post the agents' new screenshots (<folder>/reports/browser): a photo, or an album
  console.py menu                  the bot's command menu for the owner's chat (setMyCommands, scope chat)
  console.py thread FOLDER ID      record (ID) or clear (-) the task thread of a folder; thread-of FOLDER prints it
  console.py norm NAME             the agent part of a command link"""
import calendar, fcntl, json, os, re, secrets, signal, subprocess, sys, time, urllib.error, urllib.request

sys.dont_write_bytecode = True   # no __pycache__ in the hub's bin/
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import chat  # noqa: E402  (bin/chat.py: api_base, locked_owner, read_file)

H = os.environ.get("H", "."); S = os.environ.get("S", ".")
CHAT = os.path.join(S, "chat"); BOARD = os.path.join(CHAT, "board.json"); THREADS = os.path.join(CHAT, "threads.json")
STOPS = os.path.join(CHAT, "stops"); SHOTS = os.path.join(CHAT, "shots.json"); LOG = os.path.join(S, "logs", "chat.log")
GAP = 5            # seconds between two board edits
STOP_TTL = 120     # seconds a stop confirmation lives
ACTIONS = ("update", "log", "shot", "stop")
TOKEN = ""
MENU = [("agents", "the agents and what they do"), ("update", "ask an agent for a two-line status"),
        ("log", "an agent's recent log: /log <agent> [lines]"), ("shot", "an agent's latest screenshot"),
        ("to", "a message to an agent: /to <agent> <text>")]


# --- plumbing -------------------------------------------------------------------------------------------------------
def private_dir(d):
    os.makedirs(d, mode=0o700, exist_ok=True); os.chmod(d, 0o700)


def write_private(path, text):
    private_dir(os.path.dirname(path)); tmp = "%s.%d.tmp" % (path, os.getpid())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f: f.write(text)
    os.chmod(tmp, 0o600); os.replace(tmp, path)


def load(path, default):
    try:
        with open(path) as f: d = json.load(f)
        return d if isinstance(d, type(default)) else default
    except Exception: return default


class Locked:
    """one writer of a state file at a time (the forwarder's loop and an owner's tap may run together)"""
    def __init__(self, name): self.p = os.path.join(CHAT, name)
    def __enter__(self):
        private_dir(CHAT); self.f = open(self.p, "a"); fcntl.flock(self.f, fcntl.LOCK_EX); return self
    def __exit__(self, *a): fcntl.flock(self.f, fcntl.LOCK_UN); self.f.close()


def log(line):
    """one line in <S>/logs/chat.log (bin/chat logs): fixed words and agent names, never an id or a token"""
    private_dir(os.path.dirname(LOG))
    with open(LOG, "a") as f: f.write("%s chat: %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), line))


def redact(text):
    """the hub's redact helper (bin/lib.sh redact: agent.py --redact)"""
    r = subprocess.run([sys.executable, "-I", os.path.join(H, "bin", "agent.py"), "--redact"], input=text.encode("utf-8"),
                       capture_output=True, timeout=30)
    if r.returncode != 0: raise RuntimeError("redact failed")
    return r.stdout.decode("utf-8", "replace")


def call(method, payload, files=None):
    """one Bot API call; the answer as a dict ({"ok": False, "description": ...} on any failure). The address holds the
    token, so it is never printed; a description that held the token has it replaced."""
    api = chat.api_base()
    if api is None: return {"ok": False, "description": "host refused"}
    url = "%s/bot%s/%s" % (api, TOKEN, method)
    if files:
        b = "ade" + secrets.token_hex(16); parts = []
        for k, v in payload.items():
            v = v if isinstance(v, str) else json.dumps(v, ensure_ascii=False)
            parts.append(('--%s\r\nContent-Disposition: form-data; name="%s"\r\n\r\n%s\r\n' % (b, k, v)).encode("utf-8"))
        for field, name, mime, data in files:
            parts.append(('--%s\r\nContent-Disposition: form-data; name="%s"; filename="%s"\r\nContent-Type: %s\r\n\r\n'
                          % (b, field, name, mime)).encode("utf-8")); parts.append(data); parts.append(b"\r\n")
        parts.append(("--%s--\r\n" % b).encode("utf-8"))
        req = urllib.request.Request(url, data=b"".join(parts), headers={"Content-Type": "multipart/form-data; boundary=" + b})
    else:
        req = urllib.request.Request(url, data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
                                     headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r: d = json.load(r)
    except urllib.error.HTTPError as e:
        try: d = json.loads(e.read(65536).decode("utf-8", "replace"))
        except Exception: d = {}
        d = {"ok": False, "description": "HTTP %d: %s" % (e.code, str(d.get("description", "")) if isinstance(d, dict) else "")}
    except Exception as e:
        d = {"ok": False, "description": e.__class__.__name__}
    if not isinstance(d, dict): d = {"ok": False, "description": "not an answer"}
    if "description" in d and TOKEN: d["description"] = " ".join(str(d["description"]).replace(TOKEN, "<hidden>").split())[:200]
    return d


def owner():
    o = chat.locked_owner()
    if not o: print("chat: refused: the channel is not locked to you; nothing sent", file=sys.stderr)
    return o


def thread(to, reply_to):
    return {"reply_parameters": {"message_id": int(reply_to), "allow_sending_without_reply": True}} if reply_to else {}


def utf16(s):
    return len(s.encode("utf-16-le")) // 2


def say(to, text, reply_to=None, pre=False, markup=None):
    """one message (at most 4096 characters); pre: shown as a code block (an entity, so nothing needs escaping)"""
    text = text[:4096]; p = {"chat_id": to, "text": text}
    if pre: p["entities"] = [{"type": "pre", "offset": 0, "length": utf16(text)}]
    if markup: p["reply_markup"] = markup
    p.update(thread(to, reply_to)); d = call("sendMessage", p)
    if not d.get("ok"): print("chat: not sent (%s)" % d.get("description", ""), file=sys.stderr)
    return d


def document(to, name, data, caption, reply_to=None):
    p = {"chat_id": to, "caption": caption[:1024]}; p.update(thread(to, reply_to))
    d = call("sendDocument", p, [("document", name, "text/plain", data)])
    if not d.get("ok"): print("chat: not sent (%s)" % d.get("description", ""), file=sys.stderr)
    return d


# --- the agents -----------------------------------------------------------------------------------------------------
def norm(name):
    """the agent part of a command link: lowercased, anything outside a-z0-9 turned into _, at most 25 characters,
    so /update_<agent> is at most 32 (Telegram's command length)"""
    return re.sub(r"[^a-z0-9]", "_", name.lower())[:25]


def agents():
    """the running agents, from bin/sessions, with their registry entries (cwd, session id) and newest event"""
    r = subprocess.run([os.path.join(H, "bin", "sessions")], capture_output=True, timeout=30)
    latest = {}
    ev = subprocess.run([sys.executable, "-I", os.path.join(H, "bin", "events.py"), "latest"], capture_output=True, timeout=30,
                        env=dict(os.environ, H=H, ST=S))
    for ln in ev.stdout.decode("utf-8", "replace").splitlines():
        f, _, rest = ln.partition("\t"); k, _, t = rest.partition("\t"); latest[f] = (k, t)
    entries = []
    sd = os.path.join(S, "sessions")
    for n in (os.listdir(sd) if os.path.isdir(sd) else []):
        e = {}
        try:
            for l in open(os.path.join(sd, n), errors="replace"):
                k, _, v = l.rstrip("\n").partition("=")
                if k and k not in e: e[k] = v
        except OSError: continue
        entries.append(e)
    out = []
    for i, ln in enumerate(r.stdout.decode("utf-8", "replace").splitlines()):
        c = ln.split()
        if i == 0 or len(c) < 8: continue
        a = {"name": c[0], "folder": c[1], "pid": c[2], "started": c[4], "role": c[5], "status": c[6], "last": c[7],
             "engine": c[8] if len(c) > 8 else "claude"}
        e = next((e for e in entries if e.get("name") == a["name"] and e.get("folder") == a["folder"]
                  and e.get("started", a["started"]) == a["started"]), {})
        a["entry"] = e
        k, t = latest.get(a["folder"], ("", ""))
        a["state"] = "blocked" if k == "note" and t.lower().startswith("blocked") else ("busy" if a["status"] == "busy" else "idle")
        tk = e.get("ticket", "-")
        a["ticket"] = tk if tk and tk != "-" else (a["name"] if a["role"] == "builder" else "-")
        out.append(a)
    return out


def find(all_agents, q):
    """the agents a link or a typed name names: its link part, its name, its folder or the folder's last part"""
    q = q.strip(); hits = {}
    for a in all_agents:
        last = a["folder"].rsplit("/", 1)[-1]
        if q in (norm(a["name"]), a["name"], a["folder"], last, norm(last)): hits[a["folder"] + "\0" + a["name"]] = a
    return list(hits.values())


def listing(all_agents):
    if not all_agents: return "no agents are running"
    rows = [("NAME", "FOLDER", "ROLE", "STATE")] + [(a["name"], a["folder"], a["role"], a["state"]) for a in all_agents]
    w = [max(len(r[i]) for r in rows) for i in range(3)]
    return "\n".join("  ".join(r[i].ljust(w[i]) for i in range(3)) + "  " + r[3] for r in rows)


def epoch(t):
    """a UTC time as bin/sessions prints it, in seconds; None when it is not one"""
    for f in ("%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%dT%H:%MZ"):
        try: return calendar.timegm(time.strptime(t, f))
        except Exception: pass
    return None


def age(a, now):
    t = epoch(a["last"]) if a["last"] != "-" else None
    t = t if t is not None else epoch(a["started"])
    if t is None: return "-"
    s = max(0, now - t)
    return "now" if s < 60 else "%dm" % (s // 60) if s < 3600 else "%dh" % (s // 3600) if s < 172800 else "%dd" % (s // 86400)


# --- the board ------------------------------------------------------------------------------------------------------
EMOJI = {"busy": "●", "idle": "○", "blocked": "⚠"}


def board_text(all_agents, done):
    lines = ["Agents · %s" % ("none running" if not all_agents else "%d running" % len(all_agents))]
    for a in all_agents:
        n = norm(a["name"])
        lines.append("%s %s · %s · %s · %s · %s" % (EMOJI[a["state"]], a["name"], a["folder"], a["role"], a["ticket"], age(a, int(time.time()))))
        lines.append(" ".join("/%s_%s" % (x, n) for x in ACTIONS))
    for d in done: lines.append("✓ %s · %s · done" % (d["name"], d["folder"]))
    text = "\n".join(lines)
    return text if len(text) <= 4096 else text[:4090] + "\n…"


def post_board(to, b, text):
    d = say(to, text)
    if not d.get("ok"): return 1
    mid = (d.get("result") or {}).get("message_id")
    if not isinstance(mid, int): return 1
    call("pinChatMessage", {"chat_id": to, "message_id": mid, "disable_notification": True})
    b.update({"message_id": mid, "text": text, "edited": int(time.time())}); return 0


def board(to=None, ended=None):
    to = to or owner()
    if not to: return 2
    with Locked("board.lock"):
        b = load(BOARD, {}); live = agents(); now = int(time.time())
        names = {(a["name"], a["folder"]) for a in live}
        done = [d for d in b.get("done", []) if (d.get("name"), d.get("folder")) not in names]
        for p in b.get("rows", []):
            if tuple(p) not in names and not any((d["name"], d["folder"]) == tuple(p) for d in done):
                done.insert(0, {"name": p[0], "folder": p[1]})
        if ended and ended not in names and not any((d["name"], d["folder"]) == ended for d in done):
            done.insert(0, {"name": ended[0], "folder": ended[1]})   # stopped before a board run saw it
        done = done[:5]; b["rows"] = sorted(names); b["done"] = done
        text = board_text(live, done); rc = 0
        if not isinstance(b.get("message_id"), int): rc = post_board(to, b, text)
        elif text != b.get("text"):
            if now - int(b.get("edited", 0)) < GAP: rc = 0   # coalesced: the next run sends it
            else:
                d = call("editMessageText", {"chat_id": to, "message_id": b["message_id"], "text": text})
                why = str(d.get("description", ""))
                if d.get("ok") or "message is not modified" in why: b.update({"text": text, "edited": now})
                elif "message to edit not found" in why: b.pop("message_id", None); rc = post_board(to, b, text)
                else: print("chat: the board was not edited (%s)" % why, file=sys.stderr); rc = 1
        # a failed send keeps the old text, so the next run tries again
        write_private(BOARD, json.dumps(b, ensure_ascii=False))
        return rc


# --- actions --------------------------------------------------------------------------------------------------------
def transcript(a):
    """the agent's Claude Code transcript: <config dir>/projects/<cwd encoded>/<session id>.jsonl, else the newest there"""
    e = a["entry"]; cfg = e.get("config_dir", "-"); cwd = e.get("cwd", "")
    if a["engine"] != "claude" or not cwd: return None
    base = cfg if cfg and cfg != "-" else os.environ.get("CLAUDE_DIR", "")
    d = os.path.join(base, "projects", re.sub(r"[^A-Za-z0-9]", "-", cwd)); sid = e.get("session_id", "")
    if sid and re.fullmatch(r"[A-Za-z0-9._-]+", sid) and os.path.isfile(os.path.join(d, sid + ".jsonl")): return os.path.join(d, sid + ".jsonl")
    try: c = [os.path.join(d, f) for f in os.listdir(d) if f.endswith(".jsonl")]
    except OSError: return None
    return max(c, key=os.path.getmtime) if c else None


def log_lines(path):
    with open(path, "rb") as f:
        f.seek(0, 2); n = f.tell(); f.seek(max(0, n - (4 << 20))); raw = f.read().decode("utf-8", "replace")
    out = []
    def emit(ts, who, text):
        for l in str(text).splitlines():
            l = " ".join("".join(c if c.isprintable() else " " for c in l).split())
            if l: out.append(("%s %s: %s" % (ts, who, l))[:300])
    for ln in raw.splitlines():
        try: e = json.loads(ln)
        except Exception: continue
        if not isinstance(e, dict) or e.get("type") not in ("user", "assistant"): continue
        ts = str(e.get("timestamp", ""))[11:16]; who = e["type"]; c = (e.get("message") or {}).get("content")
        if isinstance(c, str): emit(ts, who, c); continue
        for b in c if isinstance(c, list) else []:
            if not isinstance(b, dict): continue
            if b.get("type") == "text": emit(ts, who, b.get("text", ""))
            elif b.get("type") == "tool_use":
                i = b.get("input") or {}
                arg = next((str(i[k]) for k in ("command", "file_path", "pattern", "description", "url") if isinstance(i, dict) and k in i), "")
                emit(ts, "tool", ("%s %s" % (b.get("name", ""), arg.splitlines()[0] if arg else "")).strip())
            elif b.get("type") == "tool_result":
                r = b.get("content"); r = r if isinstance(r, str) else " ".join(x.get("text", "") for x in r if isinstance(x, dict)) if isinstance(r, list) else ""
                if r: emit(ts, "result", r.splitlines()[0][:200])
    return out


def do_log(to, a, n, reply_to):
    p = transcript(a)
    if not p: return say(to, "no log for %s: no transcript the hub can read" % a["name"], reply_to)
    lines = log_lines(p)[-n:]
    if not lines: return say(to, "no log for %s yet" % a["name"], reply_to)
    body = redact("\n".join(lines) + "\n").rstrip("\n")
    head = "log of %s (%s), last %d line%s" % (a["name"], a["folder"], len(lines), "" if len(lines) == 1 else "s")
    if len(head) + 1 + len(body) <= 4096: return say(to, head + "\n" + body, reply_to)
    return document(to, norm(a["name"]) + "-log.txt", (body + "\n").encode("utf-8"), redact(head).strip(), reply_to)


def images(folder):
    d = os.path.join(H, folder, "reports", "browser")
    try: names = os.listdir(d)
    except OSError: return d, []
    return d, [n for n in names if re.search(r"\.(png|jpe?g)$", n, re.I)]


def safe_name(name):
    """a file's name as it goes in the request: keys and tokens hidden too (a screenshot named after a key)"""
    return re.sub(r"[^A-Za-z0-9._-]", "_", redact(name).strip(), flags=re.ASCII)[-100:].lstrip(".") or "screenshot"


def caption(a, stems):
    return redact(("[%s] %s" % (a["name"], ", ".join(stems)))).strip()[:1024]


def photo(to, a, path, reply_to=None):
    got = chat.read_file(path, "photo")
    if isinstance(got, str): return {"ok": False, "description": got}
    data, name, mime = got; name = safe_name(name); p = {"chat_id": to, "caption": caption(a, [os.path.splitext(name)[0]])}; p.update(thread(to, reply_to))
    return call("sendPhoto", p, [("photo", name, mime, data)])


def do_shot(to, a, reply_to):
    d, names = images(a["folder"])
    ok = []
    for n in names:
        p = os.path.join(d, n)
        if not isinstance(chat.read_file(p, "photo"), str): ok.append((os.lstat(p).st_mtime, p))
    if not ok: return say(to, "no screenshot from %s yet (%s/reports/browser)" % (a["name"], a["folder"]), reply_to)
    r = photo(to, a, max(ok)[1], reply_to)
    if not r.get("ok"): print("chat: not sent (%s)" % r.get("description", ""), file=sys.stderr)
    return r


def do_diff(to, a, reply_to):
    cwd = a["entry"].get("cwd", "")
    if not cwd or not os.path.isdir(cwd): return say(to, "no checkout known for %s" % a["name"], reply_to)
    g = ["git", "--no-optional-locks", "-C", cwd]
    st = subprocess.run(g + ["diff", "--stat", "HEAD"], capture_output=True, timeout=60).stdout.decode("utf-8", "replace")
    un = subprocess.run(g + ["ls-files", "--others", "--exclude-standard"], capture_output=True, timeout=60).stdout.decode("utf-8", "replace")
    text = st + ("".join("untracked: %s\n" % l for l in un.splitlines()[:200]))
    if not text.strip(): return say(to, "no changes in %s's checkout" % a["name"], reply_to)
    return document(to, norm(a["name"]) + "-diff.txt", redact(text).encode("utf-8"), "diff of %s (%s)" % (a["name"], a["folder"]), reply_to)


def do_update(to, a, reply_to):
    ask = ("The owner asks for a status update from Telegram: reply with bin/notify main and two short lines, "
           "what you are doing now and what comes next.")
    r = subprocess.run([os.path.join(H, "bin", "notify"), "--from", "main", a["folder"], ask], capture_output=True, timeout=30)
    if r.returncode != 0: return say(to, "could not ask %s (bin/notify failed)" % a["name"], reply_to)
    return say(to, "asked %s for an update; its reply comes here as [%s, claimed] note" % (a["name"], a["folder"]), reply_to)


def keyboard(*labels):
    return {"keyboard": [[{"text": l} for l in labels]], "one_time_keyboard": True, "resize_keyboard": True}


def do_stop(to, a, reply_to):
    private_dir(STOPS); n = "%04d" % secrets.randbelow(10000); c = "/stop_%s_%s" % (norm(a["name"]), n)
    write_private(os.path.join(STOPS, n), json.dumps({"name": a["name"], "folder": a["folder"], "time": int(time.time())}))
    return say(to, "Stop %s (%s)? Tap %s within 2 minutes, or /cancel." % (a["name"], a["folder"], c), reply_to,
               markup=keyboard(c, "/cancel"))


def confirm_stop(to, q, nonce, reply_to):
    f = os.path.join(STOPS, nonce); gone = {"remove_keyboard": True}
    try:
        with open(f) as fh: s = json.load(fh)
        os.unlink(f)   # single use, whatever happens next
    except Exception: s = None
    if not isinstance(s, dict) or norm(str(s.get("name", ""))) != q or int(time.time()) - int(s.get("time", 0)) > STOP_TTL:
        return say(to, "that confirmation has expired or was used; send /stop_%s again" % q, reply_to, markup=gone)
    a = next((x for x in agents() if x["name"] == s["name"] and x["folder"] == s["folder"]), None)
    if not a or not re.fullmatch(r"[0-9]+", a["pid"]) or int(a["pid"]) <= 1:
        return say(to, "%s is not running" % s["name"], reply_to, markup=gone)
    try: os.kill(int(a["pid"]), signal.SIGTERM)
    except OSError: return say(to, "could not stop %s" % a["name"], reply_to, markup=gone)
    for _ in range(40):
        try: os.kill(int(a["pid"]), 0); time.sleep(0.05)
        except OSError: break
    subprocess.run([os.path.join(H, "bin", "journal"), ".", "chat: the owner stopped %s (%s) from Telegram" % (a["name"], a["folder"])],
                   capture_output=True, timeout=30)
    r = say(to, "stopped %s (%s)" % (a["name"], a["folder"]), reply_to, markup=gone)
    board(to, (a["name"], a["folder"])); return r


def links(all_agents, action):
    if not all_agents: return "no agents are running"
    return "\n".join("/%s_%s  %s" % (action, norm(a["name"]), a["folder"]) for a in all_agents)


def act(frm, reply_to, text):
    to = chat.locked_owner()
    if not to or not frm or frm != to:
        log("act ignored: the sender is not the paired, locked owner"); return 2
    if reply_to and not re.fullmatch(r"[1-9][0-9]{0,15}", reply_to): reply_to = None
    words = text.strip().split()
    if not words or not words[0].startswith("/"): say(to, "not a command; try /agents", reply_to); return 2
    cmd = words[0][1:].split("@", 1)[0].lower(); args = words[1:]
    if cmd == "cancel":
        for f in os.listdir(STOPS) if os.path.isdir(STOPS) else []: os.unlink(os.path.join(STOPS, f))
        say(to, "cancelled", reply_to, markup={"remove_keyboard": True}); return 0
    if cmd == "to":
        print("chat: /to goes through bin/chat to --sender <id> <agent> (behind the owner's Allow)", file=sys.stderr); return 2
    all_agents = agents()
    if cmd == "agents": return 0 if say(to, listing(all_agents), reply_to, pre=True).get("ok") else 1
    action, _, q = cmd.partition("_")
    if action not in ACTIONS + ("diff",):
        say(to, "unknown command; the commands: /agents /update /log /shot /to", reply_to); return 2
    n = 50
    if not q and args:
        q = args[0]
        if action == "log" and len(args) > 1:
            if not re.fullmatch(r"[1-9][0-9]{0,2}", args[1]) or int(args[1]) > 500: say(to, "/log <agent> <1 to 500>", reply_to); return 2
            n = int(args[1])
    elif q and args and action == "log" and re.fullmatch(r"[1-9][0-9]{0,2}", args[0]) and int(args[0]) <= 500: n = int(args[0])
    if not q: return 0 if say(to, links(all_agents, action), reply_to).get("ok") else 1
    m = re.fullmatch(r"(.+)_([0-9]{4})", q)
    if action == "stop" and m and os.path.isfile(os.path.join(STOPS, m.group(2))):
        return 0 if confirm_stop(to, m.group(1), m.group(2), reply_to).get("ok") else 1
    if action == "stop" and m and not find(all_agents, q):
        return 0 if confirm_stop(to, m.group(1), m.group(2), reply_to).get("ok") else 1
    hit = find(all_agents, q)
    if len(hit) != 1:
        say(to, "no single agent named '%s'; the agents:\n%s" % (q, listing(all_agents)), reply_to); return 2
    a = hit[0]
    r = {"update": do_update, "shot": do_shot, "diff": do_diff, "stop": do_stop}.get(action)
    d = do_log(to, a, n, reply_to) if action == "log" else r(to, a, reply_to)
    return 0 if d.get("ok") else 1


# --- screenshots ----------------------------------------------------------------------------------------------------
def shots():
    to = owner()
    if not to: return 2
    rc = 0
    with Locked("shots.lock"):
        seen = load(SHOTS, {}); live = agents(); folders = {}
        for a in live: folders.setdefault(a["folder"], a)
        for folder, a in sorted(folders.items()):
            d, names = images(folder); start = epoch(a["started"]) or 0
            mine = [x for x in seen.get(folder, []) if isinstance(x, str)]; new = []
            for n in names:
                p = os.path.join(d, n)
                try: st = os.lstat(p)
                except OSError: continue
                key = "%s %d" % (n, st.st_mtime_ns)
                if key in mine or st.st_mtime < start: continue
                mine.append(key)
                got = chat.read_file(p, "photo")
                if isinstance(got, str): log("a screenshot of %s was not posted (%s)" % (folder, got)); continue
                new.append((st.st_mtime_ns, n, (got[0], safe_name(got[1]), got[2])))
            seen[folder] = mine[-500:]
            new.sort()
            for i in range(0, min(len(new), 30), 10):
                chunk = new[i:i + 10]
                if len(chunk) == 1:
                    data, name, mime = chunk[0][2]; p = {"chat_id": to, "caption": caption(a, [os.path.splitext(chunk[0][1])[0]])}
                    p.update(thread(to, thread_of(folder))); r = call("sendPhoto", p, [("photo", name, mime, data)])
                else:
                    media = [{"type": "photo", "media": "attach://p%d" % j} for j in range(len(chunk))]
                    media[0]["caption"] = caption(a, [os.path.splitext(c[1])[0] for c in chunk])
                    p = {"chat_id": to, "media": media}; p.update(thread(to, thread_of(folder)))
                    r = call("sendMediaGroup", p, [("p%d" % j, c[2][1], c[2][2], c[2][0]) for j, c in enumerate(chunk)])
                if not r.get("ok"): print("chat: screenshots not sent (%s)" % r.get("description", ""), file=sys.stderr); rc = 1
                else: log("posted %d screenshot%s from %s" % (len(chunk), "" if len(chunk) == 1 else "s", folder))
        write_private(SHOTS, json.dumps(seen, ensure_ascii=False))
    return rc


# --- menu and threads -----------------------------------------------------------------------------------------------
def menu():
    to = owner()
    if not to: return 2
    d = call("setMyCommands", {"commands": [{"command": c, "description": t} for c, t in MENU],
                               "scope": {"type": "chat", "chat_id": int(to)}})
    if not d.get("ok"): print("chat: the menu was not set (%s)" % d.get("description", ""), file=sys.stderr); return 1
    return 0


def thread_of(folder):
    v = load(THREADS, {}).get(folder)
    return str(v) if isinstance(v, int) else None


def set_thread(folder, mid):
    with Locked("threads.lock"):
        t = load(THREADS, {})
        if mid == "-": t.pop(folder, None)
        else: t[folder] = int(mid)
        write_private(THREADS, json.dumps(t))
    return 0


def main(a):
    global TOKEN
    if a[:1] == ["norm"] and len(a) == 2: print(norm(a[1])); return 0
    if a[:1] == ["thread-of"] and len(a) == 2: v = thread_of(a[1]); print(v or ""); return 0 if v else 1
    if a[:1] == ["thread"] and len(a) == 3 and re.fullmatch(r"(projects|ops)/[A-Za-z0-9._-]+", a[1]) \
            and (a[2] == "-" or re.fullmatch(r"[1-9][0-9]{0,15}", a[2])): return set_thread(a[1], a[2])
    raw = sys.stdin.buffer.read().decode("utf-8", "replace")
    TOKEN, _, rest = raw.partition("\n"); TOKEN = TOKEN.strip()
    if not TOKEN: print("chat: no bot token", file=sys.stderr); return 1
    if a == ["board"]: return board()
    if a == ["shots"]: return shots()
    if a == ["menu"]: return menu()
    if a[:1] == ["act"] and len(a) in (1, 2): return act(os.environ.get("FROM", ""), a[1] if len(a) == 2 else None, rest)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
