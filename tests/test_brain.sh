#!/bin/bash
. "$(dirname "$0")/helpers.sh"
make_hub; cd "$HUB"
bin/new projects/demo >/dev/null
cat > projects/demo/STATE.md <<'MD'
# State: demo
## Live
- The billing service runs on the staging box.
## Open
- Lauren asked to stop the SMS lead alerts; email already reaches her phone.
MD
mkdir -p projects/demo/notes; cat > projects/demo/notes/call.md <<'MD'
# Call 29 Oct
## Photos
No families or faces in the hero photos; use small towns and main streets.
MD
# a fake key built from parts, so the literal never sits in the repo (gitleaks would flag the test itself)
printf '## Secrets\naws_secret_access_key = %s\n' "9fXvPj2LsZqk1Wm8""RtYb3Nc7Hd5Ea0Ug4Ko6Ti2s" >> projects/demo/notes/call.md
X="$(mktemp -d)"; printf '# Proposal\n## Borrower portal\nStage 1 discovery costs CAD 5,750.\n' > "$X/portal.md"
# 1. keyword-only: no embedding server reachable, still indexes and finds
out=$(AGENT_OLLAMA_URL=http://127.0.0.1:9 AGENT_BRAIN_PATHS="$X" bin/brain index 2>&1) || fail "index without ollama failed: $out"
echo "$out" | grep -qi "keyword only" || fail "says it fell back to keyword search: [$out]"
AGENT_OLLAMA_URL=http://127.0.0.1:9 bin/brain search "SMS lead alerts" | head -1 | grep -q "projects/demo/STATE.md:" || fail "keyword hit with path"
AGENT_OLLAMA_URL=http://127.0.0.1:9 bin/brain search "discovery" | grep -q "portal.md" || fail "extra paths indexed"
bin/brain search "aws_secret_access_key" | grep -q "call.md" && fail "a chunk with a secret was indexed"
[ -f .local/brain.db ] || fail "db at .local/brain.db"; grep -q '^\.local/' .gitignore || fail ".local/ is gitignored"
# 2. vectors via an Ollama-compatible server
P="$(mktemp -d)"; python3 "$REPO/tests/fake_ollama.py" "$P/port" "$P/models" & SRV=$!; trap 'kill $SRV 2>/dev/null' EXIT
for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$P/port" ] && break; sleep 0.2; done
U="http://127.0.0.1:$(cat "$P/port")"
AGENT_OLLAMA_URL="$U" AGENT_BRAIN_PATHS="$X" bin/brain index --full >/dev/null || fail "full index with vectors"
assert_contains "$P/models" "nomic-embed-text" "default embedding model"
st=$(AGENT_OLLAMA_URL="$U" bin/brain status); echo "$st" | grep -qE "embedded +[1-9]" || fail "chunks embedded: [$st]"
echo "$st" | grep -qE "^stale +0" || fail "nothing stale after index: [$st]"
# semantic: words not in the text's exact form still rank the right section first via the vector side
AGENT_OLLAMA_URL="$U" bin/brain search "hero photos families" | head -1 | grep -q "call.md:.*Photos" || fail "hybrid search ranks the photos section"
AGENT_OLLAMA_URL="$U" bin/brain search --json "billing service" | python3 -c "import json,sys; r=json.load(sys.stdin); assert r[0]['path'].endswith('STATE.md') and r[0]['line']>0" || fail "--json output"
# 3. incremental: an unchanged hub re-embeds nothing; an edit re-embeds one file; a delete removes it
: > "$P/models"; AGENT_OLLAMA_URL="$U" AGENT_BRAIN_PATHS="$X" bin/brain index >/dev/null
[ -s "$P/models" ] && fail "unchanged files were re-embedded"
echo "- Renewal questions go to servicing." >> projects/demo/STATE.md
AGENT_OLLAMA_URL="$U" bin/brain status | grep -qE "^stale +1" || fail "edit makes one file stale"
AGENT_OLLAMA_URL="$U" AGENT_BRAIN_PATHS="$X" bin/brain index >/dev/null
AGENT_OLLAMA_URL="$U" bin/brain search "renewal servicing" | head -1 | grep -q "STATE.md" || fail "edit indexed"
rm "$X/portal.md"; AGENT_OLLAMA_URL="$U" AGENT_BRAIN_PATHS="$X" bin/brain index >/dev/null
bin/brain search "discovery" | grep -q "portal.md" && fail "deleted file still indexed"
# 3b. a memory file's front matter titles its first section (name: description)
printf -- '---\nname: sms-feedback\ndescription: content team on SMS lead alerts\nmetadata:\n  type: project\n---\n\nThey find the alerts noisy.\n' > memory/sms-feedback.md
AGENT_OLLAMA_URL="$U" bin/brain index >/dev/null
out=$(AGENT_OLLAMA_URL="$U" bin/brain search "sms feedback noisy"); echo "$out" | head -1 | grep -q "memory/sms-feedback.md:1  sms-feedback: content team on SMS lead alerts" || fail "front matter is the heading: [$out]"
echo "$out" | head -2 | tail -1 | grep -q "metadata" && fail "front matter left in the snippet"
# 3c. a glob path indexes only matching files (top-level briefs, not whole checkouts beside them)
G="$(mktemp -d)"; printf '# Brief\nquokka strategy\n' > "$G/brief one.md"; mkdir -p "$G/repo"; printf '# Deep\nquokka internals\n' > "$G/repo/deep.md"
AGENT_OLLAMA_URL="$U" AGENT_BRAIN_PATHS="$X $G/*.md" bin/brain index >/dev/null
out=$(bin/brain search quokka); echo "$out" | grep -q "brief one.md" || fail "glob file (with a space) indexed: [$out]"
echo "$out" | grep -q "deep.md" && fail "glob indexed a file outside the pattern"
# 4. skipped trees and bad input
mkdir -p .claude/skills/x repos/y; echo "# zebra skill" > .claude/skills/x/SKILL.md; echo "# zebra repo" > repos/y/a.md
AGENT_OLLAMA_URL="$U" bin/brain index >/dev/null; bin/brain search zebra | grep -q . && fail "skills or repos indexed"
bin/brain search >/dev/null 2>&1; assert_eq "$?" "2" "search needs a query"
bin/brain nope >/dev/null 2>&1; assert_eq "$?" "2" "unknown command"
# 5. story C4: each folder's code checkouts (ACCESS.md) add their .ade/context and .ade/knowledge Markdown, read-only
C="$(mktemp -d)/demo-code"; mkdir -p "$C/.ade/context/decisions" "$C/.ade/knowledge" "$C/docs" "$C/src" "$C/.github"
printf '# 0001 Pick walrus\nWe chose the walrus queue for jobs.\n' > "$C/.ade/context/decisions/0001-x.md"
printf '# Ops\nThe narwhal cache warms at boot.\n' > "$C/.ade/knowledge/ops.md"
printf '# Guide\nokapi docs only\n' > "$C/docs/guide.md"; printf '# Src\nokapi code\n' > "$C/src/readme.md"
printf '# CI\nokapi ci\n' > "$C/.github/ci.md"; printf '# Other\nokapi other ade\n' > "$C/.ade/notes.md"
printf 'okapi context text\n' > "$C/.ade/context/plain.txt"
printf '| demo-code | %s | main | owner | none |\n| gone | /nonexistent/gone-code | main | owner | none |\n' "$C" >> projects/demo/ACCESS.md
before=$(cd "$C" && python3 -c 'import os
for r, _, fs in os.walk("."):
    for f in fs: p = os.path.join(r, f); s = os.stat(p); print(p, int(s.st_mtime), s.st_size)' | sort)
out=$(AGENT_OLLAMA_URL="$U" bin/brain index 2>&1) || fail "index with a missing checkout failed: [$out]"   # missing_checkout_skipped
out=$(bin/brain search walrus queue); echo "$out" | head -1 | grep -q "decisions/0001-x.md:" || fail "project_decision_indexed: [$out]"
echo "$out" | head -1 | grep -q "^projects/demo: demo-code/.ade/context/decisions/0001-x.md:1" || fail "results_name_project: [$out]"
bin/brain search narwhal cache | head -1 | grep -q "^projects/demo: demo-code/.ade/knowledge/ops.md:" || fail "project_knowledge_indexed"
bin/brain search okapi | grep -q . && fail "only_ade_folders: [$(bin/brain search okapi)]"
after=$(cd "$C" && python3 -c 'import os
for r, _, fs in os.walk("."):
    for f in fs: p = os.path.join(r, f); s = os.stat(p); print(p, int(s.st_mtime), s.st_size)' | sort)
assert_eq "$after" "$before" "checkout_untouched"
rm "$C/.ade/context/decisions/0001-x.md"; AGENT_OLLAMA_URL="$U" bin/brain index >/dev/null
bin/brain search walrus | grep -q "0001-x.md" && fail "removed_file_dropped"
echo ok
