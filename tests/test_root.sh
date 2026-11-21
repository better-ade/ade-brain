#!/bin/bash
. "$(dirname "$0")/helpers.sh"
make_hub; cd "$HUB"
for s in "## Shared rules" "## Coordination" "Approvals come through the main session" "Check what {{OWNER}} already sent" "Client contact data stays out of the hub repo" "Decide routine choices yourself" "## The main agent" "## Git boundaries" "## Token budget" "@memory/MEMORY.md" "{{PERSONA}}" "{{OWNER}}"; do assert_contains templates/hub/CLAUDE.md "$s" "hub CLAUDE.md template"; done
python3 -c "import json; d=json.load(open('.claude/settings.json')); assert 'bin/context' in d['hooks']['SessionStart'][0]['hooks'][0]['command']" || fail "root SessionStart hook"
grep -rqiE "(api[_-]?key|token|password)\s*[:=]\s*[A-Za-z0-9_-]{16,}" templates personas CLAUDE.md README.md && fail "something secret-looking in the template"
grep -rqi "orillia\|arjuns57\|jared" bin templates personas docs README.md CLAUDE.md && fail "a client-specific name is left in the template"
# bin/init copies the whole template into each hub: hub agents are rendered by bin/init, never shipped pre-made
[ -z "$(ls -A .claude/agents 2>/dev/null)" ] || fail "the template ships agents in .claude/agents (bin/init renders a hub's agents)"
# every relative link in an llms.txt index points at a file the hub actually has
[ ! -f llms.txt ] || for l in $(grep -oE '\]\([^)]+\)' llms.txt | sed -E 's/^\]\(//; s/\)$//' | grep -v '://'); do [ -e "$l" ] || fail "llms.txt links to missing $l"; done
python3 -c "import json; d=json.load(open('.claude/settings.json')); assert 'attribution' not in d and 'includeCoAuthoredBy' not in d" || fail "the template overrides commit attribution for every hub"
grep -rni "alvin" templates && fail "a person's name is hard-coded in templates/ (use {{OWNER}})"
grep -rniI --exclude-dir=__pycache__ "alvin" bin tests | grep -v "^tests/test_root.sh:" && fail "a person's name in bin/ or tests/ (test fixtures say Owner)"
grep -rnE "[A-Z]{4,}_STATE=" tests | grep -vqE "(AGENT|HUB)_STATE=" && fail "a test sets another hub's state variable (only AGENT_STATE)"
grep -rni "alvin" _bmad/custom && fail "a person's name in _bmad/custom/ (every hub copies it; say 'owner')"
# every user-facing bin/work flag and the session list are documented
for d in README.md docs/index.html templates/hub/README.md; do
  grep -q "bin/sessions" "$d" || fail "$d does not mention bin/sessions"; grep -q -- "--force" "$d" || fail "$d does not mention bin/work --force"; done
n=$(ls personas/*.md | wc -l | tr -d ' '); [ "$n" -ge 10 ] || fail "persona library has $n personas"
for p in personas/*.md; do for k in title folders briefing_focus; do grep -q "^$k: ." "$p" || fail "$p has no $k"; done
  grep -q "{{CLIENT}}" "$p" && grep -q "{{OWNER}}" "$p" || fail "$p does not name the client and owner"; done
# the ADE rules are ade-method's own (story C1): test_method.sh keeps .ade/rules.md equal to the pinned ref
echo ok
