#!/bin/bash
. "$(dirname "$0")/helpers.sh"
make_hub; cd "$HUB"
bin/init --list | grep -q "^staff-software-engineer *Staff Software Engineer" || fail "--list shows personas"
# --dest: a new hub for a DevOps persona, from a copy
D="$(mktemp -d)/acme-ops"; CO="$(mktemp -d)/acme-infra"; mkdir -p "$CO"
bin/init --persona devops-sre --client "Acme Corp" --owner "Sam Lee" --dest "$D" --repo acme/infra="$CO" \
  --remote deploy@box.acme.test:2222 --remote-key /keys/acme --remote-dir /srv/app --staging-url https://staging.acme.test \
  --secret grafana-token --briefing 07:30 --auto-sync off --brain-path ~/notes --embed-model mxbai-embed-large >/dev/null || fail "init --dest failed"
[ -f "$HUB/hub.conf" ] && fail "--dest wrote into the template"
cd "$D"
for f in hub.conf CLAUDE.md ACCESS.md README.md .claude/agents/devops-sre.md ops/environments/STATE.md ops/ci-cd/CLAUDE.md \
         ops/monitoring/memory/MEMORY.md ops/security/ACCESS.md .claude/agents/ops-environments.md journal; do [ -e "$f" ] || fail "missing $f"; done
assert_contains CLAUDE.md "# acme-corp-devops-sre: the DevOps / Site Reliability Engineer" "title"
assert_contains CLAUDE.md "You are the **DevOps / Site Reliability Engineer** for Acme Corp, working for Sam Lee." "persona"
assert_contains CLAUDE.md "when Sam Lee says so" "owner in the rules"
assert_contains CLAUDE.md "Commits and PRs carry Sam Lee's own git identity only" "no AI author in the rules"
assert_contains .claude/agents/devops-sre.md "no Co-Authored-By" "no AI trailer for folder agents"
grep -q "{{" CLAUDE.md ACCESS.md README.md .claude/agents/*.md && fail "unfilled placeholder"
# work_kinds (story T1 addendum): the four ways a task runs, in the rules (the main agent names the one it picks) and the README
wk1='**Ask in plain words** (a subagent): the main session hands the task to that project'"'"'s agent and reports back. The usual way.'
wk2='**Deep work** (a focus agent): a full session in the project'"'"'s code, in its own tab, reporting to the main session.'
wk4='**A second opinion** (a role run): read-only work on another AI model; it reports, never edits.'
wk3='**`ade dispatch`**: one focus agent per ready ticket; a high-risk ticket waits for your yes.'
for w in "$wk1" "$wk2" "$wk3" "$wk4"; do grep -qF -- "- $w" CLAUDE.md || fail "work_kinds: CLAUDE.md lacks [$w]"; done
awk '/^## The main agent/{p=1;next} /^## /{p=0} p' CLAUDE.md | grep -q 'name the one you pick' || fail "work_kinds: the main agent names its pick"
for w in "$wk1" "$wk2" "$wk3" "$wk4"; do
  grep -qF -- "- $w" README.md || fail "work_kinds: README.md lacks [$w]"; done
# ade_rules_line (story T1): the Tools section names ade, what it is for, and that it runs the same bin/ scripts
al="$(awk '/^## Tools/{p=1;next} /^## /{p=0} p' CLAUDE.md | grep '^- \*\*ade:\*\* ')"
for w in 'hubs, projects, dispatch, proof shots, the web dashboard, the tab view' '`ade help`' 'runs the same `bin/` script'; do
  printf '%s' "$al" | grep -qF -- "$w" || fail "ade_rules_line: the Tools section's ade line lacks [$w]: [$al]"; done
. ./hub.conf; . ./.local/hub.conf; assert_eq "$HUB_REMOTE_HOST" "box.acme.test" "remote host"; assert_eq "$HUB_REMOTE_PORT" "2222" "remote port"
assert_eq "$HUB_REMOTE_USER" "deploy" "remote user"; assert_eq "$HUB_BRIEFING_HOUR:$HUB_BRIEFING_MINUTE" "7:30" "briefing time"
assert_eq "$HUB_SECRETS" "grafana-token" "secret names"; assert_eq "$HUB_AUTO_SYNC" "0" "--auto-sync off"
assert_eq "$HUB_BRAIN_PATHS|$HUB_EMBED_MODEL|$HUB_OLLAMA_URL" "$HOME/notes|mxbai-embed-large|http://localhost:11434" "brain settings"; assert_eq "$HUB_REPOS" "acme/infra" "repos"
assert_contains ops/environments/ACCESS.md "| acme/infra | $CO |" "first folder checks out the repos"
awk '/^## Code/{c=1;next} /^## /{c=0} c' ops/environments/ACCESS.md | grep -q "| acme/infra |" || fail "repo row is inside the Code table"
assert_contains .claude/agents/ops-environments.md "You are the DevOps / Site Reliability Engineer, working only on ops/environments in the acme-corp-devops-sre hub" "folder agent persona"
assert_contains .claude/agents/ops-environments.md "staged for Sam Lee" "folder agent names the hub owner"
assert_contains ops/environments/ACCESS.md "Staged for Sam Lee to run" "folder ACCESS names the hub owner"
for f in CLAUDE.md .claude/agents/devops-sre.md .claude/agents/ops-environments.md; do
  assert_contains "$f" "Ground every answer in a source" "$f tells the agent to ground answers"
  assert_contains "$f" "path:line" "$f names code sources as path:line"; done
out=$(env -u HUB WORK_DRY=1 bin/work ops/environments) || fail "deep work on the first folder"
echo "$out" | grep -q "cd '$CO'" || fail "work opens the repo checkout"
HUB="$D" bin/context | grep -q "^# acme-corp-devops-sre: every folder" || fail "context names the hub"
assert_contains "journal/$(date -u +%Y-%m-%d).md" "Hub initialized from ade-brain" "journal entry"
[ "$(git config core.hooksPath)" = .githooks ] || fail "hooks path"
grep -rqi "orillia" . --exclude-dir=.git --exclude-dir=.claude --exclude-dir=tests && fail "Orillia leaked into a new hub"
# refusals: re-init, unknown persona, bad names, a secret value instead of a name
bin/init --persona devops-sre --client X --owner Y >/dev/null 2>&1; assert_eq "$?" "2" "an initialized hub is never re-initialized"
cd "$HUB"
bin/init --persona nope --client X --owner Y --dest "$(mktemp -d)/n" >/dev/null 2>&1; assert_eq "$?" "2" "unknown persona"
bin/init --persona tech-lead --client X >/dev/null 2>&1; assert_eq "$?" "2" "owner required"
bin/init --persona tech-lead --client X --owner Y --dest "$D" >/dev/null 2>&1; assert_eq "$?" "2" "existing dest refused"
bin/init --persona tech-lead --client X --owner Y --secret 'sk-ABC123=' --dest "$(mktemp -d)/s" >/dev/null 2>&1; assert_eq "$?" "2" "secret value refused"
bin/init --persona tech-lead --client X --owner Y --briefing 25:00 --dest "$(mktemp -d)/b" >/dev/null 2>&1; assert_eq "$?" "2" "bad briefing time"
bin/init --persona tech-lead --client X --owner Y --auto-sync maybe --dest "$(mktemp -d)/a" >/dev/null 2>&1; assert_eq "$?" "2" "bad --auto-sync"
# --ollama-url: written as the brain's Ollama URL; a value that is no http(s) URL is refused (story C2 init_ollama_url)
O="$(mktemp -d)/o"; bin/init --persona tech-lead --client X --owner Y --ollama-url http://127.0.0.1:11999 --dest "$O" >/dev/null || fail "init --ollama-url failed"
assert_eq "$(. "$O/hub.conf"; echo "$HUB_OLLAMA_URL")" "http://127.0.0.1:11999" "init_ollama_url: hub.conf"
for u in "not a url" "ftp://127.0.0.1:11999" "http://" "http://h /x" ""; do
  ou="$(mktemp -d)/ou"; bin/init --persona tech-lead --client X --owner Y --ollama-url "$u" --dest "$ou" >/dev/null 2>&1; assert_eq "$?" "2" "init_ollama_url: bad [$u] refused"
  [ ! -e "$ou" ] || fail "init_ollama_url: a refused [$u] wrote $ou"; done
for u in "http://[::1]:11434" "https://o.example.test/api?x=1"; do   # IPv6 and a query still pass
  bin/init --persona tech-lead --client X --owner Y --ollama-url "$u" --dest "$(mktemp -d)/ok" >/dev/null || fail "init_ollama_url: [$u] refused"; done
bin/init --persona tech-lead --client X --owner Y --folders "projects/Bad" --dest "$(mktemp -d)/f" >/dev/null 2>&1; assert_eq "$?" "2" "bad folder"
# names with sed metacharacters (& and #) and a hub path with & render as written, everywhere
D2="$(mktemp -d)/r&d hub"
bin/init --persona devops-sre --client "AT&T #1" --owner "Sam & Lee" --name att-ops --dest "$D2" >/dev/null || fail "init with & and # in names failed"
assert_contains "$D2/CLAUDE.md" "for AT&T #1, working for Sam & Lee." "persona with & and # in the client and owner"
assert_contains "$D2/.claude/agents/ops-environments.md" "staged for Sam & Lee" "folder agent with & in the owner"
assert_contains "$D2/ops/environments/.claude/settings.local.json" "\"$D2/CLAUDE.md\"" "the folder's exclude with & in the hub path"
assert_contains "$D2/_bmad/config.toml" 'output_folder = "_bmad-output"' "BMAD output folder, relative (no machine path)"
assert_contains "$D2/_bmad/config.toml" 'project_name = "att-ops"' "BMAD project name"
grep -rq "{{" "$D2/CLAUDE.md" "$D2/.claude/agents" "$D2"/ops/*/CLAUDE.md "$D2"/ops/*/ACCESS.md && fail "unfilled placeholder with & in names"
# in place, default folders and name from the client
bin/init --persona staff-software-engineer --client "Beta Inc" --owner "Pat" >/dev/null || fail "init in place failed"
assert_contains hub.conf "HUB_NAME=beta-inc-staff-software-engineer" "derived name"
assert_contains hub.conf "HUB_AUTO_SYNC=1" "auto sync on by default"
assert_contains hub.conf "HUB_ONETIME_URL=https://us.onetimesecret.com" "the one-time link service (story I6)"
for f in projects/app projects/proposals projects/client ops/environments; do [ -f "$f/STATE.md" ] || fail "default folder $f"
  grep -qF "/bin/changes $f\"" "$f/.claude/settings.json" || fail "$f hears hub changes (UserPromptSubmit)"; done

# --- story H3: bin/init asks forgivingly and can be run again ---
# questions go through a pseudo-terminal (tests/pty_run.py: each -i is a typed line, then end of input)
W="$(mktemp -d)"; export HOME="$W/home"; mkdir -p "$HOME"; trap 'rm -rf "$W"' EXIT
pty() { python3 "$REPO/tests/pty_run.py" "$@"; }
make_hub; T1="$HUB"; cd "$T1"
NSTAFF=$(ls personas/*.md | grep -n '/staff-software-engineer.md$' | cut -d: -f1); NP=$(ls personas/*.md | wc -l | tr -d ' ')
resume_of() { printf '%s\n' "$1" | sed -n 's/.*to continue: //p'; }

init_persona_forgives() {
  local out rc form
  # the number, the slug or the title in any case with spaces, -, _ or / anywhere, and a prefix only one persona has
  for form in "$NSTAFF" "staff software engineer" "STAFF-SOFTWARE-ENGINEER" "Staff_Software/Engineer" "staffsoftware" "staff"; do
    out=$(pty -i "$form" -- bin/init --dest "$W/none"); rc=$?
    assert_eq "$rc" "1" "persona '$form' then end of input at the client question"
    resume_of "$out" | grep -q -- "--persona staff-software-engineer" || fail "persona '$form' not taken as staff-software-engineer: $out"
  done
  printf '%s\n' "$out" | grep -qE "^ *$NSTAFF\) staff-software-engineer +Staff Software Engineer" || fail "the persona question numbers the personas: $out"
  # anything else is asked again, with one line saying what is accepted, until an answer fits
  out=$(pty -i "" -i "tech" -i "staff eng" -i "0" -i "$((NP + 1))" -i "devops site" -- bin/init --dest "$W/none"); rc=$?
  assert_eq "$rc" "1" "asked again, then end of input at the client question"
  assert_eq "$(printf '%s\n' "$out" | grep -c "init: .*give its number (1-$NP), slug or title")" "5" "one line saying what is accepted, per refused answer"
  resume_of "$out" | grep -q -- "--persona devops-sre" || fail "a title prefix only one persona has: $out"
  [ -e "$W/none" ] && fail "a run that stopped at a question wrote the copy"
  # the answer the owner's first test gave, through to a hub
  out=$(pty -i "staff software engineer" -i "Acme Corp" -i "Sam Lee" -- bin/init --dest "$W/pf") || fail "init with the persona's title: $out"
  assert_contains "$W/pf/hub.conf" "HUB_PERSONA=staff-software-engineer" "the title becomes the slug"
}

init_persona_flag() {
  local out rc form
  for form in "$NSTAFF" "Staff Software Engineer" "staff_software_engineer" "STAFF/SOFTWARE" "staff"; do
    out=$(bin/init --persona "$form" --client X 2>&1); rc=$?
    assert_eq "$rc" "2" "--persona '$form' without --owner"
    case "$out" in *"missing --owner"*) ;; *) fail "--persona '$form' not accepted: $out";; esac
  done
  bin/init --persona "ML / AI Engineer" --client "Acme Corp" --owner "Sam Lee" --dest "$W/pg" >/dev/null 2>&1 || fail "--persona with the title"
  assert_contains "$W/pg/hub.conf" "HUB_PERSONA=ml-ai-engineer" "--persona title becomes the slug"
  out=$(bin/init --persona "staff engineer" --client X --owner Y --dest "$W/pn" 2>&1); rc=$?
  assert_eq "$rc" "2" "an unknown --persona exits 2"
  case "$out" in *"no persona 'staff engineer'"*"staff-software-engineer"*) ;; *) fail "the closest persona is named: $out";; esac
  out=$(bin/init --persona tech --client X --owner Y --dest "$W/pn" 2>&1); rc=$?
  assert_eq "$rc" "2" "a prefix two personas share exits 2"
  case "$out" in *tech-lead*technical-product-manager*) ;; *) fail "both personas with the prefix are named: $out";; esac
  bin/init --persona zzz --client X --owner Y --dest "$W/pn" >/dev/null 2>&1; assert_eq "$?" "2" "nothing close exits 2"
  [ -e "$W/pn" ] && fail "an unknown --persona wrote the copy"
}

init_asks_again() {
  local out
  out=$(pty -i "" -i $'Acme\e[D' -i "  Acme Corp  " -i "   " -i $'Sam\tLee' -i "Sam Lee" -- bin/init --persona tech-lead --dest "$W/aa") ||
    fail "init after answers asked again: $out"
  . "$W/aa/hub.conf"; assert_eq "$HUB_CLIENT|$HUB_OWNER" "Acme Corp|Sam Lee" "client and owner as answered (trimmed)"
  assert_eq "$(printf '%s\n' "$out" | grep -c "init: the client: not empty, no control characters")" "2" "the client question asked again twice"
  assert_eq "$(printf '%s\n' "$out" | grep -c "init: the owner: not empty, no control characters")" "2" "the owner question asked again twice"
  printf '%s\n' "$out" | grep -q "Client (the organisation this hub works for" || fail "the client question says what it is for: $out"
  printf '%s\n' "$out" | grep -q "Owner (the person this hub works for" || fail "the owner question says what it is for: $out"
}

init_resume_line() {
  local out rc line cmd
  # end of input at the first question: the command with nothing filled in, still runnable
  out=$(pty -- bin/init --dest "$W/r0"); rc=$?
  assert_eq "$rc" "1" "end of input at the persona question"
  assert_eq "$(printf '%s\n' "$out" | grep -c "^init: stopped")" "1" "one line"
  resume_of "$out" | grep -qE "bin/init --dest [^ ]+/r0$" || fail "the resume line repeats the options: $out"
  # end of input later: the answers given are in it, quoted for a shell, and running it asks only what is left
  out=$(pty -i "staff software engineer" -- bin/init --client "O'Brien & Co \$1 \`x\`" --briefing 07:30 --dest "$W/r hub"); rc=$?
  assert_eq "$rc" "1" "end of input at the owner question"
  line=$(printf '%s\n' "$out" | grep "^init: stopped"); cmd=$(resume_of "$line")
  [ -n "$cmd" ] || fail "no command to continue: $out"
  case "$cmd" in *"<"*|*"{{"*|*"..."*) fail "a placeholder in the resume line: $cmd";; esac
  case "$cmd" in *"--persona staff-software-engineer"*) ;; *) fail "the persona answer is in the resume line: $cmd";; esac
  [ -e "$W/r hub" ] && fail "a run that stopped at a question wrote the copy"
  out=$(cd / && pty -i "Sam Lee" -- bash -c "$cmd") || fail "the resume line did not finish the hub: $out"
  printf '%s\n' "$out" | grep -q "Persona (" && fail "the resume line asked the persona again"
  . "$W/r hub/hub.conf"
  assert_eq "$HUB_PERSONA|$HUB_CLIENT|$HUB_OWNER|$HUB_BRIEFING_HOUR" "staff-software-engineer|O'Brien & Co \$1 \`x\`|Sam Lee|7" "values through the resume line"
}

init_runs_again() {
  local out rc C D
  # a copy in place where bin/init stopped part way (a folder it could not make) and the person fixed the cause
  make_hub; C="$HUB"; mkdir -p "$C/ops"; echo blocker > "$C/ops/ci-cd"
  out=$(cd "$C" && bin/init --persona devops-sre --client "Acme Corp" --owner "Sam Lee" --repo acme/infra=/x --folders "ops/environments ops/ci-cd" 2>&1); rc=$?
  assert_eq "$rc" "1" "the first run stops at the folder it cannot make"
  [ -f "$C/.init-pending" ] || fail "a stopped run is recognisable"
  case "$out" in *"not finished"*) ;; *) fail "the stop says the copy is not finished: $out";; esac
  rm "$C/ops/ci-cd"; echo "a person's note" >> "$C/ops/environments/STATE.md"
  # run again with no options and no terminal: the earlier run's values, nothing asked, nothing damaged
  out=$(cd "$C" && bin/init 2>&1 </dev/null) || fail "running again did not finish the copy: $out"
  [ -e "$C/.init-pending" ] && fail "the finished hub still says pending"
  . "$C/hub.conf"; assert_eq "$HUB_PERSONA|$HUB_CLIENT|$HUB_OWNER|$HUB_REPOS" "devops-sre|Acme Corp|Sam Lee|acme/infra" "the earlier run's values"
  [ -f "$C/ops/ci-cd/STATE.md" ] || fail "the folder left over is made"
  assert_contains "$C/ops/environments/STATE.md" "a person's note" "an edited file is kept"
  assert_eq "$(grep -c '| acme/infra |' "$C/ops/environments/ACCESS.md")" "1" "the repo row once"
  assert_eq "$(cat "$C"/journal/*.md | grep -c 'Hub initialized from ade-brain')" "1" "one journal entry"
  assert_eq "$(grep -c 'You are the \*\*DevOps' "$C/CLAUDE.md")" "1" "the persona rendered once"
  grep -q "{{" "$C/CLAUDE.md" "$C/ACCESS.md" "$C/README.md" "$C"/.claude/agents/*.md && fail "an unfilled placeholder after running again"
  (cd "$C" && bin/init >/dev/null 2>&1); assert_eq "$?" "2" "a finished hub is still never re-initialized"
  # a --dest copy that stopped after a question was answered: the same command again asks nothing given before
  make_hub; T2="$HUB"; D="$W/rd"; echo '{' > "$T2/.claude/settings.json"
  out=$(pty -i "Sam Lee" -- "$T2/bin/init" --persona tech-lead --client "Acme Corp" --dest "$D"); rc=$?
  assert_eq "$rc" "1" "the first --dest run stops at a broken settings file"
  cp "$REPO/.claude/settings.json" "$D/.claude/settings.json"; cp "$REPO/.claude/settings.json" "$T2/.claude/settings.json"
  rm "$D/bin/doctor"   # as if the copy itself had stopped part way
  out=$("$T2/bin/init" --persona tech-lead --client "Other" --dest "$D" 2>&1 </dev/null); rc=$?
  assert_eq "$rc" "2" "different values for a copy started with others are refused"
  case "$out" in *"Acme Corp"*) ;; *) fail "the refusal names the earlier run's values: $out";; esac
  out=$(pty -- "$T2/bin/init" --persona tech-lead --client "Acme Corp" --dest "$D") || fail "the same command did not finish the copy: $out"
  printf '%s\n' "$out" | grep -q "Owner (" && fail "the owner answered before was asked again"
  . "$D/hub.conf"; assert_eq "$HUB_PERSONA|$HUB_CLIENT|$HUB_OWNER" "tech-lead|Acme Corp|Sam Lee" "the answer recorded by the first run"
  [ -x "$D/bin/doctor" ] || fail "the copy is completed"
  [ -e "$D/.init-pending" ] && fail "the finished --dest hub still says pending"
}

init_no_terminal() {
  local out rc
  out=$(bin/init --client X --dest "$W/nt" 2>&1 </dev/null); rc=$?
  assert_eq "$rc" "2" "missing values without a terminal"
  assert_eq "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "1" "one line: $out"
  case "$out" in *--persona*--owner*) ;; *) fail "the line names what is missing: $out";; esac
  case "$out" in *--client*) fail "the line names only what is missing: $out";; esac
  out=$(bin/init 2>&1 </dev/null); rc=$?
  assert_eq "$rc" "2" "nothing given, no terminal"
  case "$out" in *--persona*--client*--owner*) ;; *) fail "all three named: $out";; esac
  [ -e "$W/nt" ] && fail "a refused run wrote the copy"
}


# a template copy in a folder of its own, with no git of its own (the same files make_hub copies)
copy_template() { mkdir -p "$1"; (cd "$REPO" && tar cf - --exclude ./repos --exclude ./.git --exclude ./hub.conf --exclude ./.local \
  --exclude ./.superpowers --exclude ./.claude/worktrees --exclude ./_bmad/render --exclude ./_bmad-output .) | (cd "$1" && tar xf -)
  rm -f "$1"/journal/[0-9]*.md; }

init_existing_repo() {
  local R="$W/repo" WT="$W/wt" P="$W/plain" out refs cfg
  # in a git worktree: no git init, the branch keeps its name, the main repo's refs and config are untouched
  mkdir -p "$R" && git -C "$R" init -q && git -C "$R" config user.name t && git -C "$R" config user.email t@t
  echo x > "$R/f" && git -C "$R" add f && git -C "$R" commit -qm one && git -C "$R" worktree add -q "$WT" -b feature
  copy_template "$WT"
  refs=$(git -C "$R" for-each-ref --format='%(refname) %(objectname)'); cfg=$(cat "$R/.git/config")
  out=$(cd "$WT" && bin/init --persona tech-lead --client "Acme Corp" --owner "Sam Lee" 2>&1) || fail "init in a worktree: $out"
  assert_eq "$(git -C "$WT" branch --show-current)" "feature" "the worktree's branch keeps its name"
  assert_eq "$(git -C "$R" for-each-ref --format='%(refname) %(objectname)')" "$refs" "the main repo's refs are unchanged"
  assert_eq "$(cat "$R/.git/config")" "$cfg" "the main repo's .git/config is unchanged"
  [ -f "$WT/.git" ] || fail "the worktree's .git file was replaced"
  assert_eq "$(printf '%s\n' "$out" | grep -c "hooks path")" "1" "one line says what is done about the hooks path"
  # in a plain folder that is not a repo: today's behaviour (a repo on main, the hub's hooks)
  copy_template "$P"
  out=$(cd "$P" && bin/init --persona tech-lead --client "Acme Corp" --owner "Sam Lee" 2>&1) || fail "init in a plain folder: $out"
  [ -d "$P/.git" ] || fail "a plain folder becomes a repo"
  assert_eq "$(git -C "$P" symbolic-ref --short HEAD)" "main" "on main"
  assert_eq "$(git -C "$P" config core.hooksPath)" ".githooks" "the hub's hooks"
}

init_client_needs_a_letter() {
  local out rc
  # asked: a client with no letter or digit for the folder name is asked again, with one line
  out=$(pty -i "株式会社" -i "Acme Corp" -i "Sam Lee" -- bin/init --persona tech-lead --dest "$W/cn") || fail "asked again after a client with no letter: $out"
  assert_eq "$(printf '%s\n' "$out" | grep -c "needs at least one letter or digit")" "1" "one line on the refused client"
  printf '%s\n' "$out" | grep "needs at least one letter or digit" | grep -q -- "--name" || fail "the line names --name: $out"
  . "$W/cn/hub.conf"; assert_eq "$HUB_CLIENT" "Acme Corp" "the client answered again"
  # given as a flag: exit 2 before anything is written, naming --name; with --name it is fine
  out=$(bin/init --persona tech-lead --client "株式会社" --owner "Sam Lee" --dest "$W/cf" 2>&1 </dev/null); rc=$?
  assert_eq "$rc" "2" "a --client with no letter or digit"
  case "$out" in *"--client '株式会社' has no letter or digit"*--name*) ;; *) fail "the refusal names the client and --name: $out";; esac
  [ -e "$W/cf" ] && fail "a refused --client wrote the copy"
  bin/init --persona tech-lead --client "株式会社" --owner "Sam Lee" --name kk-lead --dest "$W/ck" >/dev/null 2>&1 </dev/null || fail "--name gives the folder name"
  . "$W/ck/hub.conf"; assert_eq "$HUB_CLIENT|$HUB_NAME" "株式会社|kk-lead" "client kept, name from --name"
}

# story P1 AC8: --repo rows come from bin/lib.sh's repo_row, so a checkout whose default branch is master writes master
init_repo_branch() {
  local W M; W="$(mktemp -d)"; M="$W/legacy"
  git init -q -b master "$M" && echo x > "$M/README" && git -C "$M" add -A && git -C "$M" -c user.name=t -c user.email=t@t commit -qm init
  bin/init --persona tech-lead --client "Acme Corp" --owner "Sam Lee" --dest "$W/hub" --repo acme/legacy="$M" >/dev/null 2>&1 </dev/null ||
    fail "init --repo on a master checkout"
  grep -rqF "| acme/legacy | $M | master | Sam Lee | (fill in) |" "$W/hub/projects" "$W/hub/ops" 2>/dev/null ||
    fail "init writes the checkout's master branch, not main: $(grep -rh 'acme/legacy' "$W/hub/projects" "$W/hub/ops" 2>/dev/null)"
}

init_persona_forgives; init_persona_flag; init_asks_again; init_resume_line; init_runs_again; init_no_terminal; init_existing_repo; init_client_needs_a_letter; init_repo_branch
echo ok
