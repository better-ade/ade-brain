#!/bin/bash
set -u
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
}
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
