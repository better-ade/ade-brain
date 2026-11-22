#!/bin/bash
# Shared helpers for bin/ scripts. HUB and CLAUDE_HOME may be overridden (tests).
hub_root() { if [ -n "${HUB:-}" ]; then echo "$HUB"; else (cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd); fi; }
# the Claude config dir this hub's install uses (memory and skills are linked there): CLAUDE_HOME (tests), else
# HUB_CLAUDE_CONFIG_DIR from hub.conf, else the shell's CLAUDE_CONFIG_DIR, else ~/.claude
claude_home() { echo "${CLAUDE_HOME:-${HUB_CLAUDE_CONFIG_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}}"; }
# the Claude install hub sessions run as: AGENT_CLAUDE, else HUB_CLAUDE from hub.conf, else claude
claude_cmd() { echo "${AGENT_CLAUDE:-${HUB_CLAUDE:-claude}}"; }
encode_path() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }
# wrapper_config_dir CMD: the CLAUDE_CONFIG_DIR a wrapper script exports (empty for a binary or a plain claude)
wrapper_config_dir() { local w c; w="$(command -v -- "$1" 2>/dev/null)"
  [ -n "$w" ] && [ -f "$w" ] && [ "$(wc -c < "$w")" -lt 65536 ] || return 0
  c="$(sed -n "s/^[[:space:]]*export[[:space:]][[:space:]]*CLAUDE_CONFIG_DIR=[\"']\{0,1\}\([^\"']*\).*/\1/p" "$w" | head -1)"
  c="${c//\$\{HOME\}/$HOME}"; c="${c//\$HOME/$HOME}"; c="${c/#\~/$HOME}"; printf '%s' "$c"; }
# link_memory CONFIG_DIR DIR [TARGET]: Claude's auto-memory for sessions in DIR, inside CONFIG_DIR, becomes a link to
# TARGET (default DIR/memory). Files already in a plain memory folder there are copied in first (never overwriting), and
# the folder is kept as memory.bak-<time>. Prints "ok" when the link was already right, "linked" otherwise.
link_memory() { local mem="$1/projects/$(encode_path "$2")/memory" tgt="${3:-$2/memory}"
  mkdir -p "$tgt" "$(dirname "$mem")" || return 1
  if [ -L "$mem" ] && [ "$(readlink "$mem")" = "$tgt" ]; then echo ok; return 0; fi
  if [ -d "$mem" ] && [ ! -L "$mem" ]; then
    cp -n "$mem"/* "$tgt/" 2>/dev/null || true
    mv "$mem" "$mem.bak-$(date -u +%Y%m%dT%H%M%SZ)"
  fi
  rm -f "$mem"; ln -s "$tgt" "$mem" && echo linked; }
utc_today() { date -u +%Y-%m-%d; }
utc_now() { date -u +%H:%M; }
folders() { local h; h="$(hub_root)"; for d in "$h"/projects/* "$h"/ops/*; do [ -d "$d" ] && echo "${d#$h/}"; done; }
agent_name() { case "$1" in projects/*) echo "${1#projects/}";; ops/*) echo "ops-${1#ops/}";; esac; }
state_dir() { echo "${AGENT_STATE:-$HOME/.agent-hub/$(hub_name)}"; }
# session_mark <folder> <busy|idle>: a focus session started by bin/work notes its status and the time in its own
# registry entry ($(state_dir)/sessions/<name>.<launcher pid>, name = its --name or the folder name; the launcher is an ancestor of the hook that calls this).
# Called outside a focus session (the hub root, a plain terminal) it finds no entry and does nothing. Never fails.
session_mark() {
  local sd n p e i; sd="$(state_dir)/sessions"; n="${1##*/}"; p=$$
  [ -n "$n" ] && [ -d "$sd" ] || return 0
  for i in 1 2 3 4 5 6 7 8; do
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' '); [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -gt 1 ] || return 0
    # the entry is <name>.<launcher pid>; name is the folder's or the session's --name, so match the pid and the folder
    e=""; for c in "$sd"/*."$p"; do [ -f "$c" ] && [ "$(sed -n 's/^folder=//p' "$c" | head -1)" = "$1" ] && { e="$c"; break; }; done
    [ -n "$e" ] || { [ -f "$sd/$n.$p" ] && e="$sd/$n.$p"; } || continue
    { grep -v -e '^status=' -e '^last=' "$e"; printf 'status=%s\nlast=%s\n' "$2" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; } > "$sd/.mark.$$" 2>/dev/null &&
      mv "$sd/.mark.$$" "$e" 2>/dev/null || rm -f "$sd/.mark.$$"
    return 0
  done; return 0
}
# repos_of <folder>: existing checkout dirs from the Checkout column of ACCESS.md's Code table (absolute, ~ allowed).
# Any table row whose 2nd cell starts with / or ~ counts, so a row appended after the table still works.
repos_of() {
  local a; a="$(hub_root)/$1/ACCESS.md"; [ -f "$a" ] || return 0
  awk -F'|' '/^\|/{c=$3; gsub(/^[ \t]+|[ \t]+$/,"",c); if(c ~ /^[\/~]/)print c}' "$a" |
    while IFS= read -r r; do r="${r/#\~/$HOME}"; [ -d "$r" ] && echo "$r"; done
}
# stale_repos <folder>: repos whose HEAD commit is newer than STATE.md's mtime, as "<repo> <hash>" lines
stale_repos() {
  local s m r ct; s="$(hub_root)/$1/STATE.md"; [ -f "$s" ] || return 0; m=$(file_mtime "$s")
  repos_of "$1" | while IFS= read -r r; do
    ct=$(git -C "$r" log -1 --format=%ct 2>/dev/null) || continue
    [ -n "$ct" ] && [ "$ct" -gt "$m" ] && echo "$r $(git -C "$r" rev-parse HEAD)"
  done
  return 0
}
# _timeout_fallback <secs> <cmd...>: no timeout/gtimeout installed. Run in the background, sleep, then kill the
# command and its children (so a pipe it holds open closes). Returns the command's status, or 124 if it was killed.
_timeout_fallback() {
  local s="$1" p w rc; shift
  "$@" & p=$!
  ( sleep "$s"; pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null ) >/dev/null 2>&1 & w=$!
  wait "$p" 2>/dev/null; rc=$?
  if kill -0 "$w" 2>/dev/null; then pkill -P "$w" 2>/dev/null; kill "$w" 2>/dev/null; wait "$w" 2>/dev/null; return "$rc"; fi
  return 124
}
# A timeout that works on macOS: GNU coreutils' gtimeout when installed, else the fallback above.
if ! command -v timeout >/dev/null; then
  if command -v gtimeout >/dev/null; then timeout() { gtimeout "$@"; }; else timeout() { _timeout_fallback "$@"; }; fi
fi
# Providers behind Claude Code (story SP; contract in .ade/context/providers.md, findings in .ade/context/engines.md).
# One row per provider; anthropic (Claude Code's own login) has no row. Base URLs live only here: no override, ever.
# Fields: base_url, secret (Keychain name for bin/secret), label (doctor), model/opus/sonnet/haiku/small (slots),
# owner_only (1 = only in a hub with HUB_OWNED_BY_OWNER=1; owner rule 2026-11-09, ADR 0002; a row without it is owner-only too).
providers() { echo "deepseek glm"; }
provider_field() {
  case "$1:$2" in
    deepseek:base_url) echo "https://api.deepseek.com/anthropic" ;;
    deepseek:secret) echo "deepseek-api-key" ;;
    deepseek:label) echo "DeepSeek API key" ;;
    deepseek:model|deepseek:sonnet|deepseek:haiku|deepseek:small) echo "deepseek-flash" ;;
    deepseek:opus) echo "deepseek-v4-pro" ;;
    deepseek:owner_only) echo 1 ;;
    glm:base_url) echo "https://api.z.ai/api/anthropic" ;;
    glm:secret) echo "zai-api-key" ;;
    glm:label) echo "z.ai API key" ;;
    glm:owner_only) echo 1 ;;
    glm:model|glm:opus|glm:sonnet|glm:haiku|glm:small) echo "unconfirmed" ;;
    gemini:secret) echo "gemini-api-key" ;;
    gemini:label) echo "Gemini API key" ;;
    gemini:owner_only) echo 1 ;;
    *) return 1 ;;
  esac
}
# provider_feature_go <provider> <focus|agents|delegation|effort|remote>: 0 = go (S0 item 21). One go per line.
provider_feature_go() {
  case "$1:$2" in
    deepseek:focus) return 0 ;;
    deepseek:agents) return 0 ;;
    deepseek:delegation) return 0 ;;
    deepseek:effort) return 0 ;;
    gemini:focus) return 0 ;;
    gemini:delegation) return 0 ;;
    *) return 1 ;;
  esac
}
provider_no_go_reason() { echo "provider $1 has no go for $2 (S0 item 21, .ade/context/engines.md)"; }
# provider_model_ok <provider> <model>: a slot alias or an id from the row
provider_model_ok() {
  case "$2" in opus|sonnet|haiku) return 0 ;; esac
  local s; for s in model opus sonnet haiku small; do [ "$(provider_field "$1" "$s")" = "$2" ] && return 0; done; return 1
}
# provider_model_id <provider> <model>: a slot alias resolved through the row, else the model itself
provider_model_id() { case "$2" in opus|sonnet|haiku) provider_field "$1" "$2" ;; *) echo "$2" ;; esac; }
# provider_hub_refusal <provider>: prints why this hub may not use it (empty = it may). Call after hub.conf is read.
# Fails closed: only owner_only 0 opens a provider to client hubs; a missing value counts as owner-only.
provider_hub_refusal() {
  local o; o="$(provider_field "$1" owner_only)"
  [ "$o" = 0 ] || [ "${HUB_OWNED_BY_OWNER:-}" = 1 ] && return 0
  if [ "$1" = gemini ]; then
    [ "${HUB_GEMINI_CLIENT_APPROVED:-}" = 1 ] && return 0
    echo "gemini runs only in the owner's own hubs (HUB_OWNED_BY_OWNER=1), or in a client hub whose client approved it (HUB_GEMINI_CLIENT_APPROVED=1 in hub.conf): Google's unpaid API and free-login terms let it use prompts and code to improve its products (ADR 0002)"
  elif [ "$o" = 1 ]; then
    echo "$1 is only for the owner's own hubs (HUB_OWNED_BY_OWNER=1 in hub.conf): its terms allow training on API data and store it in the People's Republic of China (ADR 0002)"
  else
    echo "$1 has no owner_only value in bin/lib.sh, so it is refused outside the owner's own hubs (HUB_OWNED_BY_OWNER=1 in hub.conf, ADR 0002)"
  fi
}
# provider_scrub_vars: names that beat apiKeyHelper or switch Claude Code to another backend (auth order:
# ANTHROPIC_AUTH_TOKEN > ANTHROPIC_API_KEY > apiKeyHelper > OAuth). A provider session never passes them on.
provider_scrub_vars() { echo "ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY ANTHROPIC_CUSTOM_HEADERS CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY CLAUDE_CODE_OAUTH_TOKEN"; }
# Shared by bin/work --provider and bin/agent, so a provider run has one set of checks and one settings format.
provider_sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
# provider_models <provider>: the model names it accepts, space-separated
provider_models() { printf 'opus sonnet haiku %s' "$(local s; for s in model opus sonnet haiku small; do provider_field "$1" "$s"; done | sort -u | tr '\n' ' ')"; }
# the hub.conf names of a provider's main and small-fast slot overrides
provider_model_var() { printf 'HUB_%s_MODEL' "$(printf '%s' "$1" | tr 'a-z-' 'A-Z_')"; }
provider_small_var() { printf 'HUB_%s_SMALL_MODEL' "$(printf '%s' "$1" | tr 'a-z-' 'A-Z_')"; }
# Each *_refusal prints why the run may not go ahead (empty = it may).
provider_conf_models_refusal() {
  local v; for v in "$(provider_model_var "$1")" "$(provider_small_var "$1")"; do
    [ -z "${!v:-}" ] || provider_model_ok "$1" "${!v}" || { echo "$v=${!v} in hub.conf is not a $1 model ($(provider_models "$1"))"; return 0; }
  done
}
# HUB (environment) picks the hub every helper reads; a provider run only starts from the hub this script is in
provider_own_hub_refusal() {
  local own; own="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
  [ -z "${HUB:-}" ] || [ "$(cd "$HUB" 2>/dev/null && pwd -P)" = "$own" ] ||
    echo "HUB=$HUB is not this script's hub ($own); a provider session runs only from its own hub"
}
# the provider config dir stays inside the hub: never a symlink out to ~/.claude or anywhere else
provider_config_refusal() {
  local H p r rl; H="$(hub_root)"; rl="$(cd "$H" && pwd -P)/.local"
  for p in "$H/.local" "$H/.local/providers/$1" "$H/.local/providers/$1/projects"; do
    r="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$p")"
    case "$r" in "$rl"|"$rl"/*) ;; *) echo "$p resolves to $r, outside $H/.local; a provider config dir stays in the hub"; return 0 ;; esac
  done
}
# checkout_gate_vars: hub switches a checkout's settings may never set either (story V1): they would move the secret store
# or the platform the session's hooks run on
checkout_gate_vars() { echo "AGENT_PLATFORM AGENT_PLATFORM_TEST AGENT_SECRETS_DIR PASSWORD_STORE_DIR HUB_SECRET_STORE"; }
# provider_checkout_refusal <provider> <dir>: the checkout's own settings load below nothing that can unset a key: an
# Anthropic credential or a backend switch in their env would beat apiKeyHelper and go to the provider (names only, never values)
provider_checkout_refusal() {
  local why; why="$(WORK_SCRUB="$(provider_scrub_vars) $(checkout_gate_vars)" python3 - "$2/.claude/settings.json" "$2/.claude/settings.local.json" <<'PY'
import json, os, sys
bad = os.environ["WORK_SCRUB"].split()
for p in sys.argv[1:]:
    if not os.path.exists(p): continue
    try: env = (json.load(open(p)) or {}).get("env") or {}
    except Exception: print("%s is not readable JSON" % p); continue
    hit = [k for k in bad if k in env]
    if hit: print("%s sets %s in its env" % (p, " ".join(hit)))
PY
)" || why="the checkout's settings could not be checked"
  [ -z "$why" ] || echo "$why; a provider session would send that to $1 instead of its key (remove it, or run without --provider)"
}
# provider_key_ok <provider>: fail closed, since Claude Code without a key sends the Anthropic login to the provider.
# The key is read once into a subshell variable, checked and dropped; it is never printed, written or passed on.
provider_key_ok() {
  local H s v; H="$(hub_root)"; s="$(provider_field "$1" secret)"; v="$(keychain_service)"
  ( key="$(HUB="$H" AGENT_KEYCHAIN_SERVICE="$v" "$H/bin/secret" "$s" 2>/dev/null)" && [ -n "$key" ]; r=$?; unset key; exit "$r" )
}
# provider_settings_write <src json> <dst> <provider> <main model id> <small model id>: src plus the provider layer, whose
# env wins; never a key value. The helper pins the hub and Keychain service the key check used; src's credentials and
# switches are dropped.
provider_settings_write() {
  local H p="$3"; H="$(hub_root)"
  WORK_PENV="ANTHROPIC_BASE_URL=$(provider_field "$p" base_url)
ANTHROPIC_MODEL=$4
ANTHROPIC_DEFAULT_OPUS_MODEL=$(provider_field "$p" opus)
ANTHROPIC_DEFAULT_SONNET_MODEL=$(provider_field "$p" sonnet)
ANTHROPIC_DEFAULT_HAIKU_MODEL=$(provider_field "$p" haiku)
ANTHROPIC_SMALL_FAST_MODEL=$5
CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1" WORK_SCRUB="$(provider_scrub_vars)" python3 - "$1" "$2" "HUB=$(provider_sq "$H") AGENT_KEYCHAIN_SERVICE=$(provider_sq "$(keychain_service)") $(provider_sq "$H/bin/secret") $(provider_field "$p" secret)" <<'PY'
import json, os, sys
src, dst, helper = sys.argv[1:4]
s = json.load(open(src))
env = dict(s.get("env") or {})
env.pop("CLAUDE_CODE_SUBAGENT_MODEL", None)   # agents' own model: values resolve through the slots
for k in os.environ["WORK_SCRUB"].split(): env.pop(k, None)
for l in os.environ["WORK_PENV"].splitlines():
    k, _, v = l.partition("="); env[k] = v
s["env"] = env; s["apiKeyHelper"] = helper; s["skipWebFetchPreflight"] = True
json.dump(s, open(dst, "w"), indent=2)
PY
}
# Engines (story E1; contract .ade/context/engines.md "Gemini CLI engine", ADR 0002): the CLI a role entry runs in.
# claude = Claude Code (anthropic and every provider row with a base_url); gemini = the Gemini CLI, signed in with its
# own Google login or a stored Gemini API key. A gemini session never gets a Claude Code flag, and never yolo.
# The hub's restrictions reach the CLI two ways it honours as a normal user (checked with the real CLI 0.67.0, offline):
# a user settings layer in a hub-owned GEMINI_CLI_HOME, and an --admin-policy file. Never the system-settings slot: the
# CLI skips a GEMINI_CLI_SYSTEM_SETTINGS_PATH file that is not owned by root.
engines() { echo "claude gemini"; }
engine_of() { case "$1" in gemini) echo gemini ;; *) echo claude ;; esac; }
gemini_cmd() { echo gemini; }
gemini_model_ok() { [[ "$1" =~ ^gemini-[A-Za-z0-9._-]+$ ]]; }
# gemini_home <google|key>: the CLI's home for that sign-in (GEMINI_CLI_HOME; it keeps .gemini/ there), inside the hub
gemini_home() { echo "$(hub_root)/.local/engines/gemini-$1"; }
# the Gemini CLI's credential, backend, trust and settings-path switches. bin/gemini-run sets each one to empty (a .env
# file never overrides a variable that is set), then sets its own; the settings paths are removed instead.
gemini_scrub_vars() { echo "GEMINI_API_KEY GOOGLE_API_KEY GOOGLE_GENAI_USE_VERTEXAI GOOGLE_GENAI_USE_GCA GOOGLE_APPLICATION_CREDENTIALS GOOGLE_GEMINI_BASE_URL GOOGLE_VERTEX_BASE_URL GOOGLE_CLOUD_PROJECT GOOGLE_CLOUD_LOCATION GEMINI_CLI_TRUST_WORKSPACE GEMINI_CLI_TRUSTED_FOLDERS_PATH GEMINI_MODEL"; }
gemini_unset_vars() { echo "GEMINI_CLI_SYSTEM_SETTINGS_PATH GEMINI_CLI_SYSTEM_DEFAULTS_PATH GEMINI_CLI_HOME"; }
# gemini_yolo_refusal <args...>: the CLI's approve-everything mode, in any spelling (-y, --yolo, --approval-mode or
# --approvalMode, as yolo or =yolo, in any letter case, -y among combined short flags), is refused like
# --dangerously-skip-permissions. The value after an option that takes one (a prompt, a model) is not a flag.
# Prints the reason, empty = none.
gemini_yolo_refusal() {
  local a l p="" why=""
  for a in "$@"; do
    l="$(printf '%s' "$a" | tr 'A-Z' 'a-z')"
    case "$p" in -m|--model|-p|--prompt|-i|--prompt-interactive|-o|--output-format|-e|--extensions|--allowed-mcp-server-names|--include-directories|--policy|--admin-policy) p=""; continue ;;
      --approval-mode|--approvalmode) [ "$l" != yolo ] || why="$p yolo"; p=""; [ -z "$why" ] || break; continue ;; esac
    case "$l" in -y|--yolo|--yolo=*|--approval-mode=yolo|--approvalmode=yolo) why="$a"; break ;; --*) ;; -*y*) why="$a"; break ;; esac
    p="$l"
  done
  [ -z "$why" ] || echo "yolo mode ($why) is never allowed: every tool call would run unapproved"
}
# gemini_checkout_refusal <dir>: the checkout's own Gemini configuration is never loaded: any .gemini/settings.json (it
# could set a discovery or call command, hooks, MCP servers, security settings or yolo), .gemini/hooks, .gemini/policies,
# .gemini/.env (loaded even with ignoreLocalEnv). Names only, never contents. Empty = none.
gemini_checkout_refusal() {
  local f; for f in settings.json hooks policies .env; do
    [ ! -e "$1/.gemini/$f" ] || { echo "$1/.gemini/$f exists: the Gemini CLI would load the checkout's own configuration (commands, hooks, MCP servers, keys or yolo); a hub session runs without it, so remove or move it"; return 0; }
  done
}
# gemini_admin_policy_dir: the CLI's standard admin policy folder. Any .toml there makes the CLI ignore --admin-policy,
# so the hub's policy would not apply: refused (gemini_system_refusal).
gemini_admin_policy_dir() { if [ "$(uname -s 2>/dev/null)" = Darwin ]; then echo "/Library/Application Support/GeminiCli/policies"; else echo /etc/gemini-cli/policies; fi; }
gemini_system_refusal() {
  local d; d="${AGENT_GEMINI_ADMIN_POLICY_DIR:-$(gemini_admin_policy_dir)}"
  ls "$d"/*.toml >/dev/null 2>&1 && echo "$d holds admin policies, so the Gemini CLI would ignore the hub's --admin-policy; the hub does not run Gemini on this machine"
  return 0
}
# gemini_auth [has|read]: how the CLI is signed in: "google" (its own Google login, cached in the hub's google home,
# gemini_home google), else "key" (a stored gemini-api-key; "read" also reads it once and drops it), else nothing
# (exit 1). The login is judged in the same home the CLI gets; another home's login (~/.gemini) does not count.
gemini_auth() {
  local H v; H="$(hub_root)"; v="$(keychain_service)"
  [ -s "$(gemini_home google)/.gemini/oauth_creds.json" ] && { echo google; return 0; }
  if [ "${1:-has}" = read ]; then
    ( key="$(HUB="$H" AGENT_KEYCHAIN_SERVICE="$v" "$H/bin/secret" gemini-api-key 2>/dev/null)" && [ -n "$key" ]; r=$?; unset key; exit "$r" ) || return 1
  else HUB="$H" AGENT_KEYCHAIN_SERVICE="$v" "$H/bin/secret" --has gemini-api-key || return 1; fi
  echo key
}
gemini_auth_hint() { echo "no Gemini sign-in and no Gemini API key: sign in once with GEMINI_CLI_HOME='$(gemini_home google)' gemini (Sign in with Google), or store a key with: bin/keys set gemini"; }
# gemini_settings_write <home> <google|key>: the hub's user settings layer, <home>/.gemini/settings.json (written whole,
# through a temp file). Never a key.
gemini_settings_write() {
  mkdir -p "$1/.gemini" && chmod 700 "$1" "$1/.gemini" || return 1
  python3 -c '
import json, os, sys
home, auth = sys.argv[1:3]
t = "oauth-personal" if auth == "google" else "gemini-api-key"
s = {
    "security": {"disableYoloMode": True, "auth": {"selectedType": t, "enforcedType": t}, "folderTrust": {"enabled": True},
                 "environmentVariableRedaction": {"enabled": True, "blocked": ["GEMINI_API_KEY", "GOOGLE_API_KEY", "GOOGLE_APPLICATION_CREDENTIALS"]}},
    "context": {"fileName": ["AGENTS.md", "CLAUDE.md", "GEMINI.md"]},
    "advanced": {"ignoreLocalEnv": True},
    "tools": {"discoveryCommand": "", "callCommand": ""},
    "hooksConfig": {"enabled": False},
    "mcpServers": {},
    "privacy": {"usageStatisticsEnabled": False},
    "general": {"enableAutoUpdate": False, "enableAutoUpdateNotification": False},
}
p = os.path.join(home, ".gemini", "settings.json"); tmp = "%s.%d" % (p, os.getpid())
with open(tmp, "w") as f: json.dump(s, f, indent=2)
os.replace(tmp, p)
' "$1" "$2"
}
# gemini_policy_write <file> <focus|agent>: the hub's --admin-policy (TOML, Admin tier, above any user rule). Both: the
# secret files a Claude path run may not read (the same names) are denied to the read tools and the shell, and every tool
# asks in yolo mode. agent: everything is denied but the read tools. Never a key.
gemini_policy_write() {
  python3 -c '
import os, sys
dst, kind = sys.argv[1:3]
q = chr(39)   # TOML literal strings: backslashes stay as written. No nested quantifiers: the CLI skips such a rule.
b = "[/\" ]"; e = "(?:[\" ]|$)"
names = "(?:%s\\.env(?:[\". /]|$)|\\.pem%s|\\.key%s|%sid_rsa|%s\\.npmrc%s|%s\\.netrc%s|%scredentials)" % (b, e, e, b, b, e, b, e, b)
dirs = "%s(?:\\.ssh|\\.aws|secrets)(?:[/\" ]|$)" % b
tools = "[\"read_file\", \"read_many_files\", \"glob\", \"grep_search\", \"list_directory\", \"run_shell_command\"]"
out = []
out.append("# the hub policy (bin/lib.sh gemini_policy_write); written for every run\n")
out.append("[[rule]]\ntoolName = %s\nargsPattern = %s\ndecision = \"deny\"\npriority = 999\ndenyMessage = \"hub: a secret file (.env, *.pem, *.key, id_rsa*, .npmrc, .netrc, credentials*)\"\n" % (tools, q + names + q))
out.append("[[rule]]\ntoolName = %s\nargsPattern = %s\ndecision = \"deny\"\npriority = 999\ndenyMessage = \"hub: a secret folder (.ssh, .aws, secrets)\"\n" % (tools, q + dirs + q))
out.append("[[rule]]\ntoolName = \"*\"\ndecision = \"ask_user\"\nmodes = [\"yolo\"]\npriority = 500\n")
if kind == "agent":
    out.append("[[rule]]\ntoolName = \"*\"\ndecision = \"deny\"\npriority = 100\ndenyMessage = \"hub: a delegated run is read-only\"\n")
    out.append("[[rule]]\ntoolName = [\"read_file\", \"read_many_files\", \"glob\", \"grep_search\", \"list_directory\"]\ndecision = \"allow\"\npriority = 200\n")
tmp = "%s.%d" % (dst, os.getpid())
with open(tmp, "w") as f: f.write("\n".join(out))
os.replace(tmp, dst)
' "$1" "$2"
}
# AI tools whose key bin/keys manages. A tool here need not be connected yet: a stored key enables nothing.
key_tools() { echo "anthropic deepseek glm muse gemini telegram"; }
key_secret() { case "$1" in anthropic) echo "anthropic-api-key" ;; deepseek|glm) provider_field "$1" secret ;; muse) echo "meta-model-api-key" ;; gemini) echo "gemini-api-key" ;; telegram) channel_secret telegram ;; *) return 1 ;; esac; }
key_source() { case "$1" in anthropic) echo "console.anthropic.com" ;; deepseek) echo "platform.deepseek.com" ;; glm) echo "z.ai" ;; muse) echo "dev.meta.ai" ;; gemini) echo "aistudio.google.com" ;; telegram) echo "@BotFather in Telegram" ;; *) return 1 ;; esac; }
# anthropic_settings_write <dst>: the settings of an Anthropic run with a stored API key (story H1): Claude Code reads the
# key through apiKeyHelper (bin/secret anthropic-api-key, the hub and Keychain service pinned), never an environment variable
anthropic_settings_write() {
  local H; H="$(hub_root)"
  python3 -c 'import json, sys; json.dump({"apiKeyHelper": sys.argv[2]}, open(sys.argv[1], "w"), indent=2)' "$1" \
    "HUB=$(provider_sq "$H") AGENT_KEYCHAIN_SERVICE=$(provider_sq "$(keychain_service)") $(provider_sq "$H/bin/secret") $(key_secret anthropic)"
}
# anthropic_key_ok: the stored Anthropic API key can be read and is not empty (read once, in a subshell, never printed)
anthropic_key_ok() { local H; H="$(hub_root)"
  ( key="$(HUB="$H" AGENT_KEYCHAIN_SERVICE="$(keychain_service)" "$H/bin/secret" "$(key_secret anthropic)" 2>/dev/null)" && [ -n "$key" ]; r=$?; unset key; exit "$r" ); }
# redact: stdin to stdout with escape sequences and control characters removed, then bot tokens, GLM-style keys,
# key-shaped strings and long opaque runs hidden (the patterns live in agent.py, the live test's printer)
redact() { python3 -I "$(dirname "${BASH_SOURCE[0]}")/agent.py" --redact; }
# anthropic_model_ok <model>: an Anthropic model name a role or a live test may use
anthropic_model_ok() { local am='^((opus|sonnet|haiku)(\[1m\])?|claude-[A-Za-z0-9._-]+(\[1m\])?)$'; [[ "$1" =~ $am ]]; }
# Chat channels (story C5, ADR 0006, .ade/context/chat.md): each type's plugin, Keychain secret, the variable the
# plugin reads its token from, and the variable that moves its state folder (bot token, access.json, inbox).
channel_types() { echo "telegram"; }
channel_plugin() { case "$1" in telegram) echo "plugin:telegram@claude-plugins-official" ;; *) return 1 ;; esac; }
channel_secret() { case "$1" in telegram) echo "telegram-bot-token" ;; *) return 1 ;; esac; }
channel_token_env() { case "$1" in telegram) echo "TELEGRAM_BOT_TOKEN" ;; *) return 1 ;; esac; }
# hub_name_claim: this hub owns its name on this machine (the state folder, Keychain service and launchd labels all
# derive from it). The first hub to claim it is recorded in <state dir>/hub-path; a different hub that still exists
# there makes this print that hub's path and return 1 (two folders both named "hub": set HUB_NAME in one of them).
hub_name_claim() { local f me o; f="$(state_dir)/hub-path"; me="$(cd "$(hub_root)" && pwd -P)" || return 0
  mkdir -p "$(state_dir)" || return 0
  if [ -f "$f" ]; then o="$(cat "$f")"; [ "$o" = "$me" ] && return 0; [ -d "$o" ] && { echo "$o"; return 1; }; fi
  echo "$me" > "$f"; }
channel_state_env() { case "$1" in telegram) echo "TELEGRAM_STATE_DIR" ;; *) return 1 ;; esac; }
# channel_buttons <type>: which messages may carry inline buttons (story C7). telegram: "permission" (the plugin shows
# Allow / Deny buttons on Claude Code's permission prompts itself; its reply tool sends none, so bin/chat ask uses
# numbered replies). "all" lets bin/chat ask send Approve / Deny buttons.
channel_buttons() { case "$1" in telegram) echo "permission" ;; *) return 1 ;; esac; }
# Role routing (.ade/context/providers.md, "Roles"): a role is an ordered list of provider:model candidates. Defaults
# here; HUB_ROLE_<ROLE> in hub.conf (never the environment) replaces a role's list or adds a role.
role_default() { case "$1" in
  architect|builder) echo "anthropic:opus" ;;
  routine) echo "anthropic:sonnet deepseek:sonnet" ;;
  triage) echo "anthropic:haiku deepseek:haiku" ;;
  reviewer) echo "deepseek:sonnet anthropic:sonnet" ;;
  *) return 1 ;; esac; }
role_var() { printf 'HUB_ROLE_%s' "$(printf '%s' "$1" | tr 'a-z-' 'A-Z_')"; }
roles() { { printf '%s\n' routine triage reviewer architect builder
  local v; for v in $(compgen -v HUB_ROLE_); do [[ "$v" =~ ^HUB_ROLE_[A-Z0-9_]+$ ]] && printf '%s\n' "${v#HUB_ROLE_}" | tr 'A-Z_' 'a-z-'; done; } | awk '!seen[$0]++'; }
# role_candidates <role>: one provider:model per line. Exit 2, with the reason on stderr, for an unknown role or any bad
# entry, so a typo stops the run instead of quietly changing where the work goes.
role_candidates() {
  local r="$1" v c n=0 list am='^((opus|sonnet|haiku)(\[1m\])?|claude-[A-Za-z0-9._-]+(\[1m\])?)$'
  { [[ "$r" =~ ^[a-z0-9-]+$ ]] && roles | grep -qx -- "$r"; } || { echo "unknown role '$r' (roles: $(roles | tr '\n' ' '))" >&2; return 2; }
  v="$(role_var "$r")"; if [ -n "${!v+x}" ]; then list="${!v}"; else list="$(role_default "$r")"; fi
  for c in $list; do
    [[ "$c" =~ ^[a-z0-9-]+:[][A-Za-z0-9._:/-]+$ ]] || { echo "role $r: bad entry '$c' (want provider:model)" >&2; return 2; }
    if [ "${c%%:*}" = anthropic ]; then [[ "${c#*:}" =~ $am ]] || { echo "role $r: '$c' is not an Anthropic model (opus, sonnet, haiku, optional [1m], or claude-*)" >&2; return 2; }
    elif [ "${c%%:*}" = gemini ]; then gemini_model_ok "${c#*:}" || { echo "role $r: '$c' is not a Gemini model (gemini-*)" >&2; return 2; }
    else provider_field "${c%%:*}" base_url >/dev/null || { echo "role $r: no provider '${c%%:*}' in bin/lib.sh ('$c')" >&2; return 2; }; fi
    n=$((n + 1))
  done
  [ "$n" -gt 0 ] || { echo "role $r: no candidates" >&2; return 2; }
  printf '%s\n' $list
}
# candidate_refusal <provider:model> [checkout dir] [has|read]: why this hub may not use it (empty = it may): every check
# bin/work --provider makes, for delegation. "has" asks only whether the key is stored; "read" (just before a run) reads it.
candidate_refusal() {
  local p="${1%%:*}" m="${1#*:}" dir="${2:-}" mode="${3:-has}" why
  case " ${HUB_PROVIDERS_ALLOWED:-anthropic} " in *" $p "*) ;; *) echo "$p is not in HUB_PROVIDERS_ALLOWED (hub.conf)"; return 0 ;; esac
  [ "$p" != anthropic ] || return 0
  if [ "$p" = gemini ]; then   # the Gemini CLI engine (E1): no Claude Code, so its own checks
    why="$(provider_hub_refusal gemini)"; [ -z "$why" ] || { echo "$why"; return 0; }
    why="$(provider_own_hub_refusal)"; [ -z "$why" ] || { echo "$why"; return 0; }
    provider_feature_go gemini delegation || { provider_no_go_reason gemini delegation; return 0; }
    gemini_model_ok "$m" || { echo "$m is not a Gemini model (gemini-*)"; return 0; }
    command -v "$(gemini_cmd)" >/dev/null 2>&1 || { echo "the Gemini CLI ($(gemini_cmd)) is not installed"; return 0; }
    why="$(gemini_system_refusal)"; [ -z "$why" ] || { echo "$why"; return 0; }
    if [ -n "$dir" ]; then why="$(gemini_checkout_refusal "$dir")"; [ -z "$why" ] || { echo "$why"; return 0; }; fi
    gemini_auth "$mode" >/dev/null || gemini_auth_hint
    return 0
  fi
  provider_field "$p" base_url >/dev/null || { echo "no provider '$p' in bin/lib.sh"; return 0; }
  why="$(provider_hub_refusal "$p")"; [ -z "$why" ] || { echo "$why"; return 0; }
  why="$(provider_own_hub_refusal)"; [ -z "$why" ] || { echo "$why"; return 0; }
  [ "$(claude_cmd)" = claude ] || { echo "$p needs plain claude, not '$(claude_cmd)' (a wrapper could send the run elsewhere)"; return 0; }
  provider_feature_go "$p" delegation || { provider_no_go_reason "$p" delegation; return 0; }
  provider_model_ok "$p" "$m" || { echo "$m is not a $p model ($(provider_models "$p"))"; return 0; }
  why="$(provider_conf_models_refusal "$p")"; [ -z "$why" ] || { echo "$why"; return 0; }
  why="$(provider_config_refusal "$p")"; [ -z "$why" ] || { echo "$why"; return 0; }
  if [ -n "$dir" ]; then why="$(provider_checkout_refusal "$p" "$dir")"; [ -z "$why" ] || { echo "$why"; return 0; }; fi
  local s; s="$(provider_field "$p" secret)"
  if [ "$mode" = read ]; then provider_key_ok "$p" || echo "no $(provider_field "$p" label) in the Keychain; store it with: bin/secret --set $s"
  else "$(hub_root)/bin/secret" --has "$s" || echo "no $(provider_field "$p" label) in the Keychain; store it with: bin/secret --set $s"; fi
}
# role_pick <role> [checkout dir] [has|read]: sets ROLE_PICK to the first usable candidate and ROLE_SKIPS to one
# "skipped <candidate>: <why>" line per candidate before it. 0 = picked, 1 = none usable, 2 = bad role or table.
role_pick() {
  local cs c why; ROLE_PICK=""; ROLE_SKIPS=""; cs="$(role_candidates "$1")" || return 2
  for c in $cs; do
    why="$(candidate_refusal "$c" "${2:-}" "${3:-has}")"
    [ -n "$why" ] || { ROLE_PICK="$c"; return 0; }
    ROLE_SKIPS="${ROLE_SKIPS}skipped $c: $why"$'\n'
  done
  return 1
}
# orchestrator_endpoint_warning: the hub-root session stays on Anthropic (ADR 0002). Prints a warning when
# ANTHROPIC_BASE_URL points at another host. A focus session (AGENT_FOLDER) may run on a provider. Only the host is shown.
orchestrator_endpoint_warning() {
  local h="${ANTHROPIC_BASE_URL:-}"; [ -n "$h" ] && [ -z "${AGENT_FOLDER:-}" ] || return 0
  h="${h#*://}"; h="${h%%[/?#]*}"; h="${h##*@}"; h="${h%%:*}"; h="$(printf '%s' "$h" | tr 'A-Z' 'a-z')"
  case "$h" in anthropic.com|*.anthropic.com) return 0 ;; esac
  echo "ANTHROPIC_BASE_URL points at $h: the hub-root orchestrator runs on Anthropic only (ADR 0002); use bin/agent --role for other providers"
}
# the method (story C1, .ade/context/method.md): ade-method is its only home. method_pin is the tag this template pins
# (bin/init writes it as HUB_METHOD_REF); method_repo is where bin/method fetches it (AGENT_METHOD_REPO: tests' fixture)
method_pin() { echo v2.1.0; }
method_repo() { echo "${AGENT_METHOD_REPO:-https://github.com/better-ade/ade-method}"; }
# hub.conf (written by bin/init): who this agent is and what it can reach. Names and locations only, never secrets.
# AGENT_* environment variables override it (tests use them). Provider choice, role tables, hub ownership and HUB_AGENT_ANTHROPIC_KEY come only from hub.conf.
unset HUB_PROVIDER HUB_PROVIDERS_ALLOWED HUB_OWNED_BY_OWNER HUB_GEMINI_CLIENT_APPROVED HUB_AGENT_ANTHROPIC_KEY HUB_SECRET_STORE
for _v in $(compgen -v HUB_ROLE_); do unset "$_v"; done; unset _v   # role tables too
[ -f "$(hub_root)/hub.conf" ] && . "$(hub_root)/hub.conf"
hub_name() { echo "${HUB_NAME:-$(basename "$(hub_root)")}"; }
hub_owner() { echo "${HUB_OWNER:-the hub owner}"; }
persona_title() { echo "${HUB_PERSONA_TITLE:-technical agent}"; }
code_owner() { echo "${AGENT_CODE_OWNER:-${HUB_CODE_OWNER:-}}"; }
# The remote box (staging server, VM) reached by bin/remote; empty host = none configured.
remote_host() { echo "${AGENT_REMOTE_HOST:-${HUB_REMOTE_HOST:-}}"; }
remote_user() { echo "${AGENT_REMOTE_USER:-${HUB_REMOTE_USER:-}}"; }
remote_port() { echo "${AGENT_REMOTE_PORT:-${HUB_REMOTE_PORT:-22}}"; }
remote_key() { echo "${AGENT_REMOTE_KEY:-${HUB_REMOTE_KEY:-}}"; }
remote_dir() { echo "${AGENT_REMOTE_DIR:-${HUB_REMOTE_DIR:-}}"; }
remote_target() { local u; u="$(remote_user)"; echo "${u:+$u@}$(remote_host)"; }
staging_url() { echo "${AGENT_STAGING_URL:-${HUB_STAGING_URL:-}}"; }
keychain_service() { echo "${AGENT_KEYCHAIN_SERVICE:-${HUB_KEYCHAIN_SERVICE:-$(hub_name)}}"; }
# The sync lock: one bin/sync --yes/--auto run or session-end commit at a time. A directory holding its owner's pid.
sync_lock_path() { echo "${AGENT_SYNC_LOCK:-$(state_dir)/sync.lock}"; }
# seconds bin/sync --yes and bin/session-end --since wait for a busy lock (--auto never waits)
sync_lock_wait() { echo "${AGENT_LOCK_WAIT:-30}"; }
# seconds the SessionEnd hook path (bin/session-end without --since) waits for a busy lock
sync_hook_lock_wait() { echo "${AGENT_HOOK_LOCK_WAIT:-5}"; }
# seconds a lock without a usable pid file is kept (its taker may not have written the pid yet); fixed
sync_lock_grace() { echo 10; }
# proc_start <pid>: the process's start time (ps lstart in UTC and the C locale, so every taker and judge print the same
# string whatever their TZ or locale; spaces collapsed); nothing when there is no such process
proc_start() { TZ=UTC LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null | head -1 | tr -s ' ' | sed 's/^ //; s/ $//'; }
# sync_lock_take <lock> <wait-secs> [log-cmd]: take the lock, trying once a second; a busy lock is retried <wait-secs>
# times after the first try (attempts are counted, so the wait is at least <wait-secs> seconds).
# The lock holds <lock>/start (`<pid> <start time>`, written first; left out when ps gives no start time) and
# <lock>/pid. It is stale only when its owner is gone: the pid names no process, or a process that started at another
# time than the start record says (the pid was reused), or there is no usable pid and the lock is older than
# sync_lock_grace seconds. A live owner's lock is kept however old. A stale lock is removed and
# `<log-cmd> removed stale lock` runs.
# Returns 0 holding the lock (pid file = $$), 1 when a live owner still holds it.
sync_lock_take() {
  local k="$1" w="${2:-0}" lg="${3:-:}" n=0 t; mkdir -p "$(dirname "$k")" 2>/dev/null
  while :; do
    if mkdir "$k" 2>/dev/null; then
      t=$(proc_start $$); [ -z "$t" ] || echo "$$ $t" > "$k/start"
      echo $$ > "$k/pid"; return 0
    fi
    _sync_lock_reap "$k" "$lg" && continue
    [ "$n" -lt "$w" ] || return 1
    n=$((n + 1)); sleep 1
  done
}
# _sync_lock_stale <lock>: 0 = stale (the owner rule above). ps -p, not kill -0: kill -0 fails for another user's live
# process. A start record naming another pid than the pid file, or with no start, leaves the lock judged by pid alone.
_sync_lock_stale() {
  local op rec m live
  op=$(cat "$1/pid" 2>/dev/null)
  case "$op" in
    ""|*[!0-9]*)
      m=$(file_mtime "$1"); [ -n "$m" ] || return 1
      [ $(( $(command date +%s) - m )) -gt "$(sync_lock_grace)" ]; return ;;
  esac
  ps -p "$op" >/dev/null 2>&1 || return 0
  rec=$(head -1 "$1/start" 2>/dev/null)
  case "$rec" in "$op "?*) rec="${rec#"$op "}" ;; *) return 1 ;; esac
  live=$(proc_start "$op")
  [ -n "$live" ] && [ "$live" != "$rec" ]
}
# _sync_lock_reap <lock> <log-cmd>: removes <lock> if it is stale; 0 = removed. Only one taker at a time may judge and
# remove (the guard <lock>.gc, a mkdir), and the lock is judged again inside the guard, so two takers that both saw the
# same stale lock cannot remove the lock one of them has just taken. The judged directory is moved aside and removed
# only if it is still the one judged (same inode); otherwise it is put back and the lock counts as busy.
# A guard left by a killed run expires after a minute.
_sync_lock_reap() {
  local k="$1" g="$1.gc" s="$1.stale.$$" i r=1
  _sync_lock_stale "$k" || return 1
  [ -n "$(find "$g" -maxdepth 0 -mmin +1 2>/dev/null)" ] && rm -rf "$g"
  mkdir "$g" 2>/dev/null || return 1
  i=$(file_inode "$k")
  if [ -n "$i" ] && _sync_lock_stale "$k"; then
    rm -rf "$s"
    if mv "$k" "$s" 2>/dev/null; then
      if [ "$(file_inode "$s")" = "$i" ]; then rm -rf "$s"; "$lg" "removed stale lock"; r=0
      else [ -e "$k" ] || mv "$s" "$k" 2>/dev/null; rm -rf "$s"; fi
    fi
  fi
  rmdir "$g" 2>/dev/null
  return $r
}
# sync_lock_release <lock>: removes the lock only when this process owns it
sync_lock_release() { [ "$(cat "$1/pid" 2>/dev/null)" = "$$" ] && rm -rf "$1"; return 0; }
# The platform layer (story V1, .ade/context/platform.md): every macOS-only call in bin/ goes through here, so the same
# hub runs on macOS and on Linux (Ubuntu). AGENT_PLATFORM=macos|linux overrides the detection only with the test flag
# AGENT_PLATFORM_TEST=1 (tests/helpers.sh), so a stray variable never switches a real hub's secrets or scheduler.
platform() { case "${AGENT_PLATFORM:-}:${AGENT_PLATFORM_TEST:-}" in macos:1|linux:1) echo "$AGENT_PLATFORM"; return 0 ;; esac
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then echo macos; else echo linux; fi; }
# File times, inodes, modes and owners: GNU stat -c or BSD stat -f, whichever this stat is (a Mac may have GNU first).
if stat -c %Y / >/dev/null 2>&1; then _stat() { stat -c "$1" "$2"; }; _SF_M=%Y _SF_P=%a
else _stat() { stat -f "$1" "$2"; }; _SF_M=%m _SF_P=%Lp; fi
file_mtime() { _stat "$_SF_M" "$1" 2>/dev/null; }
file_inode() { _stat %i "$1" 2>/dev/null; }
file_mode() { _stat "$_SF_P" "$1" 2>/dev/null; }   # the permission bits in octal, e.g. 700
file_owner() { _stat %u "$1" 2>/dev/null; }
# file_low9 <path>: the low nine permission bits only (setgid, setuid and sticky left out), e.g. 700
file_low9() { local m; m="$(file_mode "$1")" || return 1; [ -n "$m" ] || return 1; printf '%o' "$(( 8#$m & 0777 ))"; }
# dir_loose <dir>: why a folder on a secret's path is unsafe (empty = it is not): writable by group or others without the
# sticky bit, or owned by someone other than this user or root
dir_loose() { local m o; m="$(file_mode "$1")" || return 0; [ -n "$m" ] || return 0; o="$(file_owner "$1")"
  [ "$o" = "$(id -u)" ] || [ "$o" = 0 ] || { echo "$1 is owned by uid $o, not you"; return 0; }
  [ $(( 8#$m & 022 )) = 0 ] || [ $(( 8#$m & 01000 )) != 0 ] || echo "$1 is writable by group or others (mode $m): chmod go-w $1"; }
# script(1) for a pseudo-terminal: util-linux takes the command as -c "<cmd>" before the file, BSD takes it after
script_is_util_linux() { script --version 2>/dev/null | grep -q util-linux; }
# utc_epoch <YYYY-MM-DDTHH:MM:SS>: that UTC time in seconds (GNU date -d or BSD date -j); nothing when unreadable
utc_epoch() { date -u -d "$1" +%s 2>/dev/null || date -j -u -f "%Y-%m-%dT%H:%M:%S" "$1" +%s 2>/dev/null; }
# Desktop notifications: macOS only (osascript); elsewhere nothing (bin/monitor writes an event instead).
desktop_notify() { [ "$(platform)" = macos ] || return 0
  osascript -e "display notification \"$(printf '%s' "$2" | tr -d '"\\')\" with title \"$(printf '%s' "$1" | tr -d '"\\')\"" 2>/dev/null; }
# terminal_window <terminal|iterm> <launcher>: a new macOS Terminal or iTerm window running the launcher.
terminal_window() {
  if [ "$1" = iterm ]; then osascript -e "tell application \"iTerm\" to create window with default profile command \"bash -l $2\""
  else osascript -e "tell application \"Terminal\" to do script \"bash -l $2\"" -e 'tell application "Terminal" to activate'; fi; }
# tmux: focus sessions on Linux, and with AGENT_TERMINAL=tmux anywhere (ade-cli's `ade ui` attaches to ade-<hub>).
# tmux turns . and : in a name into _, so names are made that way here, and targets are exact (=name).
tmux_name() { printf '%s' "$1" | tr '.:' '__'; }
tmux_hub_session() { echo "ade-$(tmux_name "$(hub_name)")"; }
# tmux_env: the env -i prefix a tmux session starts with: these variables only. A tmux server keeps the environment it
# was started with, so a focus session never takes a caller's credentials or switches.
tmux_env() { local v o=""; for v in HOME PATH TERM LANG LC_ALL USER LOGNAME SHELL TMPDIR SSH_AUTH_SOCK XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS; do
    [ -n "${!v:-}" ] && o="$o $v=$(provider_sq "${!v}")"; done
  [ -n "${TERM:-}" ] || o="$o TERM=xterm-256color"; printf 'env -i%s' "$o"; }
# tmux_taken <name>: 0 when a tmux session <name>, or a window <name> in the hub's session, already exists
tmux_taken() { local n hs; n="$(tmux_name "$1")"; hs="$(tmux_hub_session)"
  tmux has-session -t "=$n" 2>/dev/null && return 0
  tmux has-session -t "=$hs" 2>/dev/null && tmux list-windows -t "=$hs" -F '#W' 2>/dev/null | grep -qxF -- "$n"; }
# tmux_open <name> <dir> <launcher>: a new window in session ade-<hub> when it exists (left in the background), else a
# detached session named <name>. Prints where it went: "window <hub session> <name>" or "session <name>".
tmux_open() { local n hs c; n="$(tmux_name "$1")"; hs="$(tmux_hub_session)"; c="$(tmux_env) bash -l $(printf "'%s'" "$(printf '%s' "$3" | sed "s/'/'\\\\''/g")")"
  if tmux has-session -t "=$hs" 2>/dev/null; then tmux new-window -d -t "=$hs:" -n "$n" -c "$2" "$c" && echo "window $hs $n"
  else tmux new-session -d -s "$n" -c "$2" "$c" && echo "session $n"; fi; }
# Scheduled jobs: launchd on macOS, systemd user units and timers on Linux (bin/schedule).
launchd_domain() { echo "gui/$(id -u)"; }
launchd_bootout() { launchctl bootout "$(launchd_domain)/$1" 2>/dev/null; }
launchd_bootstrap() { launchctl bootstrap "$(launchd_domain)" "$1"; }
launchd_loaded() { launchctl print "$(launchd_domain)/$1" >/dev/null 2>&1; }
launchd_enable() { launchctl enable "$(launchd_domain)/$1"; }
launchd_disable() { launchctl disable "$(launchd_domain)/$1" 2>/dev/null; }
# systemd_escape <text>: a value for a unit file (systemd expands % specifiers and $ variables)
systemd_escape() { printf '%s' "$1" | sed -e 's/%/%%/g' -e 's/\$/$$/g'; }
systemd_user_dir() { echo "${AGENT_SYSTEMD_USER_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user}"; }
systemd_user() { systemctl --user "$@"; }
# linger_on: user units run without a login session (a server); asks loginctl once
linger_on() { local u; u="$(id -un)"; loginctl show-user "$u" -p Linger 2>/dev/null | grep -qx 'Linger=yes' || loginctl enable-linger "$u"; }
# Secrets (bin/secret, bin/keys): HUB_SECRET_STORE in hub.conf (keychain|pass|file; never the environment), default
# keychain on macOS and file on Linux: the store never switches by itself when pass appears. The file store lives under
# ~/.config/ade/secrets/<service>/ (dirs 0700, files 0600, no loose parent up to $HOME; bin/doctor calls it the weaker
# store). A value only ever moves on stdin or in this shell's variables: never an argument of another program, the
# environment or a log.
secret_store() { case "${HUB_SECRET_STORE:-}" in
    "") if [ "$(platform)" = macos ]; then echo keychain; else echo file; fi ;;
    keychain|pass|file) echo "$HUB_SECRET_STORE" ;; *) echo invalid ;; esac; }
secret_store_label() { case "$(secret_store)" in keychain) echo "the Keychain" ;; pass) echo "pass" ;; file) echo "the file store ($(secret_file_root))" ;; *) echo "no store" ;; esac; }
pass_dir() { echo "${PASSWORD_STORE_DIR:-$HOME/.password-store}"; }
secret_file_root() { echo "${AGENT_SECRETS_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/ade/secrets}"; }
# secret_name_ok <name>: a store key, never a path
secret_name_ok() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; }
# secret_store_refusal: why the store cannot be used (empty = it can): no security on macOS; a file store folder that is
# not 0700 and the user's (it is made 0700 when missing); a service name that is not a plain name
secret_store_refusal() {
  local st d x why; st="$(secret_store)"
  case "$st" in
    invalid) echo "HUB_SECRET_STORE=${HUB_SECRET_STORE:-} in hub.conf: it must be keychain, pass or file"; return 0 ;;
    keychain) [ "$(platform)" = macos ] || { echo "HUB_SECRET_STORE=keychain: the Keychain is macOS only (use pass or file)"; return 0; }
      command -v security >/dev/null || echo "needs the macOS Keychain (the security command)"; return 0 ;;
    pass) command -v pass >/dev/null 2>&1 && [ -f "$(pass_dir)/.gpg-id" ] || { echo "HUB_SECRET_STORE=pass, but pass is not installed and initialised (pass init <gpg-id>)"; return 0; }
      secret_name_ok "$(keychain_service)" || echo "the service name '$(keychain_service)' is not a plain name"; return 0 ;;
  esac
  secret_name_ok "$(keychain_service)" || { echo "the service name '$(keychain_service)' is not a plain name"; return 0; }
  d="$(secret_file_root)"
  # every folder above the store, up to $HOME (or /): none writable by others, none owned by another user
  x="$(dirname "$d")"; while :; do why="$(dir_loose "$x")"; [ -z "$why" ] || { echo "$why; the file store refuses to run"; return 0; }
    { [ "$x" = "$HOME" ] || [ "$x" = / ] || [ "$x" = . ]; } && break; x="$(dirname "$x")"; done
  for x in "$d" "$d/$(keychain_service)"; do
    if [ ! -d "$x" ]; then ( umask 077; mkdir -p "$x" ) 2>/dev/null && chmod 0700 "$x" || { echo "cannot make $x"; return 0; }; fi
    [ "$(file_low9 "$x")" = 700 ] && [ "$(file_owner "$x")" = "$(id -u)" ] ||
      { echo "$x must be a 0700 folder of yours (it is $(file_mode "$x")); the file store refuses to run: chmod 00700 $x"; return 0; }
  done
}
_secret_path() { case "$(secret_store)" in pass) echo "ade/$(keychain_service)/$1" ;; file) echo "$(secret_file_root)/$(keychain_service)/$1" ;; esac; }
# secret_get <name>: the value on stdout; exit 1 when not stored (or, in the file store, when the file is not 0600)
secret_get() {
  local p v; p="$(_secret_path "$1")"
  case "$(secret_store)" in
    keychain) security find-generic-password -s "$(keychain_service)" -a "$1" -w 2>/dev/null ;;
    pass) v="$(pass show "$p" 2>/dev/null)" || return 1; printf '%s\n' "${v%%$'\n'*}" ;;
    file) [ -f "$p" ] || return 1
      [ "$(file_low9 "$p")" = 600 ] && [ "$(file_owner "$p")" = "$(id -u)" ] || { echo "secret: $p must be a 0600 file of yours: chmod 600 $p" >&2; return 1; }
      printf '%s\n' "$(cat "$p")" ;;
  esac
}
secret_has() {
  case "$(secret_store)" in
    keychain) security find-generic-password -s "$(keychain_service)" -a "$1" >/dev/null 2>&1 ;;
    pass) [ -f "$(pass_dir)/$(_secret_path "$1").gpg" ] ;;
    file) [ -f "$(_secret_path "$1")" ] ;;
  esac
}
# secret_put <name> <value>: store or replace (a shell function's argument: no process sees it), then read it back
secret_put() {
  local p t; p="$(_secret_path "$1")"
  case "$(secret_store)" in
    keychain) q() { local s="${1//\\/\\\\}"; printf '"%s"' "${s//\"/\\\"}"; }
      # on stdin (security -i), so the value is never in a process argument; read back, since -i can hide a failure
      printf 'add-generic-password -U -s %s -a %s -w %s\n' "$(q "$(keychain_service)")" "$(q "$1")" "$(q "$2")" | security -i >/dev/null 2>&1 ;;
    pass) printf '%s\n' "$2" | pass insert -m -f "$p" >/dev/null 2>&1 ;;
    file) t="$p.tmp.$$"; rm -f "$t"; ( set -C; umask 077; printf '%s' "$2" > "$t" ) 2>/dev/null && chmod 600 "$t" && mv -f "$t" "$p" || { rm -f "$t"; return 1; } ;;
  esac
  [ "$(secret_get "$1" 2>/dev/null)" = "$2" ]
}
secret_forget() {
  case "$(secret_store)" in
    keychain) security delete-generic-password -s "$(keychain_service)" -a "$1" >/dev/null 2>&1 ;;
    pass) secret_has "$1" && pass rm -f "$(_secret_path "$1")" >/dev/null 2>&1 ;;
    file) [ -f "$(_secret_path "$1")" ] && rm -f "$(_secret_path "$1")" ;;
  esac
}
# secret_names: the names stored for this hub's service (never values)
secret_names() {
  local d
  case "$(secret_store)" in
    keychain) security dump-keychain 2>/dev/null | awk -v s="$(keychain_service)" '/"svce"<blob>=/{x=($0 ~ "\"" s "\"")} x && /"acct"<blob>=/{gsub(/.*="|"$/,""); print; x=0}' | sort -u ;;
    pass) d="$(pass_dir)/ade/$(keychain_service)"; [ -d "$d" ] && for f in "$d"/*.gpg; do [ -f "$f" ] && basename "$f" .gpg; done | sort ;;
    file) d="$(secret_file_root)/$(keychain_service)"; [ -d "$d" ] && for f in "$d"/*; do [ -f "$f" ] && basename "$f"; done | grep -v '\.tmp\.[0-9]*$' | sort ;;
  esac
  return 0
}
