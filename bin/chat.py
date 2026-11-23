#!/usr/bin/env python3
"""bin/chat's helpers for what it sends and whom it believes (story C7; contract in .ade/context/chat.md). Called by
bin/chat, never by a person. Env: ACCESS (the channel's access.json), AGENT_CHAT_SEND (tests: a fake channel that gets
each payload as JSON on stdin), AGENT_TELEGRAM_API (default https://api.telegram.org).

  chat.py owner SENDER            exit 0 when SENDER is a paired owner (in access.json allowFrom), else 2
  chat.py send [--buttons REF] [--done FILE [--skip-first]]   the text on stdin to every paired owner, plain text (no
                                  parse mode). Exit 0 all owners have it, 3 some (each miss named on stderr: "not
                                  delivered to <id>"), 1 none. --done records (and skips) the owners it reached; --buttons adds
                                  Approve / Deny inline buttons (callback data ask:approve:REF, ask:deny:REF). Without
                                  AGENT_CHAT_SEND the bot token is the first line of stdin and the rest is the text.
                                  Exit 0 sent to all, 1 not sent (not paired, or the channel failed)
  chat.py agents card|table TITLE the agents (bin/sessions output on stdin, newest events from LATEST) as the status
                                  card or the /agents table
  chat.py file photo|document PATH   one file to the one owner the channel is locked to (bin/chat send). The bot token is
                                  the first line of stdin (not with AGENT_CHAT_SEND), the rest the caption. Exit 0 sent,
                                  1 not sent, 2 refused (not locked, or a file that is never sent)
  chat.py ref                     a new five-letter ask ref"""
import json, os, re, secrets, stat, sys, unicodedata, urllib.error, urllib.request

STATE = {"busy": "● busy", "idle": "○ idle", "blocked": "⚠ blocked"}


def owners():
    try: d = json.load(open(os.environ.get("ACCESS", "")))
    except Exception: return []
    if not isinstance(d, dict) or d.get("dmPolicy", d.get("policy")) == "disabled": return []
    a = d.get("allowFrom")
    return [str(x) for x in a if str(x).strip()] if isinstance(a, list) else []


def send(argv):
    ref = done = None; skip = 0; i = 0
    while i < len(argv):
        if argv[i] == "--buttons" and i + 1 < len(argv): ref = argv[i + 1]; i += 2
        elif argv[i] == "--done" and i + 1 < len(argv): done = argv[i + 1]; i += 2
        elif argv[i] == "--skip-first": skip = 1; i += 1
        else: return 2
    got = set()
    if done:
        try: got = set(l.strip() for l in open(done).read().splitlines()[skip:] if l.strip())
        except OSError: pass
    fake = os.environ.get("AGENT_CHAT_SEND", "")
    data = sys.stdin.read()
    token = ""
    if not fake:
        token, _, data = data.partition("\n")
        token = token.strip()
        if not token: print("chat: no bot token", file=sys.stderr); return 1
    text = data.rstrip("\n")
    if not text: return 0
    to = owners()
    if not to: print("chat: not paired (no allowFrom in access.json): nothing sent", file=sys.stderr); return 1
    ok = True; hits = 0
    for chat_id in to:
        if chat_id in got: continue   # it reached this owner on an earlier try
        p = {"chat_id": chat_id, "text": text[:4096]}
        if ref:
            p["reply_markup"] = {"inline_keyboard": [[{"text": "Approve", "callback_data": "ask:approve:" + ref},
                                                       {"text": "Deny", "callback_data": "ask:deny:" + ref}]]}
        body = json.dumps(p, ensure_ascii=False)
        if fake:
            import subprocess
            try: one = subprocess.run([fake], input=body.encode(), timeout=30).returncode == 0
            except Exception: one = False
            ok = one and ok; hits += one; mark(done, chat_id, one)
            if not one: print("chat: not delivered to %s" % chat_id, file=sys.stderr)
            continue
        api = os.environ.get("AGENT_TELEGRAM_API", "https://api.telegram.org").rstrip("/")
        req = urllib.request.Request("%s/bot%s/sendMessage" % (api, token), data=body.encode(),
                                     headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=20) as r: one = json.load(r).get("ok") is True
        except Exception as e:
            # never the URL: it holds the token
            print("chat: send failed (%s)" % e.__class__.__name__, file=sys.stderr); one = False
        ok = one and ok; hits += one; mark(done, chat_id, one)
        if not one: print("chat: not delivered to %s" % chat_id, file=sys.stderr)
    # 0: every owner has it (now or on an earlier try); 3: some have it (a forward line counts as sent, a kept message
    # is retried for the rest only); 1: nobody got it
    if ok: return 0
    return 3 if hits or got else 1


PHOTO_MAX = 10 * 1024 * 1024
DOC_MAX = 20 * 1024 * 1024
# folders whose files are never sent, whatever asks: the hub's state (tokens, access.json, logs), every hub's state,
# and the home folders that hold keys and sign-ins
NEVER = ("~/.agent-hub", "~/.ssh", "~/.config", "~/.aws", "~/.gnupg", "~/.claude", "~/.kube", "~/.docker", "~/Library/Keychains")


def refuse(why):
    print("chat: refused: %s; nothing sent" % why, file=sys.stderr); return 2


def locked_owner():
    """the one id the channel is locked to, as bin/chat's lock_of reads access.json (which ran first); else None"""
    try: d = json.load(open(os.environ.get("ACCESS", "")))
    except Exception: return None
    if not isinstance(d, dict) or d.get("dmPolicy") != "allowlist" or d.get("groups") not in (None, {}, []): return None
    a = d.get("allowFrom")
    if not isinstance(a, list) or len(a) != 1 or not isinstance(a[0], str) or not re.fullmatch("[1-9][0-9]{0,19}", a[0], re.ASCII): return None
    return a[0]


def under(path, folder):
    return path == folder or path.startswith(folder.rstrip("/") + "/")


def read_file(path, kind):
    """(bytes, name, mime) of a file that may be sent, or a str saying why not. The file is opened once, without
    following a link, and checked on the open file: a regular file, not empty, within the cap."""
    if not path or "\0" in path: return "no file named"
    real = os.path.realpath(path); name = os.path.basename(real)
    if name == ".env" or name.startswith(".env.") or name.endswith(".env"): return "a .env file is never sent"
    never = [os.path.realpath(os.path.expanduser(n)) for n in NEVER]
    if os.environ.get("STATE"): never.append(os.path.realpath(os.environ["STATE"]))
    if any(under(real, n) for n in never): return "a file in a folder of keys, sign-ins or the hub's state is never sent"
    try: fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError: return "no such file"
    except OSError: return "not a regular file (a link, a folder or something else)"
    try:
        st = os.fstat(fd); cap = PHOTO_MAX if kind == "photo" else DOC_MAX
        if not stat.S_ISREG(st.st_mode): return "not a regular file (a link, a folder or something else)"
        if st.st_size == 0: return "the file is empty"
        if st.st_size > cap: return "the file is over %d MB" % (cap >> 20)
        data = b""
        while len(data) <= cap:
            chunk = os.read(fd, 1 << 20)
            if not chunk: break
            data += chunk
    finally: os.close(fd)
    if len(data) > cap: return "the file is over %d MB" % (cap >> 20)
    mime = "application/octet-stream"
    if kind == "photo":
        if data[:8] == b"\x89PNG\r\n\x1a\n": mime = "image/png"
        elif data[:3] == b"\xff\xd8\xff": mime = "image/jpeg"
        else: return "not a PNG or JPEG image (bin/chat send --document sends another kind of file)"
    name = re.sub(r"[^A-Za-z0-9._-]", "_", name, flags=re.ASCII)[-100:].lstrip(".") or "file"
    return data, name, mime


def send_file(kind, path):
    fake = os.environ.get("AGENT_CHAT_SEND", "")
    raw = sys.stdin.buffer.read().decode("utf-8", "replace")
    token = ""
    if not fake:
        token, _, raw = raw.partition("\n")
        token = token.strip()
        if not token: print("chat: no bot token", file=sys.stderr); return 1
    caption = " ".join("".join(c if c.isprintable() else " " for c in raw).split())[:1024]
    to = locked_owner()
    if not to: return refuse("the channel is not locked to you")
    got = read_file(path, kind)
    if isinstance(got, str): return refuse(got)
    data, name, mime = got
    if fake:
        import subprocess
        body = json.dumps({"chat_id": to, "kind": kind, "file": os.path.realpath(path), "name": name, "bytes": len(data), "caption": caption}, ensure_ascii=False)
        try: return 0 if subprocess.run([fake], input=body.encode(), timeout=30).returncode == 0 else 1
        except Exception: return 1
    api = os.environ.get("AGENT_TELEGRAM_API", "https://api.telegram.org").rstrip("/")
    # the token and the file leave only over HTTPS; plain http is the tests' stand-in on this machine, nothing else
    if not re.fullmatch(r"https://[A-Za-z0-9.-]+(:[0-9]{1,5})?|http://(127\.0\.0\.1|localhost)(:[0-9]{1,5})?", api):
        print("chat: AGENT_TELEGRAM_API is not an https address; nothing sent", file=sys.stderr); return 1
    b = "ade" + secrets.token_hex(16); parts = []
    fields = [("chat_id", to)] + ([("caption", caption)] if caption else [])
    for k, v in fields:
        parts.append(('--%s\r\nContent-Disposition: form-data; name="%s"\r\n\r\n%s\r\n' % (b, k, v)).encode("utf-8"))
    parts.append(('--%s\r\nContent-Disposition: form-data; name="%s"; filename="%s"\r\nContent-Type: %s\r\n\r\n' % (b, kind, name, mime)).encode("utf-8"))
    parts.append(data); parts.append(("\r\n--%s--\r\n" % b).encode("utf-8"))
    method = "sendPhoto" if kind == "photo" else "sendDocument"
    req = urllib.request.Request("%s/bot%s/%s" % (api, token, method), data=b"".join(parts),
                                 headers={"Content-Type": "multipart/form-data; boundary=" + b})
    why = ""
    try:
        with urllib.request.urlopen(req, timeout=60) as r: ok = json.load(r).get("ok") is True
    except urllib.error.HTTPError as e:
        # the Bot API's own reason, never the URL (it holds the token)
        ok = False
        try: why = str(json.loads(e.read(65536).decode("utf-8", "replace")).get("description", ""))
        except Exception: why = ""
        why = "HTTP %d%s" % (e.code, ": " + " ".join(why.replace(token, "<hidden>").split())[:200] if why else "")
    except Exception as e:
        ok = False; why = e.__class__.__name__
    if ok: print("%s %d" % (name, len(data))); return 0
    print("chat: the file was not sent (%s)" % (why or "the Bot API did not say ok"), file=sys.stderr); return 1


def mark(done, chat_id, sent):
    if done and sent:
        with open(done, "a") as f: f.write(chat_id + "\n")


def width(s):
    return sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in s)


def agents(kind, title):
    latest = {}
    for ln in os.environ.get("LATEST", "").splitlines():
        f, _, rest = ln.partition("\t"); k, _, t = rest.partition("\t")
        latest[f] = (k, t)
    rows = []
    for i, ln in enumerate(sys.stdin.read().splitlines()):
        c = ln.split()
        if i == 0 or len(c) < 8: continue
        name, folder, role, status, last = c[0], c[1], c[5], c[6], c[7]
        k, t = latest.get(folder, ("", ""))
        if k == "note" and t.lower().startswith("blocked"): st = "blocked"
        elif status == "busy": st = "busy"
        else: st = "idle"
        hhmm = last[11:16] + "Z" if len(last) >= 16 and last[10:11] == "T" else ""
        rows.append((name, folder, role, name if role == "builder" else "-", st, hhmm))
    if kind == "card":
        n = len(rows)
        print("%s · %s" % (title, "no agents" if n == 0 else "%d agent%s" % (n, "" if n == 1 else "s")))
        for name, folder, role, ticket, st, hhmm in rows:
            e, word = STATE[st].split(" ")
            print("%s %s · %s · %s · %s · %s" % (e, name, folder, role, ticket, word + (" " + hhmm if hhmm and st != "blocked" else "")))
        return 0
    table = [("NAME", "FOLDER", "ROLE", "TICKET", "STATE")] + [(r[0], r[1], r[2], r[3], STATE[r[4]]) for r in rows]
    w = [max(width(r[i]) for r in table) for i in range(4)]
    for r in table:
        print("  ".join(r[i] + " " * (w[i] - width(r[i])) for i in range(4)) + "  " + r[4])
    return 0


def main(a):
    if a[:1] == ["owner"] and len(a) == 2: return 0 if a[1] in owners() else 2
    if a[:1] == ["send"]: return send(a[1:])
    if a[:1] == ["file"] and len(a) == 3 and a[1] in ("photo", "document"): return send_file(a[1], a[2])
    if a[:1] == ["agents"] and len(a) == 3 and a[1] in ("card", "table"): return agents(a[1], a[2])
    if a[:1] == ["ref"]:
        # AGENT_CHAT_REFS (tests): the refs to hand out, the Nth for attempt N
        fixed = os.environ.get("AGENT_CHAT_REFS", "").split(); n = int(a[1]) if len(a) > 1 and a[1].isdigit() else 0
        if fixed: print(fixed[min(n, len(fixed) - 1)]); return 0
        print("".join(secrets.choice("abcdefghijkmnopqrstuvwxyz") for _ in range(5))); return 0
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
