#!/bin/bash
. "$(dirname "$0")/helpers.sh"
make_hub; cd "$HUB"
out=$(PATH=/usr/bin:/bin AGENT_REMOTE_KEY=/nonexistent DOCTOR_OFFLINE=1 bin/doctor); rc=$?
assert_eq "$rc" "0" "doctor always exits 0"
echo "$out" | grep -qE "^MISSING +gitleaks" || fail "missing gitleaks reported"
echo "$out" | grep -qE "^MISSING +remote ssh key +/nonexistent" || fail "missing ssh key reported"
out=$(PATH=/usr/bin:/bin DOCTOR_OFFLINE=1 bin/doctor); echo "$out" | grep -q "remote ssh key" && fail "no key configured, nothing to report"
echo "$out" | grep -qE "^MISSING +brain index +none yet" || fail "no index reported"
bin/brain index >/dev/null 2>&1; out=$(DOCTOR_OFFLINE=1 bin/doctor); echo "$out" | grep -qE "^OK +brain index" || fail "fresh index OK"
echo "- new" >> memory/MEMORY.md; out=$(DOCTOR_OFFLINE=1 bin/doctor); echo "$out" | grep -qE "^MISSING +brain index +1 file" || fail "stale index reported"
# a folder made before a hook was added to the template: doctor warns; bin/new --settings re-renders only that file
bin/new projects/old >/dev/null 2>&1; S=projects/old/.claude/settings.json
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); del d["hooks"]["PostToolUse"]; json.dump(d, open(sys.argv[1],"w"))' "$S"
echo "keep me" > projects/old/STATE.md
out=$(DOCTOR_OFFLINE=1 bin/doctor); echo "$out" | grep -qE "^WARN +settings projects/old +.*PostToolUse.*bin/new --settings projects/old" || fail "no warning for old settings: [$out]"
echo "$out" | grep -qE "settings projects/[^o]" && fail "a current folder warned"
bin/new --settings projects/old >/dev/null || fail "bin/new --settings failed"
[ -f "$S.bak" ] && ! grep -q PostToolUse "$S.bak" || fail "no .bak copy of the old settings"
grep -q '"PostToolUse"' "$S" && grep -q "bin/inbox projects/old" "$S" || fail "settings not re-rendered: $(cat "$S")"
assert_eq "$(cat projects/old/STATE.md)" "keep me" "--settings touches only the settings files"
DOCTOR_OFFLINE=1 bin/doctor | grep -q "settings projects/old" && fail "still warned after the re-render"
# story I1: a settings.json that names a hub path (a folder from before I1) is flagged for bin/setup, which fixes it
sed -i.x "s#\"\\\\\"\$CLAUDE_PROJECT_DIR\\\\\"/../../bin/inbox#\"\\\\\"$HUB\\\\\"/bin/inbox#" "$S"; rm -f "$S.x"
grep -qF "\\\"$HUB\\\"/bin/inbox" "$S" || fail "test setup: no hub path in $S"
out=$(DOCTOR_OFFLINE=1 bin/doctor); echo "$out" | grep -qE "^WARN +settings projects/old +.*names a hub path.*bin/setup" || fail "no warning for a hub path: [$out]"
bin/setup >/dev/null 2>&1; DOCTOR_OFFLINE=1 bin/doctor | grep -q "settings projects/old" && fail "still flagged after bin/setup"
# no local settings at all (a fresh clone before bin/setup): MISSING, and bin/setup writes them
L=projects/old/.claude/settings.local.json
rm "$L"; out=$(DOCTOR_OFFLINE=1 bin/doctor); echo "$out" | grep -qE "^MISSING +settings projects/old .*bin/setup" || fail "no MISSING for absent local settings: [$out]"
bin/setup >/dev/null 2>&1; DOCTOR_OFFLINE=1 bin/doctor | grep -q "settings projects/old" && fail "still flagged after bin/setup"
bin/new --settings projects/none >/dev/null 2>&1; assert_eq "$?" "2" "--settings on a missing folder exits 2"
# story V4: Docker is recommended, never needed. OK when `docker info` works; WARN (never MISSING) with this platform's
# install line, the group command, or how to start the engine; the exit code stays 0. A PATH of the system tools without
# any real docker, colima or brew (a Linux runner has /usr/bin/docker); the fakes log every call, so nothing is installed.
D="$(mktemp -d)"; mkdir -p "$D/sys" "$D/fake"
for f in /usr/bin/* /bin/*; do n="${f##*/}"; case "$n" in docker|docker-compose|colima|brew) continue ;; esac; [ -e "$D/sys/$n" ] || ln -s "$f" "$D/sys/$n"; done
for c in brew colima apt-get; do printf '#!/bin/bash\necho "%s $*" >> "%s/calls"\n' "$c" "$D" > "$D/fake/$c"; chmod +x "$D/fake/$c"; done
docker_fake() {   # <ok|denied|stopped|hung>: what `docker info` does (hung: exits 124, as timeout does when it kills it)
  printf '#!/bin/bash\necho "docker $*" >> "%s/calls"\ncase "$1" in --version) echo "Docker version 27.3.1, build ce12230" ;;\n  info) case %s in ok) echo "Server Version: 27.3.1" ;;\n    hung) exit 124 ;;\n    denied) echo "permission denied while trying to connect to the Docker daemon socket at unix:///var/run/docker.sock" >&2; exit 1 ;;\n    *) echo "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?" >&2; exit 1 ;; esac ;; esac\n' "$D" "$1" > "$D/fake/docker"; chmod +x "$D/fake/docker"; }
doc() { out=$(PATH="$D/fake:$D/sys" AGENT_PLATFORM="$1" DOCTOR_OFFLINE=1 bin/doctor 2>&1); rc=$?; dl="$(echo "$out" | grep -E '^[A-Z]+ +docker ')"; }
for p in macos linux; do
  rm -f "$D/fake/docker"; doc "$p"; assert_eq "$rc" 0 "doctor exits 0 without docker ($p)"
  # AC4: the Homebrew step names colima docker docker-compose (macOS); nothing is installed when docker works (below)
  if [ "$p" = macos ]; then il="brew install colima docker docker-compose"; else il="sudo apt-get install docker.io docker-compose-v2"; fi
  echo "$dl" | grep -qE "^WARN +docker .*not installed.*$il" || fail "docker missing on $p: WARN with the install line: [$dl]"
  echo "$out" | grep -qE '^MISSING +docker ' && fail "docker is never MISSING ($p)"
  docker_fake ok; doc "$p"; assert_eq "$rc" 0 "doctor exits 0 with docker ($p)"
  echo "$dl" | grep -qE '^OK +docker +Docker version 27.3.1' || fail "docker info works on $p: OK with the version: [$dl]"
  echo "$dl" | grep -q 'install' && fail "nothing to install when docker works ($p): [$dl]"   # AC4
  docker_fake denied; doc "$p"; assert_eq "$rc" 0 "doctor exits 0 when the daemon refuses this user ($p)"
  echo "$dl" | grep -qE "^WARN +docker .*refuses" || fail "the daemon refuses this user on $p: WARN: [$dl]"
  if [ "$p" = linux ]; then echo "$dl" | grep -qF "sudo usermod -aG docker $(printf %q "$(id -un)")" || fail "the group command on linux: [$dl]"
  else echo "$dl" | grep -q usermod && fail "no usermod on macOS: [$dl]"; fi
  docker_fake stopped; doc "$p"; assert_eq "$rc" 0 "doctor exits 0 when the engine is not running ($p)"
  if [ "$p" = macos ]; then st="colima start"; else st="sudo systemctl enable --now docker"; fi
  echo "$dl" | grep -qE "^WARN +docker .*not running.*$st" || fail "the engine is not running on $p: WARN with how to start it: [$dl]"
  docker_fake hung; doc "$p"; assert_eq "$rc" 0 "doctor exits 0 when docker info hangs ($p)"
  echo "$dl" | grep -qE "^WARN +docker .*did not answer in 15 s" || fail "a hung engine on $p: [$dl]"
  echo "$dl" | grep -q 'not running' && fail "a hung engine is not called stopped ($p): [$dl]"
done
grep -qE '^(brew|colima|apt-get) ' "$D/calls" 2>/dev/null && fail "doctor installed or started something: $(cat "$D/calls")"   # AC4
grep -qvE '^docker (--version|info)$' "$D/calls" && fail "doctor only asks docker --version and info: $(cat "$D/calls")"
rm -rf "$D"
echo ok
