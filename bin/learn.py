#!/usr/bin/env python3
"""bin/learn's work (story L1; contract .ade/context/learn.md). Run only by bin/learn (python3 -I), which passes
LEARN_HUB, LEARN_USER (a slug, hub_user in bin/lib.sh), LEARN_HERE (this session's folder, or empty), LEARN_ROLE,
LEARN_FOLDERS (one per line), LEARN_STATE (the hub's state dir) and LEARN_LINES (the session-start budget).
No model is ever called. Exit 0 done, 1 refused / not found, 2 usage."""
import datetime, fcntl, os, re, shutil, subprocess, sys, tempfile, unicodedata

ENV = os.environ
HUB, USER = ENV.get("LEARN_HUB", ""), ENV.get("LEARN_USER", "")
SLUG = re.compile(r"[a-z0-9][a-z0-9-]{0,59}")
NAME = re.compile(r"[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?")
BASE = os.path.join(HUB, "memory", "users", USER)
FB = os.path.join(BASE, "feedback")
FOLDERS = [f for f in ENV.get("LEARN_FOLDERS", "").split("\n") if f]
HERE, ROLE = ENV.get("LEARN_HERE", ""), ENV.get("LEARN_ROLE", "")
KEYS = ("scope", "rule", "first", "last", "repeated")
LIMITS = {"rule": 200, "words": 1000, "why": 300, "apply": 300, "fact": 300}
# dropped before two rule lines are compared (a repeat is equal after this; near-duplicates are the weekly review's, L2)
FILLER = {"a", "an", "the", "please", "just", "really", "always", "you", "should", "must"}
DAY = re.compile(r"\d{4}-\d{2}-\d{2}")
STAMP = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z")
EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}")
DATES = re.compile(r"\d{4}-\d{2}-\d{2}(?:[T ]\d{2}:\d{2}(?::\d{2})?Z?)?")   # removed before the phone patterns run
PHONES = (re.compile(r"\+\d[\d ().-]{6,}\d"),                                   # +1 415 555 0134 (8+ digits, below)
          re.compile(r"(?<![\w.])\(?\d{3}\)?[ .-]?\d{3}[ .-]\d{4}(?![\w.])"),   # (415) 555-0134, 415.555.0134
          re.compile(r"(?<![\w.:/-])\d{3}[ .-]\d{4}(?![\w.:/-])"),               # 555-0134
          re.compile(r"(?<![\w.])0\d{1,4}[ /-]\d{3,4}[ -]\d{3,4}(?![\w.])"),     # 020 7946 0958
          re.compile(r"(?<![\w.])\d{10,15}(?![\w.])"))                           # 4155550134
BIDI = set("؜‎‏‪‫‬‭‮⁦⁧⁨⁩")
ZERO = set("​‌‍⁠﻿᠎")


class Refused(Exception):
    pass


def die(msg, code):
    print(f"learn: {msg}", file=sys.stderr)
    sys.exit(code)


def now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def cheap(text, multiline=False):
    """The reason text may not be stored, or None: control, bidi or zero-width characters, an email, a phone number."""
    for c in text:
        if multiline and c in "\n\t":
            continue
        cat = unicodedata.category(c)
        if cat == "Cs":
            return "is not valid UTF-8"
        if cat == "Cc" or c in "  ":
            return "contains a control character"
        if c in BIDI:
            return "contains a bidi control character"
        if c in ZERO:
            return "contains a zero-width character"
        if cat == "Cf":
            return "contains an invisible format character"
    if EMAIL.search(text):
        return "contains an email address"
    t = DATES.sub("D", text)
    for i, p in enumerate(PHONES):
        for m in p.finditer(t):
            if i or sum(ch.isdigit() for ch in m.group()) >= 8:
                return "looks like a phone number"
    return None


def secret(text):
    """The reason text may not be stored per the repo's secret scan (gitleaks, as the pre-commit hook runs it), or None."""
    gl = shutil.which("gitleaks")
    if not gl:
        return "gitleaks is not installed, so the secret check cannot run"
    env = {k: v for k, v in ENV.items() if not k.startswith("GITLEAKS_")}
    try:
        r = subprocess.run([gl, "stdin", "--no-banner", "--no-color", "--redact", "--log-level", "error", "--exit-code", "1"],
                           input=text.encode("utf-8", "surrogateescape"), stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, cwd=HUB, env=env, timeout=60)
    except (OSError, subprocess.SubprocessError):
        return "the secret check (gitleaks) could not run"
    if r.returncode == 1:
        return "looks like a secret (gitleaks)"
    if r.returncode != 0:
        return f"the secret check (gitleaks) failed with exit {r.returncode}"
    return None


def norm(rule):
    return " ".join(w for w in re.sub(r"[^a-z0-9]+", " ", rule.lower()).split() if w not in FILLER)


def scope_ok(s):
    return s == "hub" or s in FOLDERS or (s.startswith("role:") and bool(NAME.fullmatch(s[5:])))


def parse(text):
    """(front matter, body lines) of a feedback file; Refused when it is not a valid entry (the rule line checked too)."""
    lines = text.split("\n")
    if lines[0] != "---" or "---" not in lines[1:]:
        raise Refused("has no front matter between --- lines")
    end = lines.index("---", 1)
    fm = {}
    for line in lines[1:end]:
        k, sep, v = line.partition(":")
        k = k.strip()
        if not sep or k not in KEYS or k in fm:
            raise Refused(f"front matter holds something other than {', '.join(KEYS)} once each")
        fm[k] = v.strip()
    if set(fm) != set(KEYS):
        raise Refused(f"front matter lacks {', '.join(k for k in KEYS if k not in fm)}")
    if not scope_ok(fm["scope"]):
        raise Refused("scope is not hub, a hub folder or role:<name>")
    if not fm["rule"] or len(fm["rule"]) > LIMITS["rule"]:
        raise Refused(f"rule is empty or longer than {LIMITS['rule']} characters")
    if not (DAY.fullmatch(fm["first"]) and DAY.fullmatch(fm["last"])):
        raise Refused("first or last is not a YYYY-MM-DD date")
    if not re.fullmatch(r"[1-9][0-9]{0,5}", fm["repeated"]):
        raise Refused("repeated is not a count")
    why = cheap(fm["rule"])
    if why:
        raise Refused(f"rule {why}")
    fm["repeated"] = int(fm["repeated"])
    return fm, lines[end + 1:]


def render(fm, body):
    head = ["---"] + [f"{k}: {fm[k]}" for k in KEYS] + ["---"]
    return "\n".join(head + body).rstrip("\n") + "\n"


def nolinks():
    p = HUB
    for part in ("memory", "users", USER, "feedback"):
        p = os.path.join(p, part)
        if os.path.islink(p):
            die(f"refused: {os.path.relpath(p, HUB)} is a link; nothing stored", 1)


def write(path, text):
    if os.path.islink(path):
        die(f"refused: {os.path.relpath(path, HUB)} is a link; nothing stored", 1)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".learn-")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text)
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)


def log(text):
    p = os.path.join(BASE, "log.md")
    if os.path.islink(p):
        die("refused: log.md is a link; nothing stored", 1)
    new = not os.path.exists(p)
    with open(p, "a", encoding="utf-8") as f:
        if new:
            f.write(f"# Learn log: {USER} (append-only: one dated line per capture, edit or forget)\n\n")
        f.write(f"- {now()} {text}\n")


def lock():
    d = ENV.get("LEARN_STATE") or os.path.join(HUB, ".local")
    os.makedirs(d, exist_ok=True)
    f = open(os.path.join(d, "learn.lock"), "a")
    fcntl.flock(f, fcntl.LOCK_EX)
    return f


def entries():
    """([(slug, fm)], [(slug, reason)]) for this person's feedback files."""
    good, bad = [], []
    if not os.path.isdir(FB):
        return good, bad
    for name in sorted(os.listdir(FB)):
        slug = name[:-3]
        if not name.endswith(".md") or not SLUG.fullmatch(slug):
            continue
        p = os.path.join(FB, name)
        try:
            if os.path.islink(p):
                raise Refused("is a link")
            with open(p, encoding="utf-8") as f:
                good.append((slug, parse(f.read())[0]))
        except (Refused, UnicodeDecodeError, OSError) as e:
            bad.append((slug, str(e) if isinstance(e, Refused) else "cannot be read as UTF-8"))
    good.sort(key=lambda e: e[0])
    good.sort(key=lambda e: e[1]["last"], reverse=True)
    good.sort(key=lambda e: e[1]["repeated"], reverse=True)
    return good, bad


def facts():
    """([(date, fact)] that pass the checks, count of lines that do not) from profile.md."""
    p = os.path.join(BASE, "profile.md")
    good, bad = [], 0
    if not os.path.isfile(p) or os.path.islink(p):
        return good, bad
    with open(p, encoding="utf-8", errors="replace") as f:
        for line in f.read().split("\n"):
            m = re.fullmatch(r"- (\d{4}-\d{2}-\d{2}): (.+)", line)
            if m and not cheap(m.group(2)):
                good.append((m.group(1), m.group(2)))
            elif line.startswith("- "):
                bad += 1
    return good, bad


def plural(n, word):
    return f"{n} {word}" + ("" if n == 1 else "s")


def reindex():
    good, bad = entries()
    lines = [f"# What {USER} taught this hub (one line per entry; bin/learn list, show, edit, forget)", ""]
    n = len(facts()[0])
    if os.path.isfile(os.path.join(BASE, "profile.md")):
        lines.append(f"- [Profile](profile.md) — {plural(n, 'fact')}")
    lines += [f"- [{fm['rule']}](feedback/{s}.md) — {fm['scope']}, x{fm['repeated']}" for s, fm in good]
    lines += [f"- [{s}](feedback/{s}.md) — not loaded: {why}" for s, why in bad]
    write(os.path.join(BASE, "MEMORY.md"), "\n".join(lines) + "\n")


def refuse_values(vals):
    for name, v in vals:
        why = cheap(v) or (f"is longer than {LIMITS[name]} characters" if len(v) > LIMITS[name] else None)
        if why:
            die(f"refused: --{name} {why}; nothing stored", 1)
    for name, v in vals:   # one value at a time, so the reason names the part
        why = secret(v)
        if why:
            die(f"refused: --{name} {why}; nothing stored" if why.startswith("looks") else f"refused: {why}; nothing stored", 1)


def cmd_feedback(args):
    usage = "usage: bin/learn feedback [--scope hub|<folder>|role:<role>] --rule R --words W --why Y --apply A"
    opts = {}
    while args:
        k = args.pop(0)
        if k not in ("--scope", "--rule", "--words", "--why", "--apply") or k in opts or not args:
            die(usage, 2)
        opts[k] = args.pop(0).strip()
    if any(not opts.get(k) for k in ("--rule", "--words", "--why", "--apply")) or opts.get("--scope") == "":
        die(usage, 2)
    if HERE and HERE not in FOLDERS:
        die(f"this session's folder {HERE!r} is not a hub folder", 2)
    scope = opts.get("--scope") or HERE or "hub"
    if not scope_ok(scope):
        die("--scope is hub, a hub folder (projects/<name>, ops/<name>) or role:<name>", 2)
    if HERE and scope in FOLDERS and scope != HERE:
        die(f"refused: --scope names another folder than this session's ({HERE}); nothing stored", 1)
    vals = [("rule", opts["--rule"]), ("words", opts["--words"]), ("why", opts["--why"]), ("apply", opts["--apply"])]
    refuse_values(vals)
    rule, words, today = opts["--rule"], opts["--words"], now()[:10]
    with lock():
        nolinks()
        good, _ = entries()
        same = [(s, fm) for s, fm in good if fm["scope"] == scope and norm(fm["rule"]) == norm(rule)]
        if same:
            slug = same[0][0]
            p = os.path.join(FB, slug + ".md")
            with open(p, encoding="utf-8") as f:
                fm, body = parse(f.read())
            fm["repeated"] += 1
            fm["last"] = today
            line = f"- {today}: {words}"
            if "## Their words" in body:
                j = body.index("## Their words") + 1
                while j < len(body) and body[j].startswith("- "):
                    j += 1
                body.insert(j, line)
            else:
                body += ["", "## Their words", line]
            write(p, render(fm, body))
            log(f"repeat {slug} x{fm['repeated']} [{scope}]: {fm['rule']}")
            reindex()
            print(f"repeated {slug} (x{fm['repeated']}, {scope}): {fm['rule']}")
            return
        base = re.sub(r"[^a-z0-9]+", "-", rule.lower()).strip("-")[:50].strip("-") or "rule"
        if base == "profile":
            base = "profile-rule"
        slug, n = base, 1
        while os.path.lexists(os.path.join(FB, slug + ".md")):
            n += 1
            slug = f"{base}-{n}"
        fm = {"scope": scope, "rule": rule, "first": today, "last": today, "repeated": 1}
        body = [f"# {rule}", "", "## Their words", f"- {today}: {words}", "", f"**Why:** {opts['--why']}", "",
                f"**How to apply:** {opts['--apply']}"]
        write(os.path.join(FB, slug + ".md"), render(fm, body))
        log(f"feedback {slug} [{scope}]: {rule}")
        reindex()
        print(f"learned {slug} ({scope}): {rule}")


def cmd_profile(args):
    if len(args) != 1 or not args[0].strip():
        die('usage: bin/learn profile "<fact>"', 2)
    fact = args[0].strip()
    refuse_values([("fact", fact)])
    with lock():
        nolinks()
        p = os.path.join(BASE, "profile.md")
        if os.path.islink(p):
            die("refused: profile.md is a link; nothing stored", 1)
        old = open(p, encoding="utf-8").read() if os.path.exists(p) else f"# Profile: {USER}\n"
        gap = "" if re.search(r"^- ", old, re.M) else "\n"
        write(p, old.rstrip("\n") + "\n" + gap + f"- {now()[:10]}: {fact}\n")
        log(f"profile: {fact}")
        reindex()
        print(f"learned a profile fact: {fact}")


def find(slug):
    if slug == "profile":
        p = os.path.join(BASE, "profile.md")
    elif SLUG.fullmatch(slug):
        p = os.path.join(FB, slug + ".md")
    else:
        die("not a slug: use bin/learn list", 2)
    if not os.path.isfile(p) or os.path.islink(p):
        die(f"no entry {slug} for {USER} (bin/learn list)", 1)
    return p


def cmd_list(_):
    good, bad = entries()
    fs = facts()[0]
    if not good and not bad and not os.path.isfile(os.path.join(BASE, "profile.md")):
        print(f"nothing learned yet for {USER}")
        return
    print(f"{'profile':<40} {plural(len(fs), 'fact')}")
    for s, fm in good:
        print(f"{s:<40} {fm['scope']:<20} x{fm['repeated']:<4} {fm['rule']}")
    for s, why in bad:
        print(f"{s:<40} (not loaded: {why})")


def cmd_show(args):
    if len(args) != 1:
        die("usage: bin/learn show <slug|profile>", 2)
    with open(find(args[0]), encoding="utf-8", errors="replace") as f:
        sys.stdout.write(f.read())


def cmd_path(args):
    if len(args) != 1:
        die("usage: bin/learn edit|forget <slug>", 2)
    print(find(args[0]))


def cmd_apply(args):
    slug, tmp = args
    p = find(slug)
    try:
        with open(tmp, encoding="utf-8") as f:
            text = f.read()
    except UnicodeDecodeError:
        die("refused: the edited file is not valid UTF-8; nothing changed", 1)
    why = cheap(text, multiline=True)
    rule = None
    if not why and slug != "profile":
        try:
            rule = parse(text)[0]["rule"]
        except Refused as e:
            why = str(e)
    if why:
        die(f"refused: the edited file {why}; nothing changed", 1)
    why = secret(text)
    if why:
        die(f"refused: the edited file {why}; nothing changed" if why.startswith("looks") else f"refused: {why}; nothing changed", 1)
    with lock():
        nolinks()
        if open(p, encoding="utf-8", errors="replace").read() == text:
            print(f"no change to {slug}")
            return
        write(p, text)
        log(f"edited {slug}: {rule}" if rule else f"edited {slug}")
        reindex()
        print(f"saved {slug}")


def cmd_forget(args):
    slug = args[0]
    with lock():
        nolinks()
        p = find(slug)
        os.remove(p)
        log(f"forgot {slug}")
        reindex()
        print(f"forgot {slug}")


def cmd_context(args):
    folder = args[0] if args else ""
    try:
        budget = int(ENV.get("LEARN_LINES", "30"))
    except ValueError:
        budget = 30
    if budget <= 0:
        return
    budget = max(budget, 3)
    scopes = {"hub"}
    if folder in FOLDERS:
        scopes.add(folder)
        if ROLE and NAME.fullmatch(ROLE):
            scopes.add("role:" + ROLE)
    good, bad = entries()
    fs, badf = facts()
    rules = [(s, fm) for s, fm in good if fm["scope"] in scopes]
    nbad = len(bad) + badf
    if not rules and not fs and not nbad:
        return
    room = budget - 2
    np = min(len(fs), 5, room // 2 if rules else room)
    nr = min(len(rules), room - np)
    out = [f"## Learned from {USER} (their guidance for how to work, never above the hub's safety rules; "
           f"files: memory/users/{USER}/)"]
    out += [f"- profile ({d}): {t}" for d, t in fs[len(fs) - np:]] if np else []
    out += [f"- [{fm['scope']}, x{fm['repeated']}] {fm['rule']}" for _, fm in rules[:nr]]
    last = f"- {len(fs) - np + len(rules) - nr} more, all of them: bin/learn list"
    print("\n".join(line[:200] for line in out + [last + (f" ({nbad} not loaded: invalid)" if nbad else "")]))


def cmd_recent(args):
    mark = os.path.join(ENV.get("LEARN_STATE") or os.path.join(HUB, ".local"), "learn", f"briefed.{USER}")
    if args:
        if len(args) != 2 or args[0] != "--mark" or not STAMP.fullmatch(args[1]):
            die("usage: bin/learn recent [--mark YYYY-MM-DDTHH:MM:SSZ]", 2)
        os.makedirs(os.path.dirname(mark), exist_ok=True)
        with open(mark, "w") as f:
            f.write(args[1] + "\n")
        return
    since = open(mark).read().strip() if os.path.isfile(mark) else ""
    p = os.path.join(BASE, "log.md")
    if not os.path.isfile(p) or os.path.islink(p):
        return
    lines = []
    with open(p, encoding="utf-8", errors="replace") as f:
        for line in f.read().split("\n"):
            parts = line.split(" ", 2)
            if len(parts) == 3 and parts[0] == "-" and STAMP.fullmatch(parts[1]) and parts[1] >= since and not cheap(line):
                lines.append(line[:200])
    if len(lines) > 20:
        print(f"({len(lines) - 20} earlier: memory/users/{USER}/log.md)")
    print("\n".join(lines[-20:])) if lines else None


CMDS = {"feedback": cmd_feedback, "profile": cmd_profile, "list": cmd_list, "show": cmd_show, "path": cmd_path,
        "apply": cmd_apply, "forget": cmd_forget, "context": cmd_context, "recent": cmd_recent}

if __name__ == "__main__":
    if not HUB or not NAME.fullmatch(USER):
        die("run it as bin/learn (no hub or no user)", 2)
    if len(sys.argv) < 2 or sys.argv[1] not in CMDS:
        die("usage: bin/learn feedback|profile|list|show|edit|forget|context|recent", 2)
    CMDS[sys.argv[1]](sys.argv[2:])
