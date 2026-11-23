#!/usr/bin/env python3
"""bin/learn's work (story L1; contract .ade/context/learn.md). Run only by bin/learn (python3 -I), which passes
LEARN_HUB, LEARN_USER (a slug, hub_user in bin/lib.sh), LEARN_HERE (this session's folder, or empty), LEARN_ROLE,
LEARN_FOLDERS (one per line), LEARN_STATE (the hub's state dir, outside the checkout), LEARN_LINES (the session-start
budget) and LEARN_SESSION_VARS (agent_session_vars in bin/lib.sh). No model is ever called.
Exit 0 done, 1 refused / not found / not confirmed, 2 usage.
A capture is pending until the person confirms it at their own terminal (bin/learn confirm); only confirmed entries load.
A confirmation is a line in <state>/learn/confirmed.<user> holding the sha256 of what loads (see rule_hash, fact_hash)."""
import datetime, fcntl, hashlib, json, os, re, shutil, subprocess, sys, tempfile, unicodedata

ENV = os.environ
HUB, USER = ENV.get("LEARN_HUB", ""), ENV.get("LEARN_USER", "")
SLUG = re.compile(r"[a-z0-9][a-z0-9-]{0,59}")
NAME = re.compile(r"[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?")
BASE = os.path.join(HUB, "memory", "users", USER)
FB = os.path.join(BASE, "feedback")
STATE = ENV.get("LEARN_STATE") or os.path.join(HUB, ".local")
CONF = os.path.join(STATE, "learn", f"confirmed.{USER}")
FOLDERS = [f for f in ENV.get("LEARN_FOLDERS", "").split("\n") if f]
HERE, ROLE = ENV.get("LEARN_HERE", ""), ENV.get("LEARN_ROLE", "")
KEYS = ("scope", "rule", "first", "last", "repeated")
LIMITS = {"rule": 200, "words": 1000, "why": 300, "apply": 300, "fact": 300}
LINE = 200   # the longest line the session-start block prints
# dropped before two rule lines are compared (a repeat is equal after this; near-duplicates are the weekly review's, L2)
FILLER = {"a", "an", "the", "please", "just", "really", "always", "you", "should", "must"}
# The tripwire (rule, why, apply and profile facts): wording that grants an approval or switches off asking. A word list,
# matched case-insensitively as whole words; it catches the obvious, it is not a parser.
TRIPWIRE = ("pre-granted", "pre-approved", "without asking", "don't ask", "do not ask", "never ask", "no need to ask",
            "skip approval", "skip the review", "ignore", "override", "system:", "autonomous mode", "bypass")
TRIP = re.compile(r"(?<![a-z0-9])(?:" + "|".join(re.escape(w).replace(r"\ ", r"\s+") for w in TRIPWIRE) + r")(?![a-z0-9])",
                  re.I)
DAY = re.compile(r"\d{4}-\d{2}-\d{2}")
STAMP = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z")
EMAILS = (re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}"),
          re.compile(r"[A-Za-z0-9._%+-]+@(?:localhost\b|\[?\d{1,3}(?:\.\d{1,3}){3})", re.I),
          re.compile(r"\b[a-z0-9._%+-]+\s*(?:[(\[{]\s*at\s*[)\]}]|\sat\s)\s*[a-z0-9-]+"
                     r"(?:\s*(?:[(\[{]\s*dot\s*[)\]}]|\sdot\s)\s*[a-z0-9-]+)+\b", re.I))   # jane at client dot com
DATES = re.compile(r"\d{4}-\d{2}-\d{2}(?:[T ]\d{2}:\d{2}(?::\d{2})?Z?)?")   # removed before the number patterns run
PHONES = ((re.compile(r"\+\d[\d ().-]{6,}\d"), 8),                                   # +1 415 555 0134
          (re.compile(r"(?<![\w.])00\d{1,3}[ .-]?\d[\d .-]{6,}\d"), 10),             # 0044 20 7946 0958
          (re.compile(r"(?<![\w.])\(?\d{3}\)?[ .-]?\d{3}[ .-]\d{4}(?![\w.])"), 0),   # (415) 555-0134, 415.555.0134
          (re.compile(r"(?<![\w.:/-])\d{3}[ .-]\d{4}(?![\w.:/-])"), 0),               # 555-0134
          (re.compile(r"(?<![\w.])0\d{1,4}[ /-]\d{3,4}[ -]\d{3,4}(?![\w.])"), 0),     # 020 7946 0958
          (re.compile(r"(?<![\w.])\d{10,15}(?![\w.])"), 0))                           # 4155550134
NATIONAL_ID = re.compile(r"(?<![\w-])\d{3}-\d{2}-\d{4}(?![\w-])")                     # a US social security number
TOKEN_START = re.compile(r"(?<![A-Za-z0-9_-])(?:gh[pousr]_|github_pat_|sk-|xox[abprs]-|AKIA|glpat-)")
TOKEN = re.compile(r"gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|sk-[A-Za-z0-9_-]{20,}|xox[abprs]-[A-Za-z0-9-]{10,}"
                   r"|AKIA[0-9A-Z]{16}|glpat-[A-Za-z0-9_-]{20,}")
BIDI = set("؜‎‏‪‫‬‭‮⁦⁧⁨⁩")
ZERO = set("​‌‍⁠﻿᠎")


class Refused(Exception):
    pass


def die(msg, code):
    print(f"learn: {msg}", file=sys.stderr)
    sys.exit(code)


def now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def sha(text):
    return hashlib.sha256(text.encode("utf-8", "surrogateescape")).hexdigest()


def rule_hash(slug, fm):
    """What a confirmation of a rule covers: the user, the slug, the scope line and the rule line (what loads).
    Not `repeated`, `first`, `last`, the words, why or apply: a repeat keeps the entry confirmed."""
    return sha(f"feedback\n{USER}\n{slug}\n{fm['scope']}\n{fm['rule']}\n")


def fact_hash(day, fact):
    """What a confirmation of a profile fact covers: the user, its date and its text (the line that loads)."""
    return sha(f"profile\n{USER}\n{day}\n{fact}\n")


def cheap(text, multiline=False):
    """The reason text may not be stored, or None: control, bidi or zero-width characters, an email, a phone number,
    a national id number, a known token prefix split by spaces."""
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
    if any(p.search(text) for p in EMAILS):
        return "contains an email address"
    t = DATES.sub("D", text)
    if NATIONAL_ID.search(t):
        return "looks like a national id number"
    for p, digits in PHONES:
        for m in p.finditer(t):
            if sum(ch.isdigit() for ch in m.group()) >= digits:
                return "looks like a phone number"
    for m in TOKEN_START.finditer(text):
        s = re.sub(r"\s+", "", text[m.start():m.start() + 300])
        tok = TOKEN.match(s)
        if tok and any(ch.isdigit() for ch in tok.group()):
            return "looks like a secret (a token split by spaces)"
    return None


def tripwire(text):
    """The reason a rule, why, apply or profile fact may not load, or None: markup, links, headings, approval wording."""
    t = text.replace("’", "'")
    if "<!--" in t or "-->" in t:
        return "contains an HTML comment"
    if "<" in t or ">" in t:
        return "contains < or >"
    if re.search(r"\[[^\]]*\]\s*\(", t):
        return "contains a markdown link"
    if re.search(r"\b[a-z][a-z0-9+.-]{1,15}://|\bwww\.|\b(?:javascript|data|vbscript|file|mailto):", t, re.I):
        return "contains a URL"
    if any(line.lstrip().startswith("#") for line in t.split("\n")):
        return "has a line starting with #"
    if TRIP.search(t):
        return "has wording that grants an approval or switches off asking (the tripwire list)"
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
    """hub, a hub folder, role:<role> (every folder, captured at the hub root) or <folder>/role:<role> (that folder only)."""
    if s == "hub" or s in FOLDERS:
        return True
    if "/role:" in s:
        folder, _, role = s.rpartition("/role:")
        return folder in FOLDERS and bool(NAME.fullmatch(role))
    return s.startswith("role:") and bool(NAME.fullmatch(s[5:]))


def scope_folder(s):
    return s if s in FOLDERS else (s.rpartition("/role:")[0] if "/role:" in s else "")


def section(body, label):
    for line in body:
        if line.startswith(f"**{label}:**"):
            return line[len(label) + 5:].strip()
    return ""


def parse(text):
    """(front matter, body lines) of a feedback file; Refused when it is not a valid entry, or its rule, why or apply
    would not pass the checks a capture makes (the cheap ones and the tripwire)."""
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
        raise Refused("scope is not hub, a hub folder, role:<name> or <folder>/role:<name>")
    if not fm["rule"] or len(fm["rule"]) > LIMITS["rule"]:
        raise Refused(f"rule is empty or longer than {LIMITS['rule']} characters")
    if not (DAY.fullmatch(fm["first"]) and DAY.fullmatch(fm["last"])):
        raise Refused("first or last is not a YYYY-MM-DD date")
    if not re.fullmatch(r"[1-9][0-9]{0,5}", fm["repeated"]):
        raise Refused("repeated is not a count")
    body = lines[end + 1:]
    for name, v in (("rule", fm["rule"]), ("why", section(body, "Why")), ("apply", section(body, "How to apply"))):
        why = cheap(v) or tripwire(v)
        if why:
            raise Refused(f"{name} {why}")
    fm["repeated"] = int(fm["repeated"])
    return fm, body


def render(fm, body):
    head = ["---"] + [f"{k}: {fm[k]}" for k in KEYS] + ["---"]
    return "\n".join(head + body).rstrip("\n") + "\n"


def preflight(*files):
    """Refuse before the first write when a folder on the way, or a file this write touches, is a link or not a regular
    file/folder: a capture writes everything or nothing."""
    p = HUB
    for part in ("memory", "users", USER, "feedback"):
        p = os.path.join(p, part)
        if os.path.islink(p) or (os.path.lexists(p) and not os.path.isdir(p)):
            die(f"refused: {os.path.relpath(p, HUB)} is a link or not a folder; nothing stored", 1)
    for f in ("log.md", "MEMORY.md", "profile.md") + files:
        q = os.path.join(BASE, f)
        if os.path.islink(q) or (os.path.lexists(q) and not os.path.isfile(q)):
            die(f"refused: {os.path.relpath(q, HUB)} is a link or not a regular file; nothing stored", 1)


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".learn-")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text)
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)


def log(text):
    p = os.path.join(BASE, "log.md")
    new = not os.path.exists(p)
    os.makedirs(BASE, exist_ok=True)
    with open(p, "a", encoding="utf-8") as f:
        if new:
            f.write(f"# Learn log: {USER} (append-only: one dated line per capture, confirmation, edit or forget)\n\n")
        f.write(f"- {now()} {text}\n")


def lock():
    os.makedirs(STATE, exist_ok=True)
    f = open(os.path.join(STATE, "learn.lock"), "a")
    fcntl.flock(f, fcntl.LOCK_EX)
    return f


def confirmations():
    """{hash: name} from the confirmation file (outside the checkout)."""
    out = {}
    if os.path.isfile(CONF):
        with open(CONF, encoding="utf-8", errors="replace") as f:
            for line in f:
                h, _, name = line.strip().partition(" ")
                if re.fullmatch(r"[0-9a-f]{64}", h):
                    out[h] = name
    return out


def confirm_add(h, name):
    os.makedirs(os.path.dirname(CONF), exist_ok=True)
    with open(CONF, "a", encoding="utf-8") as f:
        f.write(f"{h} {name}\n")


def confirm_drop(name):
    """Every confirmation of this slug (or of all profile facts, name "profile") is dropped: the entry waits again."""
    if not os.path.isfile(CONF):
        return
    with open(CONF, encoding="utf-8", errors="replace") as f:
        keep = [line for line in f if line.strip().partition(" ")[2] != name]
    write(CONF, "".join(keep))


def entries():
    """([(slug, fm, body, confirmed)], [(slug, reason)]) for this person's feedback files, load order."""
    good, bad, conf = [], [], confirmations()
    if not os.path.isdir(FB):
        return good, bad
    for name in sorted(os.listdir(FB)):
        slug = name[:-3]
        if not name.endswith(".md") or not SLUG.fullmatch(slug):
            continue
        p = os.path.join(FB, name)
        try:
            if os.path.islink(p) or not os.path.isfile(p):
                raise Refused("is a link or not a regular file")
            with open(p, encoding="utf-8") as f:
                fm, body = parse(f.read())
            good.append((slug, fm, body, rule_hash(slug, fm) in conf))
        except (Refused, UnicodeDecodeError, OSError) as e:
            bad.append((slug, str(e) if isinstance(e, Refused) else "cannot be read as UTF-8"))
    good.sort(key=lambda e: e[0])
    good.sort(key=lambda e: e[1]["last"], reverse=True)
    good.sort(key=lambda e: e[1]["repeated"], reverse=True)
    return good, bad


def facts():
    """([(date, fact, confirmed)] that pass the checks, count of fact lines that do not) from profile.md."""
    p = os.path.join(BASE, "profile.md")
    good, bad, conf = [], 0, confirmations()
    if not os.path.isfile(p) or os.path.islink(p):
        return good, bad
    with open(p, encoding="utf-8", errors="replace") as f:
        for line in f.read().split("\n"):
            m = re.fullmatch(r"- (\d{4}-\d{2}-\d{2}): (.+)", line)
            if m and not (cheap(m.group(2)) or tripwire(m.group(2))):
                good.append((m.group(1), m.group(2), fact_hash(m.group(1), m.group(2)) in conf))
            elif line.startswith("- "):
                bad += 1
    return good, bad


def plural(n, word):
    return f"{n} {word}" + ("" if n == 1 else "s")


def reindex():
    good, bad = entries()
    fs = facts()[0]
    lines = [f"# What {USER} taught this hub (one line per entry; bin/learn list, confirm, show, edit, forget)", ""]
    if os.path.isfile(os.path.join(BASE, "profile.md")):
        w = sum(1 for f in fs if not f[2])
        lines.append(f"- [Profile](profile.md) — {plural(len(fs), 'fact')}" + (f", {w} waiting for confirmation" if w else ""))
    lines += [f"- [{fm['rule']}](feedback/{s}.md) — {fm['scope']}, x{fm['repeated']}" + ("" if c else ", waiting for confirmation")
              for s, fm, _, c in good]
    lines += [f"- [{s}](feedback/{s}.md) — not loaded: {why}" for s, why in bad]
    write(os.path.join(BASE, "MEMORY.md"), "\n".join(lines) + "\n")


def check(name, v):
    why = cheap(v) or (tripwire(v) if name != "words" else None) \
        or (f"is longer than {LIMITS[name]} characters" if len(v) > LIMITS[name] else None)
    if why:
        die(f"refused: --{name} {why}; nothing stored", 1)


def refuse_values(vals):
    for name, v in vals:
        check(name, v)
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
    if HERE and scope.startswith("role:"):
        scope = f"{HERE}/{scope}"   # a role rule captured in a folder holds for that folder only
    if not scope_ok(scope):
        die("--scope is hub, a hub folder (projects/<name>, ops/<name>) or role:<name>", 2)
    if HERE and scope_folder(scope) not in ("", HERE):
        die(f"refused: --scope names another folder than this session's ({HERE}); nothing stored", 1)
    vals = [("rule", opts["--rule"]), ("words", opts["--words"]), ("why", opts["--why"]), ("apply", opts["--apply"])]
    refuse_values(vals)
    rule, words, today = opts["--rule"], opts["--words"], now()[:10]
    if not norm(rule):
        die("refused: --rule has no words left once punctuation and filler words are dropped; nothing stored", 1)
    with lock():
        good, _ = entries()
        same = [(s, fm) for s, fm, _, _ in good if fm["scope"] == scope and norm(fm["rule"]) == norm(rule)]
        if same:
            slug = same[0][0]
            preflight(f"feedback/{slug}.md")
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
            state = "" if rule_hash(slug, fm) in confirmations() else "; waiting for confirmation (bin/learn confirm)"
            print(f"repeated {slug} (x{fm['repeated']}, {scope}): {fm['rule']}{state}")
            return
        base = re.sub(r"[^a-z0-9]+", "-", rule.lower()).strip("-")[:50].strip("-") or "rule"
        if base == "profile":
            base = "profile-rule"
        slug, n = base, 1
        while os.path.lexists(os.path.join(FB, slug + ".md")):
            n += 1
            slug = f"{base}-{n}"
        preflight(f"feedback/{slug}.md")
        fm = {"scope": scope, "rule": rule, "first": today, "last": today, "repeated": 1}
        body = [f"# {rule}", "", "## Their words", f"- {today}: {words}", "", f"**Why:** {opts['--why']}", "",
                f"**How to apply:** {opts['--apply']}"]
        write(os.path.join(FB, slug + ".md"), render(fm, body))
        log(f"feedback {slug} [{scope}]: {rule}")
        reindex()
        print(f"recorded {slug} ({scope}): {rule}\n"
              "waiting for confirmation: it loads only after the person runs bin/learn confirm at their own terminal")


def cmd_profile(args):
    if len(args) != 1 or not args[0].strip():
        die('usage: bin/learn profile "<fact>"', 2)
    fact = args[0].strip()
    refuse_values([("fact", fact)])
    with lock():
        preflight()
        p = os.path.join(BASE, "profile.md")
        old = open(p, encoding="utf-8").read() if os.path.exists(p) else f"# Profile: {USER}\n"
        gap = "" if re.search(r"^- ", old, re.M) else "\n"
        write(p, old.rstrip("\n") + "\n" + gap + f"- {now()[:10]}: {fact}\n")
        log(f"profile: {fact}")
        reindex()
        print(f"recorded a profile fact: {fact}\n"
              "waiting for confirmation: it loads only after the person runs bin/learn confirm at their own terminal")


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
    w = sum(1 for f in fs if not f[2])
    print(f"{'profile':<40} {plural(len(fs), 'fact')}" + (f", {w} waiting" if w else ""))
    for s, fm, _, c in good:
        print(f"{s:<40} {fm['scope']:<28} x{fm['repeated']:<4} {'confirmed' if c else 'waiting':<9} {fm['rule']}")
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


def person_only(what):
    """Refuse a command only the person may run when an agent session's variables are set (bin/lib.sh's one list)."""
    if any(ENV.get(v) for v in ENV.get("LEARN_SESSION_VARS", "").split()):
        die(f"refused: {what} is the person's own, at their own terminal, never from an agent session", 1)


def cmd_apply(args):
    person_only("edit")
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
    if not why and slug == "profile":
        why = next((tripwire(line[2:]) for line in text.split("\n") if line.startswith("- ") and tripwire(line[2:])), None)
    if why:
        die(f"refused: the edited file {why}; nothing changed", 1)
    why = secret(text)
    if why:
        die(f"refused: the edited file {why}; nothing changed" if why.startswith("looks") else f"refused: {why}; nothing changed", 1)
    with lock():
        preflight() if slug == "profile" else preflight(f"feedback/{slug}.md")
        if open(p, encoding="utf-8", errors="replace").read() == text:
            print(f"no change to {slug}")
            return
        write(p, text)
        confirm_drop(slug)
        log(f"edited {slug}: {rule}" if rule else f"edited {slug}")
        reindex()
        print(f"saved {slug}; it waits for confirmation again (bin/learn confirm)")


def cmd_forget(args):
    person_only("forget")
    slug = args[0]
    with lock():
        preflight() if slug == "profile" else preflight(f"feedback/{slug}.md")
        p = find(slug)
        os.remove(p)
        confirm_drop(slug)
        log(f"forgot {slug}")
        reindex()
        print(f"forgot {slug}")


def shown(text):
    """Text as it is safe to print to a terminal: every control or format character a ?."""
    return "".join("?" if unicodedata.category(c)[0] == "C" else c for c in text)


def cmd_confirm(args):
    person_only("confirm")
    if len(args) > 1:
        die("usage: bin/learn confirm [<slug>|profile]", 2)
    try:
        tin, tout = open("/dev/tty", encoding="utf-8", errors="replace"), open("/dev/tty", "w", encoding="utf-8")
    except OSError:
        die("refused: confirm needs the person at an interactive terminal; nothing confirmed", 1)
    want = args[0] if args else None
    if want is not None and want != "profile" and not SLUG.fullmatch(want):
        die("not a slug: use bin/learn list", 2)
    good, _ = entries()
    todo = [("rule", s, fm, body) for s, fm, body, c in good if not c and want in (None, s)]
    todo += [("fact", "profile", {"date": d, "fact": t}, None) for d, t, c in facts()[0] if not c and want in (None, "profile")]
    if not todo:
        print(f"nothing waiting for {USER}" + (f" under {want}" if want else ""))
        return 1 if want and want != "profile" and not any(s == want for s, *_ in good) else 0
    done = {"y": 0, "n": 0, "l": 0}
    for i, (kind, slug, fm, body) in enumerate(todo, 1):
        if kind == "rule":
            words = [line[2:] for line in body if line.startswith("- ") and DAY.match(line[2:12])]
            show = [f"[{i}/{len(todo)}] {slug}", f"  scope: {fm['scope']}", f"  rule:  {fm['rule']}", "  their words:"]
            show += [f"    {w}" for w in words] + [f"  why:   {section(body, 'Why')}", f"  apply: {section(body, 'How to apply')}"]
        else:
            show = [f"[{i}/{len(todo)}] profile fact", f"  {fm['date']}: {fm['fact']}"]
        tout.write("\n".join(shown(line) for line in show) + "\nLoad this in your sessions? [y]es, [n]o (delete it), [l]ater: ")
        tout.flush()
        a = tin.readline().strip().lower()[:1]
        a = a if a in ("y", "n") else "l"
        done[a] += 1
        if a == "l":
            continue
        with lock():
            if kind == "rule":
                p = os.path.join(FB, slug + ".md")
                try:
                    now_fm = parse(open(p, encoding="utf-8").read())[0]
                except (OSError, Refused, UnicodeDecodeError):
                    now_fm = None
                if now_fm is None or rule_hash(slug, now_fm) != rule_hash(slug, fm):
                    tout.write("  it changed while you looked: left waiting\n")
                    continue
                if a == "y":
                    confirm_add(rule_hash(slug, fm), slug)
                    log(f"confirmed {slug}")
                else:
                    preflight(f"feedback/{slug}.md")
                    os.remove(p)
                    log(f"rejected {slug}")
            else:
                h = fact_hash(fm["date"], fm["fact"])
                if a == "y":
                    confirm_add(h, "profile")
                    log(f"confirmed profile {fm['date']}")
                else:
                    preflight()
                    p = os.path.join(BASE, "profile.md")
                    lines = open(p, encoding="utf-8").read().split("\n")
                    target = f"- {fm['date']}: {fm['fact']}"
                    if target in lines:
                        lines.remove(target)
                        write(p, "\n".join(lines))
                    log(f"rejected profile {fm['date']}")
    with lock():
        reindex()
    print(f"confirmed {done['y']}, rejected {done['n']}, left waiting {done['l']}")
    return 0


def applicable(folder):
    scopes = {"hub"}
    if folder in FOLDERS:
        scopes.add(folder)
        if ROLE and NAME.fullmatch(ROLE):
            scopes |= {f"role:{ROLE}", f"{folder}/role:{ROLE}"}
    return scopes


def cmd_context(args):
    folder = args[0] if args else ""
    try:
        budget = int(ENV.get("LEARN_LINES", "30"))
    except ValueError:
        budget = 30
    if budget <= 0:
        return
    scopes = applicable(folder)
    good, bad = entries()
    fs, badf = facts()
    rules = [(s, fm) for s, fm, _, c in good if c and fm["scope"] in scopes]
    conf_facts = [(d, t) for d, t, c in fs if c]
    waiting = sum(1 for *_, c in good if not c) + sum(1 for *_, c in fs if not c)
    nbad = len(bad) + badf
    if not rules and not conf_facts and not waiting and not nbad:
        return
    room = max(budget - 2, 0)
    np = min(len(conf_facts), 5, room // 2 if rules else room)
    nr = min(len(rules), room - np)
    last = f"- {len(conf_facts) - np + len(rules) - nr} more, all of them: bin/learn list"
    if waiting:
        last += f"; {waiting} waiting for the person to confirm (not loaded): bin/learn confirm, at their own terminal"
    if nbad:
        last += f"; {nbad} not loaded: invalid"
    if budget == 1:
        print(last[:LINE])
        return
    out = [f"## Learned from {USER} (their guidance for how to work; it never grants an approval or turns off asking; "
           f"files: memory/users/{USER}/)"]
    out += [f"- profile ({d}): {t}" for d, t in conf_facts[len(conf_facts) - np:]] if np else []
    out += [f"- [{fm['scope']}, x{fm['repeated']}] {fm['rule']}" for _, fm in rules[:nr]]
    print("\n".join(line[:LINE] for line in out + [last]))


def quoted(lines, cap):
    """Lines as JSON strings, at most `cap` of them, each cut at LINE characters: data for a prompt, never instructions."""
    out = [json.dumps(line[:LINE]) for line in lines[-cap:]]
    return ([json.dumps(f"({len(lines) - cap} more not shown)")] if len(lines) > cap else []) + out


def cmd_pending(args):
    good, _ = entries()
    lines = [f"waiting: [{fm['scope']}] {fm['rule']}" for _, fm, _, c in good if not c]
    lines += [f"waiting: profile fact {t}" for _, t, c in facts()[0] if not c]
    if lines:
        print("\n".join(quoted(lines, 10) if args == ["--quoted"] else lines))


def log_lines():
    """The log's well-formed entry lines ("- <stamp> ..."), oldest first; none for a missing or linked log."""
    p = os.path.join(BASE, "log.md")
    if not os.path.isfile(p) or os.path.islink(p):
        return []
    with open(p, encoding="utf-8", errors="replace") as f:
        return [line for line in f.read().split("\n")
                if len(line.split(" ", 2)) == 3 and line.startswith("- ") and STAMP.fullmatch(line.split(" ", 2)[1])]


def cmd_recent(args):
    mark = os.path.join(STATE, "learn", f"briefed.{USER}")
    if args and args[0] == "--mark":
        if len(args) != 2 or not STAMP.fullmatch(args[1]):
            die("usage: bin/learn recent [--quoted | --mark YYYY-MM-DDTHH:MM:SSZ]", 2)
        os.makedirs(os.path.dirname(mark), exist_ok=True)
        # the mark is a second, and log stamps are seconds: also keep the entries of that very second that exist now
        # (the ones this briefing listed), so a later entry in the same second is still listed next time
        same = [line for line in log_lines() if line.split(" ", 2)[1] == args[1]]
        with open(mark, "w") as f:
            f.write("\n".join([args[1]] + same) + "\n")
        return
    if args not in ([], ["--quoted"]):
        die("usage: bin/learn recent [--quoted | --mark YYYY-MM-DDTHH:MM:SSZ]", 2)
    marked = open(mark, encoding="utf-8", errors="replace").read().split("\n") if os.path.isfile(mark) else [""]
    since, seen = marked[0].strip(), set(marked[1:])
    lines = [line for line in log_lines()
             if (line.split(" ", 2)[1] > since or (line.split(" ", 2)[1] == since and line not in seen)) and not cheap(line)]
    if lines:
        print("\n".join(quoted(lines, 20) if args else [line[:LINE] for line in lines[-20:]]))


CMDS = {"feedback": cmd_feedback, "profile": cmd_profile, "list": cmd_list, "show": cmd_show, "path": cmd_path,
        "apply": cmd_apply, "forget": cmd_forget, "confirm": cmd_confirm, "context": cmd_context,
        "pending": cmd_pending, "recent": cmd_recent}

if __name__ == "__main__":
    if not HUB or not NAME.fullmatch(USER):
        die("run it as bin/learn (no hub or no user)", 2)
    if len(sys.argv) < 2 or sys.argv[1] not in CMDS:
        die("usage: bin/learn feedback|profile|list|confirm|show|edit|forget|context|pending|recent", 2)
    sys.exit(CMDS[sys.argv[1]](sys.argv[2:]) or 0)
