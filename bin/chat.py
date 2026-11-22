#!/usr/bin/env python3
"""bin/chat's helpers for what it sends and whom it believes (story C7; contract in .ade/context/chat.md). Called by
bin/chat, never by a person. Env: ACCESS (the channel's access.json), AGENT_CHAT_SEND (tests: a fake channel that gets
each payload as JSON on stdin), AGENT_TELEGRAM_API (default https://api.telegram.org).

  chat.py owner SENDER            exit 0 when SENDER is a paired owner (in access.json allowFrom), else 2
  chat.py send [--buttons REF]    the text on stdin to every paired owner, plain text (no parse mode); exit 0 once
                                  any owner got it, each miss named on stderr ("not delivered to <id>"); --buttons adds
                                  Approve / Deny inline buttons (callback data ask:approve:REF, ask:deny:REF). Without
                                  AGENT_CHAT_SEND the bot token is the first line of stdin and the rest is the text.
                                  Exit 0 sent to all, 1 not sent (not paired, or the channel failed)
  chat.py agents card|table TITLE the agents (bin/sessions output on stdin, newest events from LATEST) as the status
                                  card or the /agents table
  chat.py ref                     a new five-letter ask ref"""
import json, os, secrets, sys, unicodedata, urllib.request

STATE = {"busy": "● busy", "idle": "○ idle", "blocked": "⚠ blocked"}


def owners():
    try: d = json.load(open(os.environ.get("ACCESS", "")))
    except Exception: return []
    if not isinstance(d, dict) or d.get("dmPolicy", d.get("policy")) == "disabled": return []
    a = d.get("allowFrom")
    return [str(x) for x in a if str(x).strip()] if isinstance(a, list) else []


def send(argv):
    ref = argv[1] if argv[:1] == ["--buttons"] and len(argv) > 1 else None
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
    ok = True; got = 0
    for chat_id in to:
        p = {"chat_id": chat_id, "text": text[:4096]}
        if ref:
            p["reply_markup"] = {"inline_keyboard": [[{"text": "Approve", "callback_data": "ask:approve:" + ref},
                                                       {"text": "Deny", "callback_data": "ask:deny:" + ref}]]}
        body = json.dumps(p, ensure_ascii=False)
        if fake:
            import subprocess
            try: one = subprocess.run([fake], input=body.encode(), timeout=30).returncode == 0
            except Exception: one = False
            got += one
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
        got += one
        if not one: print("chat: not delivered to %s" % chat_id, file=sys.stderr)
    # sent once any owner got it (a line is never held back, or sent twice, for one unreachable owner)
    return 0 if got else 1


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
    if a[:1] == ["agents"] and len(a) == 3 and a[1] in ("card", "table"): return agents(a[1], a[2])
    if a[:1] == ["ref"]:
        # AGENT_CHAT_REFS (tests): the refs to hand out, the Nth for attempt N
        fixed = os.environ.get("AGENT_CHAT_REFS", "").split(); n = int(a[1]) if len(a) > 1 and a[1].isdigit() else 0
        if fixed: print(fixed[min(n, len(fixed) - 1)]); return 0
        print("".join(secrets.choice("abcdefghijkmnopqrstuvwxyz") for _ in range(5))); return 0
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
