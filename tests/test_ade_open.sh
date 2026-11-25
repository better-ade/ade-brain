#!/bin/bash
# Stories W1 and W1b: bin/work opens sub-terminals in ADE, and inside ADE never a window
# (docs/stories/W1-bin-work-opens-sub-terminals-in-ade.md, docs/stories/W1b-inside-ade-never-a-window.md). One function
# per acceptance check; bash tests/test_ade_open.sh [check ...] runs only the named checks (all of them by default).
# Hermetic: a fake $ADE_HOOK_BIN (records its argv, answers with ADE_FAKE_RC), and stub `osascript` (records its argv,
# never runs the launcher), `security` and `claude` sit first on PATH. Real ADE, osascript, claude and the Keychain
# are never reached. The osascript stub also logs every call made inside ADE (all four ADE variables set) to
# $S/osa.inade, and every check fails if that file exists afterwards (W1b: inside ADE, never a window).
. "$(dirname "$0")/helpers.sh"
make_hub; cd "$HUB"
unset CLAUDE_CONFIG_DIR HUB_CLAUDE_CONFIG_DIR AGENT_TERMINAL ADE_HOOK_BIN ADE_HOOK_PORT ADE_HOOK_TOKEN ADE_PTY_ID
S="$(mktemp -d)"; mkdir -p "$S/tmp" "$S/home"; export TMPDIR="$S/tmp" HOME="$S/home"   # never the tester's HOME
trap 'rm -rf "$S" "$(dirname "$HUB")" "$CLAUDE_HOME" "$(dirname "$AGENT_SYNC_LOG")" "$(dirname "$AGENT_SYNC_LOCK")"' EXIT
CUR=""; fail() { echo "FAIL: ${CUR:-setup}: $*" >&2; exit 1; }
CAP="$S/cap"; KEY="sk-W1TEST-$RANDOM$RANDOM-c0ffee"; export CAP W1_KEY="$KEY" W1_ROOT="$S"
# the fake ADE helper. ADE_FAKE_MODE=cli (default) is an ADE with story 9: `help` prints the usage and the line
# `capabilities: command`; =cli-split prints `capabilities: command split` (a later build). =cli-4c is stories 4a/4c
# without 9 (ADE v0.23.0): the usage only, and an `open` with `-- COMMAND` is exit 1. =cli-near prints the usage and
# only near misses (`capabilities: commands split`, an indented copy), and refuses a command like cli-4c. =hook is a
# build without `ade open`: every call is hook mode, which reads stdin to its end, prints {} and exits 0. =hang: `help`
# never answers. An `open` call records its argv, a copy of the launcher (its last word) and answers with ADE_FAKE_RC
cat > "$S/ade-hook" <<'STUB'
#!/bin/bash
mkdir -p "$CAP"
M="${ADE_FAKE_MODE:-cli}"
if [ "$M" = hook ]; then [ "${1:-}" = help ] && echo help >> "$CAP/ade.help" || echo call >> "$CAP/ade.calls"; cat > /dev/null; echo '{}'; exit 0; fi
if [ "${1:-}" = help ]; then echo help >> "$CAP/ade.help"
  [ "$M" = hang ] && exec sleep 60
  echo "usage: ade open [--cwd DIR] [--split right|down] [--name NAME] [--focus] [-- COMMAND [ARG...]]"; echo "       ade help"
  case "$M" in cli) printf '%s\n' "" "capabilities: command" ;; cli-split) printf '%s\n' "" "capabilities: command split" ;;
    cli-near) printf '%s\n' "" "capabilities: commands split" "  capabilities: command" ;; esac
  exit 0; fi
echo call >> "$CAP/ade.calls"
printf '%s\n' "$@" > "$CAP/ade.argv"
last="${@: -1}"; [ -f "$last" ] && cp "$last" "$CAP/ade.launcher"
# the contract's word rule (printable ASCII): anything else is 422, which the CLI reports as exit 1
if printf '%s' "$*" | LC_ALL=C grep -q '[^ -~]'; then echo "ade: command words must be printable ASCII" >&2; exit 1; fi
# an ADE without story 9 cannot type a command: `-- COMMAND` is 422 "not supported yet", exit 1
case "$M" in cli-4c|cli-near) for a in "$@"; do [ "$a" != -- ] || { echo "ade: a command is not supported yet" >&2; exit 1; }; done ;; esac
# like the real CLI: the reason on the first stderr line, then a usage block (bin/work keeps only the first line)
[ -z "${ADE_FAKE_MSG:-}" ] || printf '%s\n' "ade: $ADE_FAKE_MSG" "usage: ade open [--cwd DIR] [--name NAME] [--focus] [-- COMMAND [ARG...]]" "       ade help" >&2
exit "${ADE_FAKE_RC:-0}"
STUB
# stub osascript: records its argv (one per line, then a separator) and the launcher it names; never runs it. Called
# inside ADE (the same four-variable rule as bin/work), it also logs to $W1_ROOT/osa.inade, which fails every check (W1b)
cat > "$S/osascript" <<'STUB'
#!/bin/bash
if [ -n "${ADE_HOOK_BIN:-}" ] && [ -f "$ADE_HOOK_BIN" ] && [ -x "$ADE_HOOK_BIN" ] && [ -n "${ADE_HOOK_PORT:-}" ] &&
  [ -n "${ADE_HOOK_TOKEN:-}" ] && [ -n "${ADE_PTY_ID:-}" ]; then { printf '%s\n' "$@"; echo ---; } >> "$W1_ROOT/osa.inade"; fi
mkdir -p "$CAP"; echo call >> "$CAP/osa.calls"; { printf '%s\n' "$@"; echo ---; } >> "$CAP/osa.argv"
L=$(printf '%s\n' "$@" | grep -o 'bash -l [^"]*' | head -1); L="${L#bash -l }"
[ -f "$L" ] && cp "$L" "$CAP/osa.launcher"
exit 0
STUB
# stub security: one stored account, deepseek-api-key, whose value is the test key
cat > "$S/security" <<'STUB'
#!/bin/bash
op="$1"; shift; acct=""; w=0
while [ $# -gt 0 ]; do case "$1" in -a) acct="$2"; shift 2;; -w) w=1; shift;; *) shift;; esac; done
case "$op" in find-generic-password) [ "$acct" = deepseek-api-key ] || exit 44; [ "$w" = 1 ] && printf '%s' "$W1_KEY"; exit 0;; esac
exit 1
STUB
# the fake engine: a marker and its argv, nothing else written
cat > "$S/claude" <<'STUB'
#!/bin/bash
mkdir -p "$CAP"; echo "FAKE-CLAUDE" > "$CAP/claude.ran"; printf '%s\n' "$@" > "$CAP/claude.argv"
STUB
printf '#!/bin/bash\nexit 0\n' > "$S/not-exec"
chmod +x "$S/ade-hook" "$S/osascript" "$S/security" "$S/claude"
export PATH="$S:$PATH" AGENT_CLAUDE=claude
printf '%s\n' 'HUB_PROVIDERS_ALLOWED="anthropic deepseek"' 'HUB_OWNED_BY_OWNER=1' > hub.conf
bin/new projects/demo >/dev/null; bin/new projects/bare >/dev/null
R="$(mktemp -d "$S/code.XXXXXX")/demo-code"; mkdir -p "$R" && git -C "$R" init -q
printf '| demo-code | %s | main | Owner | none |\n' "$R" >> projects/demo/ACCESS.md

# inade CMD...: run CMD with the four ADE variables set (the fake helper)
inade() { env ADE_HOOK_BIN="$S/ade-hook" ADE_HOOK_PORT=4711 ADE_HOOK_TOKEN=00ff00ff ADE_PTY_ID=7 "$@"; }
# work CMD...: a fresh capture dir, then CMD with stdout and stderr captured; sets rc
work() { rm -rf "$CAP"; mkdir -p "$CAP"; "$@" > "$S/out" 2> "$S/err"; rc=$?; }
n() { [ -f "$CAP/$1.calls" ] && grep -c . "$CAP/$1.calls" || echo 0; }
argv_L() { tail -1 "$CAP/ade.argv"; }   # the launcher the helper was given
lines() { grep -c . "$1"; }
settings_in() { grep -o -- "--settings '[^']*'" "$1" | head -1 | sed "s/^--settings '//; s/'\$//"; }
osa_terminal() { printf '%s\n' -e "tell application \"Terminal\" to do script \"bash -l $1\"" -e 'tell application "Terminal" to activate' ---; }
osa_iterm() { printf '%s\n' -e "tell application \"iTerm\" to create window with default profile command \"bash -l $1\"" ---; }
osa_L() { grep -o 'bash -l [^"]*' "$CAP/osa.argv" | head -1 | sed 's/^bash -l //'; }
# only_reason FILE WHAT: bin/work printed one work: line carrying ADE's first stderr line and none of its usage block
only_reason() { assert_eq "$(lines "$1")" 1 "$2: stderr lines ($(cat "$1"))"; grep -q '^work: ' "$1" || fail "$2: the line does not start with work:"
  grep -qF "usage: ade" "$1" && fail "$2: ADE's usage block was printed: $(cat "$1")"; grep -qF "ade help" "$1" && fail "$2: ADE's usage block was printed"; return 0; }
no_leftovers() { [ -z "$(ls "$TMPDIR" | grep -E '^agent-(work|settings)\.')" ] || fail "$1: left $(ls "$TMPDIR")"; }
clean_tmp() { rm -f "$TMPDIR"/agent-work.* "$TMPDIR"/agent-settings.*; }
# the stopgap (W1b): the bare open's argv, and the launcher named in bin/work's paste line, unquoted with set (never run)
bare_argv() { printf '%s\n' open --cwd "$1" --name "$2" --focus; }
PASTE="paste this there to start the session: "
pasted_L() { local c; c="$(grep -F "$PASTE" "$1" | head -1)"; c="${c#*"$PASTE"}"; eval "set -- $c"; [ "$1 $2" = "bash -l" ] && [ $# = 3 ] && echo "$3"; }
# no_window_hint FILE WHAT: a failure inside ADE points at a terminal outside ADE, never at AGENT_TERMINAL=terminal
no_window_hint() { grep -qF "outside ADE" "$1" || fail "$2: no outside-ADE hint: $(cat "$1")"
  grep -qF "AGENT_TERMINAL=terminal" "$1" && fail "$2: the hint names AGENT_TERMINAL=terminal, refused inside ADE"; return 0; }

# C1
ade_is_detected_only_with_all_four() {
  local v
  for v in ADE_HOOK_BIN ADE_HOOK_PORT ADE_HOOK_TOKEN ADE_PTY_ID; do
    work inade env -u "$v" bin/work projects/demo; assert_eq "$rc" 0 "$v unset: exit"
    assert_eq "$(n ade)" 0 "$v unset: helper called"; assert_eq "$(n osa)" 1 "$v unset: one window"
    work inade env "$v=" bin/work projects/demo; assert_eq "$rc" 0 "$v empty: exit"
    assert_eq "$(n ade)" 0 "$v empty: helper called"; assert_eq "$(n osa)" 1 "$v empty: one window"
  done
  work inade env ADE_HOOK_BIN="$S/not-exec" bin/work projects/demo
  assert_eq "$(n ade)" 0 "non-executable helper: helper called"; assert_eq "$(n osa)" 1 "non-executable helper: one window"
  work inade env ADE_HOOK_BIN="$S" bin/work projects/demo
  assert_eq "$(n osa)" 1 "a directory as the helper: one window"
  work inade bin/work projects/demo; assert_eq "$(n ade)" 1 "all four set: the helper"; assert_eq "$(n osa)" 0 "all four set: no window"
  clean_tmp
}
# C2
inside_ade_opens_one_sub_terminal_and_no_window() {
  work inade bin/work projects/demo; assert_eq "$rc" 0 "exit"
  assert_eq "$(n ade)" 1 "helper called once"; assert_eq "$(n osa)" 0 "osascript called"
  assert_eq "$(cat "$CAP/ade.help" 2>/dev/null | grep -c .)" 1 "one help probe before the open"
  local L; L="$(argv_L)"
  case "$L" in "$TMPDIR"/agent-work.*) ;; *) fail "the launcher is not bin/work's: [$L]" ;; esac
  assert_eq "$(cat "$CAP/ade.argv")" "$(printf '%s\n' open --cwd "$R" --name demo --focus -- bash -l "$L")" "helper argv"
  clean_tmp
}
# C3
name_is_the_folder_and_cwd_is_the_checkout() {
  work inade bin/work projects/demo/; assert_eq "$rc" 0 "trailing slash: exit"
  assert_eq "$(sed -n 3p "$CAP/ade.argv")" "$R" "--cwd is the checkout"
  assert_eq "$(sed -n 4,5p "$CAP/ade.argv" | tr '\n' ' ')" "--name demo " "trailing slash: --name is the folder"
  work inade bin/work projects/bare; assert_eq "$rc" 0 "no repo: exit"
  assert_eq "$(sed -n 2,5p "$CAP/ade.argv" | tr '\n' '|')" "--cwd|$HUB/projects/bare|--name|bare|" "no repo: the hub folder"
  clean_tmp
}
# C4
ade_and_window_launchers_are_identical() {
  work inade bin/work projects/demo --model opus --prompt "go"; cp "$CAP/ade.launcher" "$S/l.ade" || fail "no ADE launcher"
  work bin/work projects/demo --model opus --prompt "go"; cp "$CAP/osa.launcher" "$S/l.win" || fail "no window launcher"
  # each launch has its own merged settings file (story I1: settings.json + settings.local.json); its name aside, the same
  for f in l.ade l.win; do sed -E 's/agent-settings\.[A-Za-z0-9]+/agent-settings.X/g' "$S/$f" > "$S/$f.n"; done
  cmp -s "$S/l.ade.n" "$S/l.win.n" || fail "the launchers differ: $(diff "$S/l.ade.n" "$S/l.win.n")"
  bash -n "$S/l.ade" || fail "the launcher is not valid bash"
  assert_eq "$(head -1 "$S/l.ade")" "#!/bin/bash" "shebang"
  assert_eq "$(sed -n 2p "$S/l.ade.n")" "trap 'rm -f \"\$0\" '\\''$TMPDIR/agent-settings.X'\\'' \"\$R\"' EXIT" "the launcher's trap (itself, its merged settings and its session record)"
  clean_tmp
}
# C5
exit_0_keeps_the_launcher_until_the_shell_runs_it() {
  local L M
  work inade bin/work projects/demo; assert_eq "$rc" 0 "exit"; L="$(argv_L)"
  [ -f "$L" ] || fail "exit 0 deleted the launcher"
  bash "$L" > /dev/null 2>&1; [ -f "$CAP/claude.ran" ] || fail "the launcher did not run the fake claude"
  [ ! -e "$L" ] || fail "the launcher did not remove itself"
  work inade bin/work --provider deepseek projects/demo; assert_eq "$rc" 0 "provider: exit ($(cat "$S/err"))"
  L="$(argv_L)"; M="$(settings_in "$L")"
  [ -f "$L" ] && [ -n "$M" ] && [ -f "$M" ] || fail "provider: exit 0 deleted the launcher [$L] or the settings [$M]"
  rm -f "$CAP/claude.ran"; bash "$L" > /dev/null 2>&1; [ -f "$CAP/claude.ran" ] || fail "provider: the fake claude did not run"
  [ ! -e "$L" ] && [ ! -e "$M" ] || fail "provider: the launcher left itself or the settings behind"
  no_leftovers "after the launchers ran"
}
# C6a (owner, 2026-11-09): ADE refused, so no window outside ADE
exit_1_refuses_with_a_hint_and_opens_no_window() {
  work inade env ADE_FAKE_RC=1 ADE_FAKE_MSG="refused 1" bin/work projects/demo
  assert_eq "$rc" 1 "exit"; assert_eq "$(n ade)" 1 "helper called once"; assert_eq "$(n osa)" 0 "osascript called"
  only_reason "$S/err" "exit 1"
  grep -qF "refused 1" "$S/err" || fail "the line does not carry ADE's error"
  no_window_hint "$S/err" "exit 1"
  no_leftovers "exit 1"
  # a non-ASCII TMPDIR: ADE answers 422 (exit 1), so bin/work refuses too, with no window
  local T="$S/tmp/caf"$'\xc3\xa9'; mkdir -p "$T"
  work inade env TMPDIR="$T" bin/work projects/demo; assert_eq "$rc" 1 "non-ASCII TMPDIR: exit"
  assert_eq "$(n ade)" 1 "non-ASCII TMPDIR: helper called"; assert_eq "$(n osa)" 0 "non-ASCII TMPDIR: osascript called"
  assert_eq "$(lines "$S/err")" 1 "non-ASCII TMPDIR: one line"
  rm -rf "$T"
}
# C6b (W1b, owner 2026-11-09: inside ADE, never a window): ADE unreachable (stale variables, connection refused)
# fails with ADE's exit code and message, removes the launcher and opens no window
exit_3_4_fail_and_open_no_window() {
  local c L
  for c in 3 4; do
    work inade env ADE_FAKE_RC=$c ADE_FAKE_MSG="unreachable $c" bin/work --provider deepseek projects/demo
    assert_eq "$rc" "$c" "exit $c: bin/work exit"; assert_eq "$(n ade)" 1 "exit $c: helper called once"
    assert_eq "$(n osa)" 0 "exit $c: a window opened"; L="$(argv_L)"
    only_reason "$S/err" "exit $c"
    grep -qF "unreachable $c" "$S/err" || fail "exit $c: the line does not carry ADE's reason"
    no_window_hint "$S/err" "exit $c"
    [ ! -e "$L" ] || fail "exit $c: the launcher was left behind"; no_leftovers "exit $c"
  done
}
# C18 (W1b): ADE types the command only when its `help` has a line starting `capabilities:` with the word `command`
# (story 9). 4a/4c without 9 (v0.23.0) and near misses show `usage: ade open`: they get the stopgap, a bare sub-terminal
# (C20). Hook mode (no `ade open`) and a helper that never answers cannot open one: exit 1, nothing opened, no window
an_ade_without_typed_commands_never_uses_a_window() {
  local m L t0 f
  for m in cli-4c cli-near; do for f in "" AGENT_TERMINAL=ade; do
    work inade env $f ADE_FAKE_MODE=$m bin/work projects/demo; assert_eq "$rc" 0 "$m ${f:-auto}: exit ($(cat "$S/err"))"
    assert_eq "$(n ade)" 1 "$m ${f:-auto}: one open"; assert_eq "$(n osa)" 0 "$m ${f:-auto}: a window opened"
    assert_eq "$(cat "$CAP/ade.help" | grep -c .)" 1 "$m ${f:-auto}: one help probe"
    assert_eq "$(cat "$CAP/ade.argv")" "$(bare_argv "$R" demo)" "$m ${f:-auto}: the bare open argv"
    assert_eq "$(lines "$S/err")" 1 "$m ${f:-auto}: one line ($(cat "$S/err"))"; grep -q '^work: ' "$S/err" || fail "$m: the line does not start with work:"
    clean_tmp
  done; done
  for m in hook hang; do for f in "" AGENT_TERMINAL=ade; do
    t0=$SECONDS; work inade env $f ADE_FAKE_MODE=$m bin/work projects/demo; assert_eq "$rc" 1 "$m ${f:-auto}: exit ($(cat "$S/err"))"
    [ $((SECONDS - t0)) -lt 15 ] || fail "$m: the probe took $((SECONDS - t0))s"
    assert_eq "$(n ade)" 0 "$m ${f:-auto}: open was called"; assert_eq "$(n osa)" 0 "$m ${f:-auto}: a window opened"
    assert_eq "$(cat "$CAP/ade.help" | grep -c .)" 1 "$m ${f:-auto}: one help probe"
    only_reason "$S/err" "$m ${f:-auto}"; grep -qF "ade open" "$S/err" || fail "$m: the line does not name ade open"
    no_window_hint "$S/err" "$m ${f:-auto}"; no_leftovers "$m ${f:-auto}"
  done; done
  for m in cli cli-split; do
    work inade env ADE_FAKE_MODE=$m bin/work projects/demo; assert_eq "$rc" 0 "$m: exit"
    assert_eq "$(n ade)" 1 "$m: open called"; assert_eq "$(n osa)" 0 "$m: a window opened"
  done
  clean_tmp
  # hook mode reads stdin to its end. With a GNU-style timeout (a fake on PATH that runs the command in the foreground,
  # so it inherits stdin, unlike lib.sh's fallback) and stdin on a pipe that never closes (a Claude Code Bash tool),
  # the probe must not wait on bin/work's stdin
  local T="$S/gnu"; mkdir -p "$T"; printf '#!/bin/bash\nshift\nexec "$@"\n' > "$T/timeout"; chmod +x "$T/timeout"
  rm -rf "$CAP"; mkdir -p "$CAP"; rm -f "$S/w.pid" "$S/w.res"
  { sleep 30 & echo $! > "$S/w.pid"; wait; } | { t0=$SECONDS
    inade env PATH="$T:$PATH" ADE_FAKE_MODE=hook bin/work projects/demo > "$S/out" 2> "$S/err"; echo "$? $((SECONDS - t0))" > "$S/w.res"; } &
  local p=$! i=0; while [ ! -s "$S/w.res" ] && [ $i -lt 150 ]; do sleep 0.1; i=$((i + 1)); done
  kill "$(cat "$S/w.pid")" 2>/dev/null; wait "$p" 2>/dev/null
  [ -s "$S/w.res" ] || fail "hook on an open pipe: bin/work had not finished after 15s"
  set -- $(cat "$S/w.res"); assert_eq "$1" 1 "hook on an open pipe: exit ($(cat "$S/err"))"
  [ "$2" -lt 4 ] || fail "hook on an open pipe: the probe took ${2}s (it read bin/work's stdin)"
  assert_eq "$(n ade)" 0 "hook on an open pipe: open was called"; assert_eq "$(n osa)" 0 "hook on an open pipe: a window opened"
  clean_tmp
}
# C20 (W1b stopgap): on an ADE without `capabilities: command`, bin/work opens a bare sub-terminal (no command), keeps
# the launcher, prints one line with the quoted command to paste there, and exits 0. Nothing secret is in that line
the_stopgap_opens_a_bare_sub_terminal_and_prints_the_command() {
  local L M T
  work inade env ADE_FAKE_MODE=cli-4c bin/work --provider deepseek projects/demo --prompt "secret W1-MARK plan"
  assert_eq "$rc" 0 "exit ($(cat "$S/err"))"; assert_eq "$(n osa)" 0 "a window opened"
  assert_eq "$(cat "$CAP/ade.argv")" "$(bare_argv "$R" demo)" "the bare open argv"
  assert_eq "$(lines "$S/err")" 1 "one stderr line ($(cat "$S/err"))"
  grep -qF "work: opened sub-terminal 'demo' in ADE; $PASTE" "$S/err" || fail "the paste line: $(cat "$S/err")"
  L="$(pasted_L "$S/err")"; case "$L" in "$TMPDIR"/agent-work.*) ;; *) fail "the pasted launcher is not bin/work's: [$L]" ;; esac
  M="$(settings_in "$L")"; [ -f "$L" ] && [ -n "$M" ] && [ -f "$M" ] || fail "the stopgap deleted the launcher [$L] or the settings [$M]"
  grep -qF -- W1-MARK "$S/err" "$CAP/ade.argv" && fail "the prompt is in the paste line or the helper argv"
  grep -qF -- "$KEY" "$L" "$M" "$S/out" "$S/err" && fail "the key was written or printed"
  rm -f "$CAP/claude.ran"; bash "$L" > /dev/null 2>&1; [ -f "$CAP/claude.ran" ] || fail "the pasted launcher did not run the fake claude"
  [ ! -e "$L" ] && [ ! -e "$M" ] || fail "the launcher left itself or the settings behind"
  no_leftovers "after the pasted launcher ran"
  # a TMPDIR with a quote and a space: the paste line quotes the path, so it is still one word
  T="$S/tmp/it's here"; mkdir -p "$T"
  work inade env TMPDIR="$T" ADE_FAKE_MODE=cli-4c bin/work projects/bare; assert_eq "$rc" 0 "quoted TMPDIR: exit ($(cat "$S/err"))"
  assert_eq "$(cat "$CAP/ade.argv")" "$(bare_argv "$HUB/projects/bare" bare)" "quoted TMPDIR: the bare open argv"
  L="$(pasted_L "$S/err")"; case "$L" in "$T"/agent-work.*) ;; *) fail "quoted TMPDIR: the pasted launcher [$L]" ;; esac
  [ -f "$L" ] || fail "quoted TMPDIR: the launcher is gone"; rm -rf "$T"
}
# C21 (W1b): any `ade open` failure in the stopgap fails with ADE's code and message, removes the launcher, no window
stopgap_open_failures_never_open_a_window() {
  local c
  for c in 1 2 3 4 5 7; do
    work inade env ADE_FAKE_MODE=cli-4c ADE_FAKE_RC=$c ADE_FAKE_MSG="bare refused $c" bin/work --provider deepseek projects/demo
    assert_eq "$rc" "$c" "exit $c"; assert_eq "$(n ade)" 1 "exit $c: one open"; assert_eq "$(n osa)" 0 "exit $c: a window opened"
    only_reason "$S/err" "exit $c"; grep -qF "bare refused $c" "$S/err" || fail "exit $c: no ADE message: $(cat "$S/err")"
    grep -qF "$PASTE" "$S/err" && fail "exit $c: a paste line after a failure"
    no_window_hint "$S/err" "exit $c"; no_leftovers "exit $c"
  done
}
# C22 (W1b): inside ADE, osascript never runs, whatever ADE answers, whichever AGENT_TERMINAL value is set
osascript_never_runs_inside_ade() {
  local m c t
  for m in cli cli-4c hook; do for c in 0 1 3 5; do for t in "" ade terminal iterm other; do
    work inade env ADE_FAKE_MODE=$m ADE_FAKE_RC=$c AGENT_TERMINAL=$t bin/work projects/demo
    assert_eq "$(n osa)" 0 "$m, exit $c, AGENT_TERMINAL=$t: osascript ran"
    work inade env WORK_DRY=1 ADE_FAKE_MODE=$m ADE_FAKE_RC=$c AGENT_TERMINAL=$t bin/work projects/demo
    assert_eq "$(n osa)" 0 "dry, $m, exit $c, AGENT_TERMINAL=$t: osascript ran"; assert_eq "$(n ade)" 0 "dry: open called"
    clean_tmp
  done; done; done
}
# C19: the probe runs only after the folder is checked, so a typo'd folder fails at once (a helper that never answers
# would cost the full 5 s), forced ADE or not
a_bad_folder_fails_before_the_probe() {
  local t0 f
  for f in "" AGENT_TERMINAL=ade; do
    t0=$SECONDS; work inade env $f ADE_FAKE_MODE=hang bin/work projects/no-such-folder
    assert_eq "$rc" 2 "${f:-auto}: exit"; [ $((SECONDS - t0)) -lt 4 ] || fail "${f:-auto}: took $((SECONDS - t0))s"
    [ ! -e "$CAP/ade.help" ] || fail "${f:-auto}: the helper was probed before the folder was checked"
    assert_eq "$(n ade)" 0 "${f:-auto}: open called"; assert_eq "$(n osa)" 0 "${f:-auto}: a window opened"
    grep -qF "usage: bin/work" "$S/err" || fail "${f:-auto}: no usage line: $(cat "$S/err")"
  done
}
# C7
exit_5_prints_the_command_and_keeps_the_launcher() {
  local L M
  work inade env ADE_FAKE_RC=5 ADE_FAKE_MSG="the shell was not ready" bin/work --provider deepseek projects/demo
  assert_eq "$rc" 5 "exit"; assert_eq "$(n osa)" 0 "no window"; L="$(argv_L)"; M="$(settings_in "$L")"
  assert_eq "$(lines "$S/err")" 1 "one stderr line ($(cat "$S/err"))"
  grep -q '^work: ' "$S/err" || fail "the line does not start with work:"
  grep -qF "the shell was not ready" "$S/err" || fail "the line does not name the reason"
  grep -qF "bash -l $L" "$S/err" || fail "the line does not hold the command to run"
  [ -f "$L" ] && [ -f "$M" ] || fail "exit 5 deleted the launcher or the settings"
  clean_tmp
}
# C8
exit_2_fails_and_opens_nothing() {
  local L
  work inade env ADE_FAKE_RC=2 ADE_FAKE_MSG="usage" bin/work --provider deepseek projects/demo
  assert_eq "$rc" 2 "exit"; assert_eq "$(n osa)" 0 "no window"; L="$(argv_L)"
  only_reason "$S/err" "exit 2"; grep -qF "ade: usage" "$S/err" || fail "exit 2: ADE's reason is not shown: $(cat "$S/err")"
  [ ! -e "$L" ] || fail "the launcher was left behind"; no_leftovers "exit 2"
  # an answer outside the contract is a failure too, never a second session
  work inade env ADE_FAKE_RC=7 ADE_FAKE_MSG="odd" bin/work projects/demo
  assert_eq "$rc" 7 "unknown code: exit"; only_reason "$S/err" "unknown code"; assert_eq "$(n osa)" 0 "unknown code: no window"; no_leftovers "unknown code"
}
# C9 (W1b): AGENT_TERMINAL=terminal|iterm inside ADE is refused (exit 2) before any probe; outside ADE they open windows
a_forced_window_inside_ade_is_refused() {
  local t d L
  for t in terminal iterm; do for d in "" WORK_DRY=1; do
    work inade env $d AGENT_TERMINAL=$t bin/work projects/demo; assert_eq "$rc" 2 "$t ${d:-}: exit"
    assert_eq "$(n ade)" 0 "$t: helper open called"; assert_eq "$(n osa)" 0 "$t: a window opened"
    [ ! -e "$CAP/ade.help" ] || fail "$t: the helper was probed"
    only_reason "$S/err" "$t"; grep -qF "inside ADE every session opens in ADE" "$S/err" || fail "$t: the message: $(cat "$S/err")"
    grep -qF "outside ADE" "$S/err" || fail "$t: no outside-ADE hint"; no_leftovers "$t"
  done; done
  work env AGENT_TERMINAL=terminal bin/work projects/demo; assert_eq "$rc" 0 "terminal outside ADE: exit"
  L="$(osa_L)"; assert_eq "$(cat "$CAP/osa.argv")" "$(osa_terminal "$L")" "terminal outside ADE: argv"
  work env AGENT_TERMINAL=iterm bin/work projects/demo; assert_eq "$rc" 0 "iterm outside ADE: exit"
  L="$(osa_L)"; assert_eq "$(cat "$CAP/osa.argv")" "$(osa_iterm "$L")" "iterm outside ADE: argv"
  clean_tmp
}
# C9b: an unrecognised AGENT_TERMINAL value inside ADE is auto, so the ADE path
an_unrecognised_value_inside_ade_is_auto() {
  work inade env AGENT_TERMINAL=something-else bin/work projects/demo; assert_eq "$rc" 0 "exit ($(cat "$S/err"))"
  assert_eq "$(n ade)" 1 "the helper's open"; assert_eq "$(n osa)" 0 "a window opened"
  assert_eq "$(cat "$CAP/ade.argv")" "$(printf '%s\n' open --cwd "$R" --name demo --focus -- bash -l "$(argv_L)")" "helper argv"
  clean_tmp
}
# C10
forced_ade_never_falls_back() {
  local c
  for c in 1 3 4; do
    work inade env AGENT_TERMINAL=ade ADE_FAKE_RC=$c ADE_FAKE_MSG="refused $c" bin/work projects/demo
    assert_eq "$rc" "$c" "forced ade, exit $c"; assert_eq "$(n osa)" 0 "forced ade, exit $c: a window opened"
    grep -qF "refused $c" "$S/err" || fail "forced ade, exit $c: no message ($(cat "$S/err"))"
    no_leftovers "forced ade, exit $c"
  done
}
forced_ade_outside_ade_is_exit_2() {
  work env AGENT_TERMINAL=ade bin/work projects/demo; assert_eq "$rc" 2 "exit"
  assert_eq "$(n osa)" 0 "a window opened"; assert_eq "$(n ade)" 0 "helper called"
  local v; for v in ADE_HOOK_BIN ADE_HOOK_PORT ADE_HOOK_TOKEN ADE_PTY_ID; do grep -qF "$v" "$S/err" || fail "the message does not name $v"; done
  no_leftovers "forced ade outside"
}
# C11
outside_ade_is_the_window_path_unchanged() {
  local L
  work bin/work projects/demo; assert_eq "$rc" 0 "exit"; assert_eq "$(n ade)" 0 "helper called"
  L="$(osa_L)"; assert_eq "$(cat "$CAP/osa.argv")" "$(osa_terminal "$L")" "Terminal argv"
  [ -s "$S/err" ] && fail "outside ADE wrote to stderr: $(cat "$S/err")"
  work env AGENT_TERMINAL=iterm bin/work projects/demo; L="$(osa_L)"; assert_eq "$(cat "$CAP/osa.argv")" "$(osa_iterm "$L")" "iTerm argv"
  work env AGENT_TERMINAL=something-else bin/work projects/demo; L="$(osa_L)"; assert_eq "$(cat "$CAP/osa.argv")" "$(osa_terminal "$L")" "unrecognised value outside ADE"
  clean_tmp
}
# C12
dry_run_inside_ade_calls_nothing() {
  local want
  want="$(WORK_DRY=1 bin/work projects/demo --prompt "go")"
  work inade env WORK_DRY=1 bin/work projects/demo --prompt "go"; assert_eq "$rc" 0 "exit"
  ms() { sed -E 's/agent-settings\.[A-Za-z0-9]+/agent-settings.X/g'; }   # each run merges its own settings file (story I1)
  assert_eq "$(ms < "$S/out")" "$(echo "$want" | ms)" "the dry-run command line"
  assert_eq "$(n ade)" 0 "helper called"; assert_eq "$(n osa)" 0 "osascript called"
  [ ! -e "$CAP/ade.help" ] || fail "a dry run probed the helper"
  grep -qF -- "work: if this ADE lists capabilities: command, this runs: $S/ade-hook open --cwd $R --name demo --focus -- bash -l " "$S/err" || fail "the ADE argv is not shown: $(cat "$S/err")"
  grep -qF -- "work: if it does not, this runs: $S/ade-hook open --cwd $R --name demo --focus (no command) and prints the command to paste there: bash -l " "$S/err" || fail "the stopgap argv is not shown: $(cat "$S/err")"
  grep -qF -- "window" "$S/err" && fail "a dry run inside ADE mentions a window: $(cat "$S/err")"
  no_leftovers "dry run"
}
# C13
provider_session_under_ade_passes_only_the_launcher_path() {
  local L M
  work inade bin/work --provider deepseek projects/demo --prompt "secret plan"; assert_eq "$rc" 0 "exit ($(cat "$S/err"))"
  L="$(argv_L)"; M="$(settings_in "$L")"; [ -n "$M" ] || fail "no settings file in the launcher"
  assert_eq "$(cat "$CAP/ade.argv")" "$(printf '%s\n' open --cwd "$R" --name demo --focus -- bash -l "$L")" "helper argv"
  grep -qF -- "$KEY" "$CAP/ade.argv" && fail "the key is in the helper argv"
  grep -qF -- "$M" "$CAP/ade.argv" && fail "the settings path is in the helper argv"
  grep -qF -- "secret plan" "$CAP/ade.argv" && fail "the prompt is in the helper argv"
  grep -qF -- "ANTHROPIC_" "$CAP/ade.argv" && fail "ANTHROPIC_ is in the helper argv"
  grep -qF -- "$KEY" "$L" "$M" "$S/out" "$S/err" && fail "the key was written or printed"
  grep -qF -- "env -u " "$L" || fail "the launcher has no env -u scrub"
  grep -qF -- "CLAUDE_CONFIG_DIR=" "$L" || fail "the launcher has no CLAUDE_CONFIG_DIR"
  clean_tmp
}
# C14
runs_from_a_non_interactive_shell_without_a_tty() {
  rm -rf "$CAP"; mkdir -p "$CAP"
  inade bash --noprofile --norc bin/work projects/demo < /dev/null 2> "$S/err" | cat > "$S/out"; rc=${PIPESTATUS[0]}
  assert_eq "$rc" 0 "exit ($(cat "$S/err"))"; assert_eq "$(n ade)" 1 "helper called once"; assert_eq "$(n osa)" 0 "osascript called"
  grep -nE '(^|[^a-z_])tty([^a-z_]|$)|\[ -t [0-9]|(^|[;&|] *)read ' bin/work && fail "bin/work needs a terminal"
  clean_tmp
}
# C15: the prompt is in the launcher file only, never in the helper's argv or bin/work's stderr. stdout is not checked on
# purpose: it keeps today's full-command echo, prompt included (owner decision 2026-11-09)
prompt_stays_out_of_the_typed_command() {
  local P=$'Don\'t "say" $HOME `id` W1-MARK\n--second line' L
  work inade bin/work projects/demo --prompt "$P"; assert_eq "$rc" 0 "exit"; L="$(argv_L)"
  grep -qF -- "-- $(printf %q "$P")" "$CAP/ade.launcher" || fail "the prompt is not in the launcher"
  grep -qF W1-MARK "$CAP/ade.argv" && fail "the prompt is in the helper argv"
  assert_eq "$(lines "$CAP/ade.argv")" 10 "the helper argv has exactly ten words"
  grep -qF W1-MARK "$S/err" && fail "the prompt is in bin/work's stderr"
  clean_tmp
}
# C16
the_checks_use_only_stubs() {
  assert_eq "$(command -v osascript)" "$S/osascript" "osascript"
  assert_eq "$(command -v security)" "$S/security" "security"
  assert_eq "$(command -v claude)" "$S/claude" "claude"
  assert_eq "$(inade sh -c 'echo "$ADE_HOOK_BIN"')" "$S/ade-hook" "ADE_HOOK_BIN"
  # make_hub drops a tester's ADE terminal and AGENT_TERMINAL, so no test reaches a real ADE
  local got; got="$(env ADE_HOOK_BIN=/x ADE_HOOK_PORT=1 ADE_HOOK_TOKEN=t ADE_PTY_ID=1 AGENT_TERMINAL=ade \
    bash -c '. "$1/tests/helpers.sh"; make_hub; rm -rf "$(dirname "$HUB")" "$CLAUDE_HOME" "$(dirname "$AGENT_SYNC_LOG")" "$(dirname "$AGENT_SYNC_LOCK")"
    echo "${ADE_HOOK_BIN-}|${ADE_HOOK_PORT-}|${ADE_HOOK_TOKEN-}|${ADE_PTY_ID-}|${AGENT_TERMINAL-}"' _ "$REPO")"
  assert_eq "$got" "||||" "make_hub clears the ADE variables and AGENT_TERMINAL"
  # the inside-ADE guard in the osascript stub fires (then is reset), and stays quiet outside ADE
  rm -rf "$CAP"; mkdir -p "$CAP"; osascript -e x; [ ! -e "$S/osa.inade" ] || fail "the guard fired outside ADE"
  inade osascript -e x; [ -s "$S/osa.inade" ] || fail "the osascript stub does not log a call inside ADE"; rm -f "$S/osa.inade"
}
# C17
readme_documents_the_ade_path() {
  local sec; sec="$(awk '/^## /{p=($0=="## Deep work inside ADE")} p' README.md)"
  [ -n "$sec" ] || fail "README has no 'Deep work inside ADE' section"
  local w; for w in ADE_HOOK_BIN ADE_HOOK_PORT ADE_HOOK_TOKEN ADE_PTY_ID AGENT_TERMINAL=ade "ade open" "--focus" "story 9"; do
    printf '%s\n' "$sec" | grep -qF -- "$w" || fail "the section does not mention $w"; done
  local rows; rows="$(printf '%s\n' "$sec" | grep -E '^\| (`[0-9]|any other )')"
  assert_eq "$(printf '%s\n' "$rows" | grep -c .)" 6 "exit-code rows"
  printf '%s\n' "$rows" | grep -q '^| `0` ' || fail "no row for 0"
  printf '%s\n' "$rows" | grep -q '^| `1` .*outside ADE' || fail "no row for 1 with the outside-ADE hint"
  printf '%s\n' "$rows" | grep -q '^| `3`, `4` .*no window' || fail "no row for 3, 4 with no window"
  printf '%s\n' "$rows" | grep -qF 'AGENT_TERMINAL=terminal bin/work' && fail "a row still hints AGENT_TERMINAL=terminal inside ADE"
  # W1b: the no-window rule, the stopgap and the refused forced window
  for w in "never opens a Terminal or iTerm window" "$PASTE" "inside ADE every session opens in ADE" "usage: ade open"; do
    printf '%s\n' "$sec" | grep -qF -- "$w" || fail "the section does not mention: $w"; done
  printf '%s\n' "$sec" | grep -qF 'ade help' || fail "the section does not explain the ade help probe"
  printf '%s\n' "$sec" | grep -qF 'capabilities: command' || fail "the section does not name the capability line"
  printf '%s\n' "$rows" | grep -q '^| `2` ' || fail "no row for 2"
  printf '%s\n' "$rows" | grep -q '^| `5` ' || fail "no row for 5"
  printf '%s\n' "$rows" | grep -q '^| any other ' || fail "no row for any other code"
}

ALL="ade_is_detected_only_with_all_four inside_ade_opens_one_sub_terminal_and_no_window name_is_the_folder_and_cwd_is_the_checkout
ade_and_window_launchers_are_identical exit_0_keeps_the_launcher_until_the_shell_runs_it
exit_1_refuses_with_a_hint_and_opens_no_window exit_3_4_fail_and_open_no_window
an_ade_without_typed_commands_never_uses_a_window exit_5_prints_the_command_and_keeps_the_launcher
the_stopgap_opens_a_bare_sub_terminal_and_prints_the_command stopgap_open_failures_never_open_a_window
osascript_never_runs_inside_ade
exit_2_fails_and_opens_nothing a_forced_window_inside_ade_is_refused an_unrecognised_value_inside_ade_is_auto
a_bad_folder_fails_before_the_probe forced_ade_never_falls_back forced_ade_outside_ade_is_exit_2
outside_ade_is_the_window_path_unchanged dry_run_inside_ade_calls_nothing provider_session_under_ade_passes_only_the_launcher_path
runs_from_a_non_interactive_shell_without_a_tty prompt_stays_out_of_the_typed_command the_checks_use_only_stubs
readme_documents_the_ade_path"
for c in ${*:-$ALL}; do CUR="$c"; "$c"
  [ ! -e "$S/osa.inade" ] || fail "osascript ran inside ADE (W1b): $(cat "$S/osa.inade")"; echo "pass: $c"; done
echo ok
