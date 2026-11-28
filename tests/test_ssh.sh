#!/bin/bash
# story X1: agents reach servers through ssh-agent, never holding a key or a password (bin/ssh, bin/askpass,
# bin/ssh-guard; .ade/context/access.md). A fake ssh and ssh-add on PATH record what they were given; nothing connects,
# and the real ~/.ssh, ssh-agent and Keychain are never touched (the file store under a throwaway HOME).
export TMPDIR="$(mktemp -d)"   # everything this test (and the commands it runs) leaves is under here, so it can be searched
. "$(dirname "$0")/helpers.sh"
make_hub; cd "$HUB"
for v in $(bash -c ". bin/lib.sh; agent_session_vars"); do unset "$v"; done   # the developer's own terminal, by default
export HOME="$TMPDIR/home"; mkdir -p "$HOME"; chmod 700 "$HOME"
unset SSH_AUTH_SOCK SSH_ASKPASS SSH_ASKPASS_REQUIRE DISPLAY
echo 'HUB_SECRET_STORE=file' > hub.conf

F="$TMPDIR/fake"; REC="$TMPDIR/rec"; mkdir -p "$F" "$REC"; export FAKE_REC="$REC"
cat > "$F/ssh" <<'SSH'
#!/bin/bash
# a fake ssh: records its arguments and environment, answers -G, asks $SSH_ASKPASS as ssh does, never connects
R="$FAKE_REC"; ARGV=("$@")
u="" h="" ask=0 G=0 seen=" " opts=""
# OpenSSH keeps the FIRST value it gets for an option: so does this fake (the effective ones go to opts.N)
while [ $# -gt 0 ]; do case "$1" in
  -G) G=1; shift ;; -l) u="$2"; shift 2 ;;
  -o) k="$(printf '%s' "${2%%=*}" | tr 'A-Z' 'a-z')"
      case "$seen" in *" $k "*) ;; *) seen="$seen$k "; opts="$opts$k=${2#*=}"$'\n'
        [ "$k=${2#*=}" = stricthostkeychecking=ask ] && ask=1 ;; esac; shift 2 ;;
  -p|-J) shift 2 ;; --) h="$2"; shift 2; break ;; *) shift ;; esac; done
u="${u:-tester}"
if [ "$G" = 1 ]; then printf 'user %s\nhostname %s\nport 22\n' "$u" "$h"; exit 0; fi   # -G connects nowhere: not a call
n=$(( $(cat "$R/n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$R/n"
printf '%s\n' "${ARGV[@]}" > "$R/argv.$n"; env > "$R/env.$n"; printf '%s' "$opts" > "$R/opts.$n"
if [ "$ask" = 1 ]; then
  echo "ED25519 key fingerprint is SHA256:fakefingerprint." >&2
  printf 'Are you sure you want to continue connecting (yes/no/[fingerprint])? ' >&2; read -r a
  if [ "$a" = yes ]; then echo "Warning: Permanently added '$h' (ED25519) to the list of known hosts." >&2; : > "$R/trusted"; exit 0; fi
  echo "Host key verification failed." >&2; exit 255
fi
[ "${FAKE_SSH_CHANGED:-}" = 1 ] && { echo "@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @" >&2; echo "Host key verification failed." >&2; exit 255; }
[ "${FAKE_SSH_UNKNOWN:-}" = 1 ] && { echo "Host key verification failed." >&2; exit 255; }
if [ -n "${SSH_ASKPASS:-}" ]; then
  sha() { python3 -c 'import hashlib, sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'; }
  IFS='|' read -ra others <<< "${FAKE_OTHER_PROMPTS:-}"
  for p in ${others[@]+"${others[@]}"}; do o="$("$SSH_ASKPASS" "$p" 2>/dev/null)"; echo "other rc=$? len=${#o}" >> "$R/askpass"; done
  tp="$u@$h's password: "; tp="${FAKE_TARGET_PROMPT:-$tp}"
  o="$("$SSH_ASKPASS" "$tp" 2>/dev/null)"; rc=$?
  if [ "$rc" = 0 ] && [ "$(printf '%s' "$o" | sha)" = "$FAKE_WANT_SHA" ]; then echo "target match" >> "$R/askpass"
  else echo "target rc=$rc nomatch" >> "$R/askpass"; echo "Permission denied (password)." >&2; exit 255; fi
fi
echo "ran on $h: $*"
SSH
cat > "$F/ssh-add" <<'ADD'
#!/bin/bash
echo "ssh-add $*" >> "$FAKE_REC/ssh-add"
[ "${FAKE_AGENT_KEYS:-1}" = none ] && { echo "Could not open a connection to your authentication agent."; exit 2; }
[ "${FAKE_AGENT_KEYS:-1}" = 1 ] && { echo "256 SHA256:fakefingerprint key (ED25519)"; exit 0; }
echo "The agent has no identities."; exit 1
ADD
chmod +x "$F/ssh" "$F/ssh-add"; export PATH="$F:$PATH"

calls() { cat "$REC/n" 2>/dev/null || echo 0; }
last() { cat "$REC/$1.$(calls)"; }   # last argv|env
conf() { local n="$1"; shift; mkdir -p ops/access; rm -f "ops/access/$n.conf"; printf '%s\n' "$@" > "ops/access/$n.conf"; }
# run <cmd...>: OUT, ERR (files), RC
run() { OUT="$TMPDIR/out.$RANDOM"; ERR="$TMPDIR/err.$RANDOM"; "$@" > "$OUT" 2> "$ERR"; RC=$?; }
refused() {   # refused <what> <secret-ish text or ""> <cmd...>: exit 2, ssh never ran, the text in no message
  local what="$1" txt="$2" c; shift 2; c="$(calls)"; run "$@"
  assert_eq "$RC" 2 "ssh_registry: $what is refused ($(cat "$ERR"))"; assert_eq "$(calls)" "$c" "ssh_registry: ssh ran for $what"
  [ -z "$txt" ] || ! grep -qF -- "$txt" "$OUT" "$ERR" || fail "ssh_registry: the refusal of $what repeats the value"; }
nodup() {   # no ssh option given twice in the last run (OpenSSH would keep the first and drop the other)
  local d; d="$(sed -n 's/^\([A-Za-z]*\)=.*/\1/p' "$REC/argv.$(calls)" | tr 'A-Z' 'a-z' | sort | uniq -d)"; assert_eq "$d" "" "$1: an ssh option given twice"; }
hookin() {   # hookin <cwd> <command> [tool]: a PreToolUse input
  python3 -c 'import json, sys; print(json.dumps({"session_id": "s1", "hook_event_name": "PreToolUse", "tool_name": sys.argv[3], "tool_input": {"command": sys.argv[2]}, "cwd": sys.argv[1]}))' "$1" "$2" "${3:-Bash}"; }
hook() { hookin "$@" | CLAUDE_PROJECT_DIR="$HUB" bin/ssh-guard; }   # bin/ssh-guard's stdout for it
asks() { local o; o="$(hook "${3:-$HUB}" "$1")"; python3 -c 'import json, sys; d = json.loads(sys.argv[1])["hookSpecificOutput"]; assert d["hookEventName"] == "PreToolUse" and d["permissionDecision"] == "ask" and d["permissionDecisionReason"]' "$o" 2>/dev/null || fail "ssh_asks: no ask for [$1] (got [$o])"; }
quiet() { local o; o="$(hook "${3:-$HUB}" "$1" "${2:-Bash}")"; assert_eq "$o" "" "ssh_asks: [$1] asks"; }

ssh_registry() {   # AC1
  conf web HOST=web.example.test USER=deploy PORT=2222 AUTH=key PROD=0
  run bin/ssh web uptime; assert_eq "$RC" 0 "ssh_registry: a valid entry connects ($(cat "$ERR"))"
  assert_contains "$OUT" "ran on web.example.test: uptime" "ssh_registry: the command reaches the host"
  grep -qx -- -l "$REC/argv.$(calls)" && grep -qx deploy "$REC/argv.$(calls)" && grep -qx 2222 "$REC/argv.$(calls)" || fail "ssh_registry: USER and PORT not passed"
  # options after the host are never options: `--` comes first (OpenSSH re-reads options after the destination otherwise)
  run bin/ssh web -oProxyCommand=touch\ "$TMPDIR/pwned"; assert_eq "$(sed -n '/^--$/{n;p;n;p;}' "$REC/argv.$(calls)" | tr '\n' ' ')" "web.example.test -oProxyCommand=touch $TMPDIR/pwned " "ssh_registry: -- before the host"
  local aws; aws="AKIA""QX7ZRW3KPL5MNB2D"   # an AWS-shaped id (split so no scanner takes the test for a leak)
  local bad; for bad in 'PASSWORD=hunter2-x1' 'IDENTITY=~/.ssh/id_ed25519' 'KEY=hunter2-x1' 'HOST=-oProxyCommand=sh' 'HOST=web example' \
      'HOST=web.example.test;id' 'HOST=$(touch pwned)' 'HOST="web.example.test"' ' HOST=web.example.test' 'USER=-oProxyCommand=sh' \
      'PORT=22 -oX=y' 'PORT=70000' 'PORT=0' 'JUMP=-oProxyCommand=sh' 'JUMP=a@b@c' 'AUTH=agent' 'PROD=yes' 'KIND=db' 'KIND=other' \
      '-----BEGIN OPENSSH PRIVATE KEY-----' "HOST=$aws" 'HOST=web.example.test'$'\r' 'just words'; do
    case "$bad" in HOST=*|" HOST="*) conf bad AUTH=key PROD=0 "$bad" ;; *) conf bad HOST=web.example.test AUTH=key PROD=0 "$bad" ;; esac
    refused "the line [$bad]" "$(printf '%s' "${bad#*=}" | tr -d '\r')" bin/ssh bad uptime
  done
  [ ! -e pwned ] && [ ! -e "$TMPDIR/pwned" ] || fail "ssh_registry: the registry was run as shell"
  # the key check holds with the paste guard switched off, and refuses when it cannot run (no python3)
  printf 'HUB_PASTE_GUARD=off\n' >> hub.conf; conf bad HOST="$aws" AUTH=key PROD=0; refused "a key shape, paste guard off" "$aws" bin/ssh bad uptime
  echo 'HUB_SECRET_STORE=file' > hub.conf
  local np="$TMPDIR/nopy" x; mkdir -p "$np"; for x in /bin/* /usr/bin/*; do case "${x##*/}" in python*) ;; *) ln -sf "$x" "$np/" ;; esac; done
  conf web HOST=web.example.test AUTH=key PROD=0; PATH="$F:$np" refused "a registry file it cannot check (no python3)" "" bin/ssh web uptime
  conf bad HOST=a.example.test HOST=b.example.test AUTH=key; refused "a key given twice" "" bin/ssh bad uptime
  conf bad HOST=a.example.test PROD=0; refused "no AUTH" "" bin/ssh bad uptime
  conf bad AUTH=key PROD=0; refused "no HOST" "" bin/ssh bad uptime
  printf 'HOST=a.example.test\nAUTH=key\n# a comment\n\nPROD=0' > ops/access/ok2.conf   # comments, blank lines, no final newline
  run bin/ssh ok2 true; assert_eq "$RC" 0 "ssh_registry: comments and a missing final newline ($(cat "$ERR"))"
  ln -sf web.conf ops/access/link.conf; refused "a linked file" "" bin/ssh link uptime
  local n; for n in Web web_1 -oProxyCommand=sh ../web a/b "" "$(printf 'a%.0s' $(seq 33))" 'web$x' ' web'; do refused "the name [$n]" "" bin/ssh "$n" uptime; done
  refused "a name with no file" "" bin/ssh nowhere uptime
  # the registry is a folder of ops/ in name only: never listed as an agent folder, never made one
  bash -c '. bin/lib.sh; folders' | grep -qx ops/access && fail "ssh_registry: folders() lists ops/access"
  run bin/new ops/access; assert_eq "$RC" 2 "ssh_registry: bin/new ops/access is refused"
  run bin/init --persona tech-lead --client X --owner Y --folders "ops/access" --dest "$TMPDIR/initdest/f"
  assert_eq "$RC" 2 "ssh_registry: bin/init --folders ops/access is refused ($(cat "$ERR"))"
  [ -f .ade/context/access.md ] || fail "ssh_registry: no .ade/context/access.md"
  local w; for w in "ops/access/<name>.conf" HOST USER PORT JUMP AUTH PROD KIND "^[a-z0-9][a-z0-9-]{0,31}$"; do assert_contains .ade/context/access.md "$w" "ssh_registry: access.md"; done
}

ssh_agent_only() {   # AC2
  conf web HOST=web.example.test AUTH=key PROD=0
  FAKE_AGENT_KEYS=1 run bin/ssh web uptime; assert_eq "$RC" 0 "ssh_agent_only: key host ($(cat "$ERR"))"
  local a; a="$(last argv)"
  for w in batchmode=yes stricthostkeychecking=yes forwardagent=no; do grep -qx "$w" "$REC/opts.$(calls)" || fail "ssh_agent_only: ssh's effective options lack $w: $(cat "$REC/opts.$(calls)")"; done
  nodup ssh_agent_only
  printf '%s\n' "$a" | grep -qx -- -i && fail "ssh_agent_only: -i given"
  printf '%s\n' "$a" | grep -qi IdentitiesOnly && fail "ssh_agent_only: IdentitiesOnly given"
  grep -q '^SSH_ASKPASS' "$REC/env.$(calls)" && fail "ssh_agent_only: a key host gets an askpass"
  local c; c="$(calls)"; FAKE_AGENT_KEYS=0 run bin/ssh web uptime; assert_eq "$RC" 3 "ssh_agent_only: no key in the agent"
  assert_contains "$ERR" "load your key once, in your own terminal: ssh-add --apple-use-keychain <key>" "ssh_agent_only: the macOS line"
  assert_eq "$(calls)" "$c" "ssh_agent_only: ssh ran with no key in the agent"
  AGENT_PLATFORM=linux FAKE_AGENT_KEYS=0 run bin/ssh web uptime; assert_eq "$RC" 3 "ssh_agent_only: Linux, no key"
  assert_contains "$ERR" "load your key once, in your own terminal: ssh-add <key>" "ssh_agent_only: the Linux line"
  grep -q apple "$ERR" && fail "ssh_agent_only: the macOS flag on Linux"
  FAKE_AGENT_KEYS=none run bin/ssh web uptime; assert_eq "$RC" 3 "ssh_agent_only: no agent reachable"
  assert_contains "$ERR" "no ssh-agent is reachable" "ssh_agent_only: says the agent is missing"; assert_eq "$(calls)" "$c" "ssh_agent_only: ssh ran with no agent"
  run bin/ssh web < /dev/null; assert_eq "$RC" 2 "ssh_agent_only: no command and no terminal"; assert_eq "$(calls)" "$c" "ssh_agent_only: ssh ran with no command"
}

ssh_password_store() {   # AC3
  local PW; PW="Tr0ub4dor-x1-$$-${RANDOM}zz"
  printf '%s\n' "$PW" | bin/secret --set ssh.db1 2>/dev/null || fail "ssh_password_store: could not store"
  export FAKE_WANT_SHA; FAKE_WANT_SHA="$(printf '%s' "$PW" | python3 -c 'import hashlib, sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')"
  conf db1 HOST=db1.example.test USER=admin JUMP=hop@jump.example.test AUTH=password PROD=0
  rm -f "$REC/askpass"; local c0; c0="$(calls)"
  FAKE_OTHER_PROMPTS="hop@jump.example.test's password: |Are you sure you want to continue connecting (yes/no)? |Enter passphrase for key '/x/id': " \
    run bin/ssh db1 uptime
  assert_eq "$RC" 0 "ssh_password_store: password host ($(cat "$ERR"))"
  assert_contains "$REC/askpass" "target match" "ssh_password_store: ssh got the password from bin/askpass"
  assert_eq "$(grep -c '^other rc=1 len=0$' "$REC/askpass")" 3 "ssh_password_store: askpass answered a jump host, a host-key question or a passphrase: $(cat "$REC/askpass")"
  local e="$REC/env.$(calls)"
  grep -qx "SSH_ASKPASS=$HUB/bin/askpass" "$e" && grep -qx "SSH_ASKPASS_REQUIRE=force" "$e" || fail "ssh_password_store: SSH_ASKPASS not set"
  grep -qx batchmode=no "$REC/opts.$(calls)" || fail "ssh_password_store: BatchMode is not no (askpass would not run): $(cat "$REC/opts.$(calls)")"
  nodup ssh_password_store
  # nowhere else: no argument, no environment, nothing printed, no file the run left (only the store's own file)
  local hits; hits="$(grep -rlF -- "$PW" "$TMPDIR" 2>/dev/null | grep -v "^$HOME/.config/ade/secrets/")"
  assert_eq "$hits" "" "ssh_password_store: the password is in a file"
  [ "$(calls)" -gt "$c0" ] || fail "ssh_password_store: ssh did not run"
  # keyboard-interactive: its own host's prompt is answered, the jump host's and one the environment names are not
  rm -f "$REC/askpass"
  ADE_SSH_ASKPASS_FOR=evil@other.example.test FAKE_TARGET_PROMPT="(admin@db1.example.test) Password: " \
    FAKE_OTHER_PROMPTS="(hop@jump.example.test) Password: |evil@other.example.test's password: |(evil@other.example.test) Password: " run bin/ssh db1 uptime
  assert_eq "$RC" 0 "ssh_password_store: keyboard-interactive ($(cat "$ERR"))"; assert_contains "$REC/askpass" "target match" "ssh_password_store: kbd prompt"
  assert_eq "$(grep -c '^other rc=1 len=0$' "$REC/askpass")" 3 "ssh_password_store: askpass answered another host: $(cat "$REC/askpass")"
  # bin/askpass answers ssh alone
  local out rc; out="$(bin/askpass "admin@db1.example.test's password: " 2>/dev/null)"; rc=$?
  assert_eq "$rc:$out" "1:" "ssh_askpass: bin/askpass with no ssh variables"
  out="$(SSH_ASKPASS="$HUB/bin/askpass" SSH_ASKPASS_REQUIRE=force ADE_SSH_ASKPASS_NAME=db1 \
    bin/askpass "admin@db1.example.test's password: " 2>/dev/null)"; rc=$?
  assert_eq "$rc:$out" "1:" "ssh_askpass: bin/askpass not started by ssh"
  # an agent session never reads it through bin/secret; the developer can
  out="$(CLAUDECODE=1 bin/secret ssh.db1 2>/dev/null)"; rc=$?; assert_eq "$rc:$out" "1:" "ssh_password_store: bin/secret ssh.* in an agent session"
  [ "$(bin/secret ssh.db1)" = "$PW" ] || fail "ssh_password_store: the developer cannot read it back"
}

ssh_missing_secret() {   # AC4
  conf db2 HOST=db2.example.test AUTH=password PROD=0
  local c; c="$(calls)"; run bin/ssh db2 uptime
  assert_eq "$RC" 3 "ssh_missing_secret: exit"; assert_eq "$(calls)" "$c" "ssh_missing_secret: ssh ran"
  assert_contains "$ERR" "in their own terminal, bin/secret --set ssh.db2 (a hidden prompt)" "ssh_missing_secret: the command"
  assert_contains "$ERR" "never ask for it in chat" "ssh_missing_secret: not in chat"
}

ssh_trust() {   # AC5
  conf web HOST=web.example.test AUTH=key PROD=0
  FAKE_SSH_UNKNOWN=1 run bin/ssh web uptime; assert_eq "$RC" 3 "ssh_trust: an unknown host key stops the run"
  assert_contains "$ERR" "bin/ssh --trust web" "ssh_trust: names --trust"
  FAKE_SSH_CHANGED=1 run bin/ssh web uptime; assert_eq "$RC" 3 "ssh_trust: a changed host key stops the run"
  assert_contains "$ERR" "CHANGED" "ssh_trust: says the key changed"; assert_contains "$ERR" "ssh-keygen -R web.example.test" "ssh_trust: the changed-key steps"
  local c v out rc; c="$(calls)"
  for v in $(bash -c ". bin/lib.sh; agent_session_vars"); do
    out="$(env "$v=1" python3 "$REPO/tests/pty_run.py" -i yes -- bin/ssh --trust web)"; rc=$?
    assert_eq "$rc" 2 "ssh_trust: --trust from an agent session ($v), even at a terminal"
    printf '%s' "$out" | grep -q "agent session" || fail "ssh_trust: says why ($v): $out"; done
  run bin/ssh --trust web; assert_eq "$RC" 2 "ssh_trust: --trust with no terminal"; assert_contains "$ERR" "terminal" "ssh_trust: says why"
  assert_eq "$(calls)" "$c" "ssh_trust: ssh ran for a refused --trust"; [ ! -e "$REC/trusted" ] || fail "ssh_trust: trusted without the developer"
  out="$(python3 "$REPO/tests/pty_run.py" -i no -- bin/ssh --trust web)"; rc=$?
  assert_eq "$rc" 3 "ssh_trust: the developer says no ($out)"; [ ! -e "$REC/trusted" ] || fail "ssh_trust: saved on no"
  out="$(python3 "$REPO/tests/pty_run.py" -i yes -- bin/ssh --trust web)"; rc=$?
  assert_eq "$rc" 0 "ssh_trust: the developer types yes ($out)"; [ -e "$REC/trusted" ] || fail "ssh_trust: not saved on yes"
  printf '%s' "$out" | grep -q "SHA256:fakefingerprint" || fail "ssh_trust: the fingerprint is not shown: $out"
  local a; a="$(last argv)"; grep -qx stricthostkeychecking=ask "$REC/opts.$(calls)" || fail "ssh_trust: ssh's effective StrictHostKeyChecking is not ask: $(cat "$REC/opts.$(calls)")"
  nodup ssh_trust
  printf '%s\n' "$a" | grep -qx BatchMode=yes && fail "ssh_trust: BatchMode=yes cannot ask"
  grep -q '^SSH_ASKPASS' "$REC/env.$(calls)" && fail "ssh_trust: askpass during --trust (it would answer the host-key question)"
  return 0
}

ssh_asks() {   # AC6
  conf web HOST=web.example.test AUTH=key PROD=0
  conf prod-db HOST=db.example.test AUTH=key PROD=1
  conf noprod HOST=np.example.test AUTH=key
  git add ops/access && git commit -qm "the registry" -- ops/access || fail "ssh_asks: could not commit the registry"
  mkdir -p ops/infra
  local c; for c in 'ssh web.example.test' '"ssh" host' "s'sh' host" '\ssh host' 'env ssh host' 'command ssh host' '/usr/bin/ssh host' \
      'bash -c "ssh host uptime"' 'echo $(ssh host)' 'echo `ssh host`' 'x=1; ssh host' 'true && ssh -p 22 host' 'scp a host:b' 'sftp host' \
      'rsync -e ssh a host:b' 'rsync -av a host:/b' 'sshpass -f pw ssh host' 'git -c core.sshCommand="ssh -i k" fetch' \
      'GIT_SSH_COMMAND="ssh -i k" git fetch' 'git -c core.sshcommand=x fetch' 'bin/ssh prod-db uptime' 'bin/ssh noprod uptime' \
      'bin/ssh nowhere uptime' 'bin/ssh --trust web' 'bin/ssh web --trust' 'env -u CLAUDECODE bin/ssh --trust web' \
      "$HUB/bin/ssh prod-db uptime" 'bin/ssh $N uptime' 'cd /tmp/other-hub && bin/ssh web uptime' 'sed -i s/1/0/ ops/access/prod-db.conf' \
      'bin/askpass x' 'bin/ssh web -oProxyCommand=sh' 'ssh -o ProxyCommand="sh -c x" host' 'xargs ssh < hosts' 'SSH host' \
      'bin/ssh web$(echo x) uptime' 'bin/ssh `echo web` uptime' '"cd" /tmp && bin/ssh web uptime' 'bin/secret ssh.web' \
      'env -u CLAUDECODE bin/secret ssh.web' 'bash -c ". bin/lib.sh; secret_get ssh.web"' 'ssh-keyscan host' 'ssh-keygen -R host' \
      'cat ~/.ssh/known_hosts' 'cat ~/.config/ade/secrets/ssh.web' 'security find-generic-password -s x -w' 'FOO=1 bin/ssh web uptime' \
      'bin/ssh >web prod-db uptime' 'bin/ssh <web prod-db uptime' 'bin/ssh 2>web prod-db uptime' 'bin/ssh >"x web" prod-db uptime' \
      "bin/ssh 'web prod-db' uptime" \
      'printf prod-db | xargs -I web bin/ssh web uptime' 'xargs -a hosts bin/ssh web uptime' 'xargs -J web bin/ssh web uptime' \
      'find . -exec bin/ssh web uptime \;' 'timeout 5 bin/ssh web uptime' 'nohup bin/ssh web uptime' 'time bin/ssh web uptime' \
      'watch bin/ssh web uptime' 'parallel bin/ssh web ::: a' 'bash -c "bin/ssh web uptime"' 'sudo bin/ssh web uptime' \
      'sed -i "" s/1/0/ ops/access/prod-db.conf; bin/ssh web uptime' 'true; bin/ssh web uptime' \
      'cd ops && sed -i "" s/PROD=1/PROD=0/ access/prod-db.conf' 'sed -i "" s/1/0/ ops//access/prod-db.conf' \
      'sed -i "" s/1/0/ ops/./access/prod-db.conf' 'cd ops; cat > access/x.conf' \
      'env -i PATH=/usr/bin:/bin HOME=$HOME bin/secret ssh.web # --has' 'bin/secret ssh.web # --set' \
      'env -u CLAUDECODE bin/secret --has ssh.web' 'bin/secret --list; bin/secret ssh.web'; do asks "$c"; done
  asks '../../bin/ssh prod-db uptime' x "$HUB/ops/infra"
  for c in 'bin/ssh web uptime' 'bin/ssh web "df -h"' './bin/ssh web uptime' "$HUB/bin/ssh web uptime" '"$CLAUDE_PROJECT_DIR"/bin/ssh web uptime' \
      'git status' 'ls -la' 'grep -n sshd_config notes.md' 'bin/secret --has ssh.web' 'bin/ssh web "FOO=1 make"' 'bin/ssh web env' 'bin/ssh web uptime 2>&1' 'bin/ssh web uptime > out.txt' \
      'bin/ssh web uptime | grep load' "cd /tmp && $HUB/bin/ssh web uptime" 'bin/secret --set ssh.web' 'bin/ssh web uptime; bin/ssh web df'; do quiet "$c"; done
  # a registry that differs from HEAD is unconfirmed: every host asks, and says why, until it is committed
  printf 'PROD=0\n' > ops/access/prod-db.conf.new; mv ops/access/prod-db.conf.new ops/access/new.conf
  o="$(hook "$HUB" 'bin/ssh web uptime')"; printf '%s' "$o" | grep -q 'not committed' || fail "ssh_asks: an untracked registry file does not ask: [$o]"
  rm ops/access/new.conf; sed -i '' 's/PROD=1/PROD=0/' ops/access/prod-db.conf
  o="$(hook "$HUB" 'bin/ssh prod-db uptime')"; printf '%s' "$o" | grep -q 'not committed' || fail "ssh_asks: a flipped PROD does not ask: [$o]"
  o="$(hook "$HUB" 'bin/ssh web uptime')"; printf '%s' "$o" | grep -q 'not committed' || fail "ssh_asks: a changed registry lets web pass: [$o]"
  git checkout -q -- ops/access; quiet 'bin/ssh web uptime'
  quiet '../../bin/ssh web uptime' Bash "$HUB/ops/infra"
  quiet 'ssh host' Read
  # an input it cannot read: asks when it names the ssh family, else stays out of the way
  o="$(printf 'not json ssh host' | bin/ssh-guard)"; printf '%s' "$o" | grep -q '"ask"' || fail "ssh_asks: malformed input naming ssh"
  assert_eq "$(printf 'not json' | bin/ssh-guard)" "" "ssh_asks: malformed input"
  # no python3: it cannot read the command, so it asks whenever the input names the ssh family
  local np="$TMPDIR/nopy"
  o="$(hookin "$HUB" 'bin/ssh web uptime' | PATH="$np" "$BASH" bin/ssh-guard)"; printf '%s' "$o" | grep -q '"ask"' || fail "ssh_asks: no python3, ssh named: [$o]"
  assert_eq "$(hookin "$HUB" 'ls -la' | PATH="$np" "$BASH" bin/ssh-guard)" "" "ssh_asks: no python3, nothing named"
  # bin/doctor flags a folder from before the guard
  bin/new ops/infra >/dev/null 2>&1; local s=ops/infra/.claude/settings.json; python3 -c 'import json, sys; p = sys.argv[1]; d = json.load(open(p)); d["hooks"]["PreToolUse"] = [g for g in d["hooks"]["PreToolUse"] if "ssh-guard" not in json.dumps(g)]; json.dump(d, open(p, "w"), indent=2)' "$s"
  bin/doctor 2>&1 | grep -q "no ssh guard" || fail "ssh_asks: bin/doctor does not flag a folder without the guard"
  bin/new --settings ops/infra >/dev/null 2>&1
  # wired at the hub root and in every folder (the template, a new folder)
  python3 - .claude/settings.json templates/folder-settings.json <<'PY' || fail "ssh_asks: the hook is not wired"
import json, sys
for f, cmd in zip(sys.argv[1:], ['"$CLAUDE_PROJECT_DIR"/bin/ssh-guard', '"$CLAUDE_PROJECT_DIR"/../../bin/ssh-guard']):
    d = json.load(open(f))
    assert any(g.get("matcher") == "Bash" and any(h["command"] == cmd for h in g["hooks"]) for g in d["hooks"]["PreToolUse"]), f
PY
  bin/new ops/infra >/dev/null 2>&1; grep -q 'bin/ssh-guard' ops/infra/.claude/settings.json || fail "ssh_asks: a new folder lacks the hook"
  grep -qF '"Edit(/ops/access/**)"' .claude/settings.json && grep -qF '"Write(/ops/access/**)"' .claude/settings.json || fail "ssh_asks: root edits of the registry do not ask"
  grep -qF '"Edit(//**/ops/access/**)"' templates/folder-settings.json && grep -qF '"Write(//**/ops/access/**)"' templates/folder-settings.json || fail "ssh_asks: folder edits of the registry do not ask"
}

ssh_rule() {   # AC7
  local f; for f in templates/hub/CLAUDE.md personas/devops-sre.md; do
    grep -qi "never ask for a password, key or passphrase in chat" "$f" || fail "ssh_rule: $f lacks the rule"
    grep -qF 'relay the command `bin/ssh` printed' "$f" || fail "ssh_rule: $f does not say to relay the command"; done
}

ssh_registry; ssh_agent_only; ssh_password_store; ssh_missing_secret; ssh_trust; ssh_asks; ssh_rule
echo ok
