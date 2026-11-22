"""The hub's searchable memory: Markdown sections in SQLite, with FTS5 keyword search and vectors from a local
Ollama embedding model, ranked together. Files stay the source of truth; this index is rebuilt from them.

Run through bin/brain, which passes the hub's settings as environment variables:
  BRAIN_HUB, BRAIN_PATHS (extra dirs/files, space-separated), BRAIN_OLLAMA_URL, BRAIN_MODEL,
  BRAIN_CHECKOUTS ("<folder>\t<checkout>" lines: only each checkout's .ade/context and .ade/knowledge Markdown, read-only).
"""
import array
import glob
import hashlib
import json
import os
import re
import sqlite3
import sys
import urllib.error
import urllib.request

HUB = os.environ["BRAIN_HUB"]
DB = os.path.join(HUB, ".local", "brain.db")
URL = os.environ.get("BRAIN_OLLAMA_URL", "http://localhost:11434").rstrip("/")
MODEL = os.environ.get("BRAIN_MODEL", "nomic-embed-text")
SKIP_DIRS = {".git", ".claude", "_bmad", "_bmad-output", "repos", "node_modules", ".local", "templates", "personas",
             "tests", "test", "launchd", "dist", "build", "runs", "vendor", "target"}
EXTS = (".md", ".txt")
PROJECT_DIRS = (".ade/context", ".ade/knowledge")   # the only parts of a code checkout the brain reads (story C4)
MAX_CHUNK = 2000
# A chunk that looks like it holds a secret is never indexed (gitleaks guards commits; this guards the index).
SECRET = re.compile(r"AKIA[0-9A-Z]{16}|(?:secret|password|passwd|token|api[_-]?key)[\w-]*\s*[:=]\s*['\"]?[A-Za-z0-9/+_=-]{16,}"
                    r"|-----BEGIN [A-Z ]*PRIVATE KEY|\bsk-[A-Za-z0-9_-]{20,}|\bghp_[A-Za-z0-9]{30,}|\bxox[abp]-[A-Za-z0-9-]{10,}"
                    r"|\bpat-[a-z0-9]{2,}-[0-9a-f-]{20,}", re.I)


def die(msg, code=2):
    print(f"brain: {msg}", file=sys.stderr)
    sys.exit(code)


def connect():
    os.makedirs(os.path.dirname(DB), exist_ok=True)
    db = sqlite3.connect(DB)
    db.executescript("""
      CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT);
      CREATE TABLE IF NOT EXISTS files(path TEXT PRIMARY KEY, hash TEXT);
      CREATE TABLE IF NOT EXISTS chunks(id INTEGER PRIMARY KEY, path TEXT, line INTEGER, heading TEXT, text TEXT, vec BLOB);
      CREATE INDEX IF NOT EXISTS chunks_path ON chunks(path);
      CREATE VIRTUAL TABLE IF NOT EXISTS fts USING fts5(heading, text);
    """)
    return db


def sources():
    """{display path: absolute path} for the hub's Markdown plus BRAIN_PATHS."""
    out = {}

    def walk(root, rel_to):
        if os.path.isfile(root):
            if root.endswith(EXTS):
                out[display(root, rel_to)] = root
            return
        for d, dirs, files in os.walk(root):
            dirs[:] = sorted(x for x in dirs if x not in SKIP_DIRS and not x.startswith("."))
            if rel_to == HUB and os.path.relpath(d, HUB) == os.path.join("memory", "users"):   # story L1: this person's only
                dirs[:] = [x for x in dirs if x == os.environ.get("BRAIN_USER", "")]
            for f in sorted(files):
                if f.endswith(EXTS):
                    p = os.path.join(d, f)
                    out[display(p, rel_to)] = p

    walk(HUB, HUB)
    for pat in os.environ.get("BRAIN_PATHS", "").split():
        # a folder (walked), a file, or a glob such as ~/docs/*.md (matches may contain spaces)
        for p in sorted(glob.glob(os.path.expanduser(pat))) if any(c in pat for c in "*?[") else [os.path.expanduser(pat)]:
            if os.path.exists(p):
                walk(os.path.abspath(p), None)
    for line in os.environ.get("BRAIN_CHECKOUTS", "").splitlines():
        folder, _, repo = line.partition("\t")
        if not repo:
            continue
        name = os.path.basename(repo.rstrip(os.sep))
        for sub in PROJECT_DIRS:
            # a missing or unreadable checkout yields nothing: os.walk skips what it cannot list
            for d, dirs, files in os.walk(os.path.join(repo, sub)):
                dirs.sort()
                for f in sorted(files):
                    if f.endswith(".md"):
                        p = os.path.join(d, f)
                        out[f"{folder}: {name}/{os.path.relpath(p, repo)}"] = p
    return out


def display(p, rel_to):
    if rel_to and p.startswith(rel_to + os.sep):
        return os.path.relpath(p, rel_to)
    home = os.path.expanduser("~")
    return "~" + p[len(home):] if p.startswith(home + os.sep) else p


def chunks_of(text):
    """Split Markdown into (line, heading, body) sections at headings; long sections split at blank lines."""
    out, head, start, buf = [], "", 1, []

    def flush():
        body = "\n".join(buf).strip()
        if not body and not head:
            return
        while len(body) > MAX_CHUNK:
            cut = body.rfind("\n\n", 0, MAX_CHUNK)
            cut = cut if cut > 0 else MAX_CHUNK
            out.append((start, head, body[:cut].strip()))
            body = body[cut:].strip()
        out.append((start, head, body))

    lines = text.splitlines()
    # YAML front matter (memory files): its name and description title the first section; the block itself is dropped
    first = 0
    if lines and lines[0].strip() == "---" and "---" in [l.strip() for l in lines[1:]]:
        end = [l.strip() for l in lines[1:]].index("---") + 1
        fm = dict(re.match(r"(\w+):\s*(.*)", l).groups() for l in lines[1:end] if re.match(r"\w+:\s*\S", l))
        name, desc = fm.get("name", "").strip('"'), fm.get("description", "").strip('"')
        head = f"{name}: {desc}" if name and desc else name or desc
        first = end + 1
    for i, line in enumerate(lines, 1):
        if i <= first:
            continue
        if re.match(r"#{1,6}\s", line):
            flush()
            head, start, buf = line.lstrip("#").strip(), i, []
        else:
            buf.append(line)
    flush()
    return [c for c in out if not SECRET.search(c[1] + "\n" + c[2])]


class Embedder:
    def __init__(self):
        self.ok, self.why = True, ""

    def __call__(self, texts, prefix):
        if not self.ok or not texts:
            return None
        vecs = []
        try:
            for i in range(0, len(texts), 32):
                body = json.dumps({"model": MODEL, "input": [prefix + t for t in texts[i:i + 32]]}).encode()
                req = urllib.request.Request(URL + "/api/embed", body, {"Content-Type": "application/json"})
                with urllib.request.urlopen(req, timeout=60) as r:
                    vecs += json.load(r)["embeddings"]
        except (urllib.error.URLError, OSError, ValueError, KeyError) as e:
            self.ok, self.why = False, f"Ollama not reachable at {URL} with model {MODEL} ({e.__class__.__name__})"
            return None
        return [normalize(v) for v in vecs]


def normalize(v):
    n = sum(x * x for x in v) ** 0.5 or 1.0
    return array.array("f", (x / n for x in v))


def file_hash(p):
    """sha1 of the file, or None when it cannot be read (it is then skipped, not indexed)."""
    try:
        with open(p, "rb") as f:
            return hashlib.sha1(f.read()).hexdigest()
    except OSError:
        return None


def cmd_index(args):
    db, emb = connect(), Embedder()
    if "--full" in args:
        db.executescript("DELETE FROM files; DELETE FROM chunks; DELETE FROM fts; DELETE FROM meta;")
    src, known = sources(), dict(db.execute("SELECT path, hash FROM files"))
    changed = 0
    for path in set(known) - set(src):
        drop(db, path)
    for path, real in src.items():
        h = file_hash(real)
        if h is None or known.get(path) == h:
            continue
        drop(db, path)
        with open(real, encoding="utf-8", errors="replace") as f:
            for line, head, body in chunks_of(f.read()):
                cur = db.execute("INSERT INTO chunks(path, line, heading, text) VALUES(?,?,?,?)", (path, line, head, body))
                db.execute("INSERT INTO fts(rowid, heading, text) VALUES(?,?,?)", (cur.lastrowid, head, body))
        db.execute("INSERT INTO files(path, hash) VALUES(?,?)", (path, h))
        changed += 1
    # embed every chunk that has no vector yet (new, changed, or left over from a run without Ollama)
    todo = db.execute("SELECT id, heading, text FROM chunks WHERE vec IS NULL").fetchall()
    vecs = emb([f"{h}\n{t}" for _, h, t in todo], "search_document: ") if todo else []
    if vecs:
        for (cid, _, _), v in zip(todo, vecs):
            db.execute("UPDATE chunks SET vec=? WHERE id=?", (v.tobytes(), cid))
        db.execute("INSERT OR REPLACE INTO meta VALUES('model', ?), ('dim', ?)", (MODEL, str(len(vecs[0]))))
    db.commit()
    n = db.execute("SELECT count(*) FROM chunks").fetchone()[0]
    mode = "keyword + vector" if emb.ok else f"keyword only: {emb.why}"
    print(f"indexed {changed} changed file(s); {n} sections; {mode}")


def drop(db, path):
    ids = [r[0] for r in db.execute("SELECT id FROM chunks WHERE path=?", (path,))]
    db.executemany("DELETE FROM fts WHERE rowid=?", [(i,) for i in ids])
    db.execute("DELETE FROM chunks WHERE path=?", (path,))
    db.execute("DELETE FROM files WHERE path=?", (path,))


def cmd_search(args):
    as_json = "--json" in args
    args = [a for a in args if a != "--json"]
    n = 8
    if "-n" in args:
        i = args.index("-n")
        try:
            n = int(args[i + 1])
        except (IndexError, ValueError):
            die("-n needs a number")
        del args[i:i + 2]
    q = " ".join(args).strip()
    if not q:
        die("usage: bin/brain search [-n N] [--json] <query>")
    if not os.path.exists(DB):
        die("no index yet: run bin/brain index", 1)
    db = connect()
    ranks = {}
    words = re.findall(r"\w+", q)
    if words:
        match = " OR ".join('"%s"' % w for w in words)
        for r, (cid,) in enumerate(db.execute("SELECT rowid FROM fts WHERE fts MATCH ? ORDER BY bm25(fts) LIMIT 50", (match,))):
            ranks[cid] = ranks.get(cid, 0) + 1 / (60 + r)
    meta = dict(db.execute("SELECT k, v FROM meta"))
    if meta.get("model") == MODEL and db.execute("SELECT 1 FROM chunks WHERE vec IS NOT NULL LIMIT 1").fetchone():
        qv = Embedder()([q], "search_query: ")
        if qv and str(len(qv[0])) == meta.get("dim"):
            qv, scored = qv[0], []
            for cid, blob in db.execute("SELECT id, vec FROM chunks WHERE vec IS NOT NULL"):
                v = array.array("f")
                v.frombytes(blob)
                scored.append((sum(a * b for a, b in zip(qv, v)), cid))
            for r, (_, cid) in enumerate(sorted(scored, reverse=True)[:50]):
                ranks[cid] = ranks.get(cid, 0) + 1 / (60 + r)
    top = sorted(ranks.items(), key=lambda x: -x[1])[:n]
    rows = []
    for cid, score in top:
        path, line, head, text = db.execute("SELECT path, line, heading, text FROM chunks WHERE id=?", (cid,)).fetchone()
        rows.append({"path": path, "line": line, "heading": head, "score": round(score, 5),
                     "snippet": " ".join(text.split())[:200]})
    if as_json:
        print(json.dumps(rows, indent=1))
        return
    for r in rows:
        print(f"{r['path']}:{r['line']}  {r['heading']}\n    {r['snippet']}")


def cmd_status(_):
    db = connect()
    known = dict(db.execute("SELECT path, hash FROM files"))
    src = sources()
    stale = sum(1 for p, real in src.items() if known.get(p) != file_hash(real))
    meta = dict(db.execute("SELECT k, v FROM meta"))
    one = lambda sql: db.execute(sql).fetchone()[0]
    print(f"files     {len(known)}\nsections  {one('SELECT count(*) FROM chunks')}\n"
          f"embedded  {one('SELECT count(*) FROM chunks WHERE vec IS NOT NULL')}\nstale     {stale}\n"
          f"model     {meta.get('model', '(none yet)')} via {URL}\ndb        {DB}")


if __name__ == "__main__":
    cmds = {"index": cmd_index, "search": cmd_search, "status": cmd_status}
    if len(sys.argv) < 2 or sys.argv[1] not in cmds:
        die("usage: bin/brain index [--full] | search [-n N] [--json] <query> | status")
    cmds[sys.argv[1]](sys.argv[2:])
