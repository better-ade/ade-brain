#!/bin/bash
set -u
# macOS's `mktemp` with no template ignores $TMPDIR (it uses its own per-user folder), so those folders would escape the
# test's TMPDIR. Exported, so the bash scripts a test runs (bin/*) get the same: a bare `mktemp [-d]` lands in $TMPDIR.
mktemp() { local a bare=1; for a in "$@"; do case "$a" in -*) ;; *) bare=0 ;; esac; done
  if [ "$bare" = 1 ]; then command mktemp "$@" "${TMPDIR:-/tmp}/tmp.XXXXXXXXXX"; else command mktemp "$@"; fi; }
export -f mktemp
# story X2: this test process gets its own TMPDIR, removed when the process ends however it ends (exit, failure, SIGKILL).
# A detached watcher (streams on /dev/null, so a caller capturing the test's output is never held) waits for the PID.
# tests/run.sh already does this per file and sets ADE_TEST_TMP_OWNED, so nothing is added there.
if [ -z "${ADE_TEST_TMP_OWNED:-}" ]; then
  ADE_TEST_TMP_OWNED=1; TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/ade-test.XXXXXX")"; export ADE_TEST_TMP_OWNED TMPDIR
  ( p=$$; d="$TMPDIR"; while kill -0 "$p" 2>/dev/null; do sleep 0.2; done
    # orphans of a killed test may still be writing: retry for up to ~20 s until the folder is gone
    n=0; while [ -e "$d" ] && [ "$n" -lt 100 ]; do rm -rf "$d" 2>/dev/null; [ -e "$d" ] && sleep 0.2; n=$((n + 1)); done ) </dev/null >/dev/null 2>&1 &
  disown $! 2>/dev/null   # not a job of the test: a bare `wait` in it must not wait for the watcher
fi
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# tests never depend on the machine's git defaults: every `git init` (hubs, bare remotes, fixtures) starts on main
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=init.defaultBranch GIT_CONFIG_VALUE_0=main
fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] || fail "$3: got [$1] want [$2]"; }
assert_contains() { grep -qF -- "$2" "$1" || fail "$3: [$2] not in $1"; }
make_hub() {
  # results never depend on the tester's shell: no Anthropic credential or backend switch reaches a test
  local v; for v in $(compgen -e); do case "$v" in ANTHROPIC_*|CLAUDE_CODE_USE_*|CLAUDE_CODE_OAUTH_TOKEN) unset "$v" ;; esac; done
  # nor a tester's ADE terminal or terminal choice: bin/work would open a real ADE sub-terminal (story W1)
  unset ADE_HOOK_BIN ADE_HOOK_PORT ADE_HOOK_TOKEN ADE_PTY_ID AGENT_TERMINAL
  # the macOS behaviour (Keychain, launchd, Terminal) with the stubs the tests give, on any machine; tests/test_platform.sh
  # runs the Linux behaviour (story V1). GNU or BSD tools underneath are the machine's own.
  export AGENT_PLATFORM=macos AGENT_PLATFORM_TEST=1   # the override only counts with the test flag (bin/lib.sh)
  unset XDG_CONFIG_HOME   # the file store and systemd units go under the test's HOME, never a runner's real config
  HUB="$(mktemp -d)/hub"; mkdir -p "$HUB"
  (cd "$REPO" && tar cf - --exclude ./repos --exclude ./.git --exclude ./hub.conf --exclude ./.local --exclude ./.superpowers --exclude ./.claude/worktrees --exclude ./_bmad/render --exclude ./_bmad-output .) | (cd "$HUB" && tar xf -)
  rm -f "$HUB"/journal/[0-9]*.md   # test hubs start with an empty journal; the real journal/ is never touched
  git -C "$HUB" init -q && git -C "$HUB" config user.name t && git -C "$HUB" config user.email t@t
  CLAUDE_HOME="$(mktemp -d)"; export HUB CLAUDE_HOME
  export AGENT_OLLAMA_URL=http://127.0.0.1:9   # tests never reach a real Ollama (test_brain runs a fake one)
  export AGENT_TELEGRAM_API=http://127.0.0.1:9   # nor the Telegram Bot API (bin/chat say/forward; test_chat runs a stand-in)
  # tests never fetch ade-method: bin/method and bin/init sync from a local fixture of the template's own method files
  if [ -z "${METHOD_FIXTURE:-}" ]; then METHOD_FIXTURE="$(mktemp -d)/ade-method"; method_repo_from_template "$METHOD_FIXTURE"; fi
  export AGENT_METHOD_REPO="$METHOD_FIXTURE"
  # tests never push a real hub or touch the real sync log/lock; test_report turns auto sync on with a stub
  export AGENT_AUTO_SYNC=0 AGENT_SYNC_LOG="$(mktemp -d)/sync.log" AGENT_SYNC_LOCK="$(mktemp -d)/sync.lock"
  # tests never run ade's real installer (story T1): off unless a test turns it on, and a dead local address if one does
  export AGENT_ADE_INSTALL=off ADE_CLI_INSTALL_URL="file:///nonexistent/ade-install.sh"
}
# ade_sandbox (story T1): a temp HOME, a PATH without any ade, and a fake ade installer at ADE_CLI_INSTALL_URL. The
# installer logs each run to $ADE_FAKE_RUNS, waits (at most 10 s) for $ADE_FAKE_RELEASE, then fails with
# "fake: download failed" when ADE_FAKE_FAIL=1, else puts an ade printing "ade 9.9.9" in ~/.local/bin.
ade_sandbox() {
  local d p o=""; d="$(mktemp -d)"; export HOME="$d/home"; mkdir -p "$HOME"
  # a PATH dir holding an ade is replaced by a copy of its links without ade (it may hold git, curl, python3 too)
  local IFS=:; for p in $PATH; do if [ -x "$p/ade" ]; then local c f; c="$(mktemp -d)"
      for f in "$p"/*; do [ "${f##*/}" = ade ] || ln -s "$f" "$c/${f##*/}" 2>/dev/null; done; p="$c"; fi
    o="${o:+$o:}$p"; done; export PATH="$o"
  export ADE_FAKE_RUNS="$d/runs" ADE_FAKE_RELEASE="$d/release" ADE_CLI_INSTALL_URL="file://$d/install.sh"; unset AGENT_ADE_INSTALL
  cat > "$d/install.sh" <<'FAKE'
echo run >> "$ADE_FAKE_RUNS"; n=0
while [ ! -e "$ADE_FAKE_RELEASE" ] && [ "$n" -lt 100 ]; do sleep 0.1; n=$((n + 1)); done
[ "${ADE_FAKE_FAIL:-}" = 1 ] && { echo "fake: download failed" >&2; exit 3; }
mkdir -p "$HOME/.local/bin" && printf '#!/bin/sh\necho "ade 9.9.9"\n' > "$HOME/.local/bin/ade" && chmod +x "$HOME/.local/bin/ade"
FAKE
}
# runs_of FILE: how many lines it has (0 when missing)
runs_of() { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }
# ade_wait CMD...: poll up to 10 s for CMD to succeed
ade_wait() { local n=0; until "$@"; do [ "$n" -lt 100 ] || return 1; sleep 0.1; n=$((n + 1)); done; }
# fmode <file>: its permission bits in octal (700), on GNU and BSD alike
fmode() { python3 -c 'import os, sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$1"; }
# in_pty <cmd...>: run cmd in a pseudo-terminal (util-linux script on Linux, BSD script on macOS)
in_pty() { if script --version 2>/dev/null | grep -q util-linux; then script -q -e -c "$(printf '%q ' "$@")" /dev/null; else script -q /dev/null "$@"; fi; }
# plist_ok <file>: a valid property list (plutil where it exists, else Python's plistlib)
plist_ok() { if command -v plutil >/dev/null; then plutil -lint "$1" >/dev/null; else python3 -c 'import plistlib, sys; plistlib.load(open(sys.argv[1], "rb"))' "$1"; fi; }
# a fake macOS `security`: a name=value file ($STORE), every argv logged ($STORE.argv); -i reads commands from stdin
stub_security() {
  local d; d="$(mktemp -d)"; export STORE="$d/store"; : > "$STORE"
  cat > "$d/security" <<'STUB'
#!/bin/bash
[ -n "${SECURITY_STDIN:-}" ] || echo "$*" >> "$STORE.argv"
if [ "${1:-}" = -i ]; then
  while IFS= read -r line; do
    eval "$(python3 -c 'import shlex,sys; print("set -- " + " ".join(shlex.quote(x) for x in shlex.split(sys.argv[1])))' "$line")"
    SECURITY_STDIN=1 "$0" "$@" || exit 1
  done; exit 0
fi
op="$1"; shift; acct=""; val=""; w=0
while [ $# -gt 0 ]; do case "$1" in -a) acct="$2"; shift 2;; -w) if [ $# -ge 2 ]; then val="$2"; shift 2; else w=1; shift; fi;; *) shift;; esac; done
case "$op" in
  add-generic-password) [ "${SECURITY_FAIL:-}" != 1 ] || exit 1; grep -v "^$acct=" "$STORE" > "$STORE.t"; mv "$STORE.t" "$STORE"; echo "$acct=$val" >> "$STORE";;
  find-generic-password) l=$(grep "^$acct=" "$STORE") || exit 44; [ "$w" = 1 ] && echo "${l#*=}"; exit 0;;
  delete-generic-password) grep -q "^$acct=" "$STORE" || exit 44; grep -v "^$acct=" "$STORE" > "$STORE.t"; mv "$STORE.t" "$STORE";;
esac
STUB
  chmod +x "$d/security"; export PATH="$d:$PATH"
}
# method_repo DIR TAG...: a local stand-in for ade-method (story C1), never the network. Each tag's commit holds
# rules.md "rules TAG" and bmad/custom/bmad-build.toml, bmad-code-review.toml ("# build TAG", "# review TAG").
method_repo() {
  local d="$1" t; shift; mkdir -p "$d/bmad/custom" && git -C "$d" init -q && git -C "$d" config user.name t && git -C "$d" config user.email t@t
  for t in "$@"; do echo "rules $t" > "$d/rules.md"; echo "# build $t" > "$d/bmad/custom/bmad-build.toml"
    echo "# review $t" > "$d/bmad/custom/bmad-code-review.toml"; git -C "$d" add -A && git -C "$d" commit -qm "$t" && git -C "$d" tag "$t"; done
}
# method_repo_from_template DIR: a stand-in whose pinned tag holds the template's own method files, so bin/init in any
# test syncs what the template already has (make_hub points AGENT_METHOD_REPO at it)
method_repo_from_template() {
  local d="$1"; mkdir -p "$d/bmad/custom" && git -C "$d" init -q && git -C "$d" config user.name t && git -C "$d" config user.email t@t
  cp "$REPO/.ade/rules.md" "$d/rules.md"; cp "$REPO"/_bmad/custom/*.toml "$d/bmad/custom/"
  git -C "$d" add -A && git -C "$d" commit -qm pin && git -C "$d" tag "$(bash -c ". '$REPO/bin/lib.sh' && method_pin")"
}
