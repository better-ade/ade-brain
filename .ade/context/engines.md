# Engines and providers: S0 item 21 findings (2026-11-09)

Spike for story SP (`docs/stories/SP-providers.md`). No product code. Tested on **Claude Code 2.1.319** (macOS, native
install). DeepSeek was tested with the owner's key; GLM and Meta come from vendor docs only (no keys stored, no requests sent).

Method: every run used a fresh temp `CLAUDE_CONFIG_DIR`, `env -i` (no inherited shell variables), `DISABLE_AUTOUPDATER=1`,
`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`, and a throwaway directory holding only dummy files (`notes.txt`,
`secret.txt` = `DUMMY-NOT-A-SECRET`). Canary prompts only. The protocol checks used a local fake Anthropic-compatible
server (Python `http.server`), which logged the path, header names and a tag of the auth values. Only fake keys ever
reached it. The DeepSeek key was read only through `bin/secret` (`AGENT_KEYCHAIN_SERVICE=agent-hub-s0`). A grep of all
spike output for the key value found nothing.

## Go/no-go per provider per feature

| Provider | Focus session (`bin/work`) | `--agents` sub-agents | Delegation (headless `claude -p`) | Thinking/`--effort` | Remote Control |
|---|---|---|---|---|---|
| deepseek | **go** | **go** | **go** | **go** (accepted; see below) | no (not tested; off by rule) |
| glm | **no-go until tested** (z.ai documents Claude Code support; no key, so no canary run) | no-go until tested | no-go until tested | no-go until tested | no (off by rule) |
| meta | **no-go** (endpoint is official but never tested; likely rejects fields Claude Code sends, see Meta) | no-go | no-go | no-go | no (off by rule) |

Per SP AC18, the `meta` row does not ship in SP (no go). GLM ships only after the same canary runs with a z.ai key.

Tool restriction (AC19): none needed for DeepSeek.

## Recipe that worked (DeepSeek)

The provider layer is passed as the `--settings` file. The key comes from `apiKeyHelper` (credential option 1). There is
no key in the environment, the argv or any file.

```json
{
  "apiKeyHelper": "<hub>/bin/secret deepseek-api-key",
  "env": {
    "ANTHROPIC_BASE_URL": "https://api.deepseek.com/anthropic",
    "ANTHROPIC_MODEL": "deepseek-flash",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "deepseek-v4-pro",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "deepseek-flash",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "deepseek-flash",
    "ANTHROPIC_SMALL_FAST_MODEL": "deepseek-flash",
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"
  }
}
```

The spike's helper string was `AGENT_KEYCHAIN_SERVICE=agent-hub-s0 <repo>/bin/secret deepseek-api-key` (run by
`/bin/sh`). The init event reported `apiKeySource: apiKeyHelper`. `CLAUDE_CODE_SUBAGENT_MODEL` was not set, and the
sub-agent's `model: haiku` resolved through the slot.

## Checklist answers

### Auth variable
- **DeepSeek:** the Claude Code guide (https://api-docs.deepseek.com/quick_start/agent_integrations/claude_code) says
  `ANTHROPIC_AUTH_TOKEN`. The Anthropic API page (https://api-docs.deepseek.com/guides/anthropic_api) says
  `ANTHROPIC_API_KEY`, and lists `x-api-key` as fully supported and `Authorization: Bearer` as an alternative. Both work.
- Fake server: `ANTHROPIC_AUTH_TOKEN` is sent as `Authorization: Bearer <token>` only.
- **GLM** (official guide https://docs.z.ai/devpack/tool/claude): `ANTHROPIC_AUTH_TOKEN`.
- **Meta** (https://dev.meta.ai/docs/protocols/messages): `Authorization: Bearer`, so `ANTHROPIC_AUTH_TOKEN`. `x-api-key`
  is not mentioned.

### Credential option: 1 (`apiKeyHelper`) passes
- **Headers sent (fake server, run t3).** `apiKeyHelper` sends the key in both `Authorization: Bearer <key>` and
  `x-api-key: <key>`.
- **DeepSeek accepts it (run d1).** The run exited 0 with real model output.
- **GLM and Meta are not verified.** Meta documents only Bearer, and whether it rejects an extra `x-api-key` header is
  unknown.
- **Children don't see the key.** A `SessionStart` hook, a `PreToolUse` hook and a Bash tool command (`printenv`) all
  saw `ANTHROPIC_AUTH_TOKEN` and `ANTHROPIC_API_KEY` **UNSET**:
  - fake server: run t3
  - real DeepSeek: run d1, hooks only
- **MCP servers were not tested.** With `apiKeyHelper` no environment variable holds the key, so there is nothing for
  them to inherit.
- **Option 2 also works, as a fallback.** The scrub variable is **`CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1`** (an
  environment variable; found in the 2.1.319 binary).
  - Run t1, env token, no scrub: hooks saw `AUTH_TOKEN=SET`, and the Bash tool printed the token.
  - Run t2, with scrub: hooks and Bash saw UNSET, and requests still carried `Authorization: Bearer`.
  - The binary ties the scrub to a "subprocess sandbox" (it is incompatible with `--await-claim`, and it hardens
    `allowedTools`). Not explored further.

### `apiKeyHelper` failure
- **After startup** (the helper succeeds once and then exits 1, and the server answers 401 to force a refresh, run t8):
  - Claude Code retried with an **empty** `Authorization: Bearer` / `x-api-key`.
  - It printed `Your apiKeyHelper script is failing · This usually means you need to re-authenticate with your provider`.
  - It **exited 1**.
  - The planted Anthropic OAuth token was **not** sent: no fallback. Option 1 is kept.
- **Cached key.** With a TTL of 1 ms and no 401 (run t6), the helper's second failure went unnoticed. The cached key kept
  being used and the run exited 0.
- **Failure at startup does not fail closed** (runs t3a, t5):
  - Claude Code logs `apiKeyHelper failed: exited 1`, then still sends requests with empty credentials, without OAuth.
  - Against a server that accepts anything, it exits 0.
  - So SP's launcher pre-check (run the helper once, and refuse on failure or empty output) is **required**, not optional.

### No Anthropic credential sent
A fake OAuth credential was planted (`sk-ant-oat01-FAKE…` in the temp config dir's `.credentials.json`).
- **No key configured** (run t4): Claude Code **sends the Anthropic OAuth token to the third-party base URL**
  (`Authorization: Bearer sk-ant-oat01-…`). This is why the fail-closed launcher check matters.
- **With `apiKeyHelper` or `ANTHROPIC_AUTH_TOKEN`** (runs t3, t5, t6, t7, t8): the OAuth token was never sent, including
  when the helper failed.
- **Other headers seen:** `anthropic-beta`, `anthropic-version`, `anthropic-dangerous-direct-browser-access`,
  `x-app: cli`, `x-claude-code-session-id`, `x-stainless-*`, and `user-agent: claude-cli/2.1.319 (external, sdk-cli)`.
  There was no cookie or proxy auth.
- **Limit:** a real login lives in the macOS Keychain, not in `.credentials.json`. The plant tests the file path only.

### Request path
`POST /v1/messages?beta=true`, with no doubled `/v1` when `ANTHROPIC_BASE_URL` has no trailing `/v1`. No other path was
requested (no `count_tokens`, no GETs) in any run.

### Settings precedence
Fake servers on two ports (runs t9_*). The `env` block of the `--settings` layer **wins** over an `env` block that sets
`ANTHROPIC_BASE_URL` / `ANTHROPIC_MODEL` in:
- the user settings (`$CLAUDE_CONFIG_DIR/settings.json`)
- the checkout's `.claude/settings.json`
- the checkout's `.claude/settings.local.json`

A plain **process environment variable loses** to the checkout's settings `env` (run t9_procenv), so the base URL must
live in the `--settings` layer, not only in the launch environment. SP AC7 can therefore be skipped with this reason.
Managed (policy) settings were not tested.

### `/model` leak: yes
An interactive `/model deepseek-v4-pro` (driven through a pty, run t14):
- printed "Set model to deepseek-v4-pro and saved as your default for new sessions"
- wrote `{"model": "deepseek-v4-pro"}` to `$CLAUDE_CONFIG_DIR/settings.json`

On a shared `~/.claude` this breaks the next Anthropic session. In `-p` mode, `/model x` is "for this session only" and
writes nothing (run t11). SP must handle this; the owner or architect decides how (for example a per-provider
`CLAUDE_CONFIG_DIR`, or a warning).

### `--resume` leak: yes
The setup (run t13, same config dir):
- A session was created against server B with the marker `HISTORY-MARKER-first-turn`.
- It was then resumed with `--resume <id>` against server A.

Server A received 4 messages including the marker: **the full prior history is sent to the new provider**. SP should
refuse `--resume` / `--continue` across providers, or isolate the config dir.

### Thinking and `--effort`
- **Default requests already carry thinking.** Without `--effort`, Claude Code sends `thinking: {type: adaptive,
  display: omitted}` and `output_config: {effort: high}` for an unrecognised model id (run t12b). `--effort high` sends
  the same.
- **DeepSeek accepts both** (runs d2, d3: success, correct answers). Per DeepSeek's docs, `adaptive` counts as enabled,
  `budget_tokens` is ignored and `output_config.effort` is supported. Verdict: **go** for DeepSeek.
- **Meta:** the docs say `thinking: disabled` is a 400 and `budget_tokens` has no effect. `adaptive` is not documented.

### Behaviour canaries, real DeepSeek (`deepseek-flash`)
- **Run d1** (`claude -p`, headless, the same path delegation uses):
  - **System-prompt / CLAUDE.md canary: obeyed.** The final answer began with `CANARY-7731`, as `CLAUDE.md` required.
  - **Forced tool call: happened.** The model called `Bash` (`echo tool-ran > proof.txt`) and `Read` (notes.txt) as
    instructed. The Bash write was stopped by Claude Code's own permission check (output redirection is not covered by
    `Bash(echo:*)`), not by the model. The model reported the block honestly.
  - **Deny rule respected.** `Read(./secret.txt)` in `permissions.deny` returned "denied by your permission settings".
    The dummy secret appears nowhere in the transcript, and the model did not try another route.
- **Hooks fire:** `SessionStart` and `PreToolUse` (d1, d2).
- **`--agents`** (run d2): the main agent called `Agent` with `subagent_type: probe`; the sub-agent (`model: haiku` →
  `deepseek-flash`) answered `PROBE-OK-55`, relayed verbatim.

### Model IDs and slot mapping (DeepSeek)
- **Current models** (https://api-docs.deepseek.com/quick_start/pricing):
  - `deepseek-flash` (served by DeepSeek-V4.1-Flash-1017)
  - `deepseek-v4-pro`
- **Retired:** `deepseek-v4-flash` and `deepseek-v4-flash-vision-exp` are legacy aliases of retired models. They are
  still accepted, but the plan's `deepseek-v4-flash` should not be used.
- **Vendor guide:** it sets every slot to `deepseek-flash[1m]` (haiku `deepseek-flash`), `CLAUDE_CODE_SUBAGENT_MODEL`,
  `CLAUDE_CODE_EFFORT_LEVEL=max` and `CLAUDE_CODE_AUTO_COMPACT_WINDOW=786432`. SP keeps `CLAUDE_CODE_SUBAGENT_MODEL`
  unset, by plan.
- **`[1m]` suffix: not tested.** Without it, Claude Code warns that it doesn't recognise the model and assumes a 200k
  context window. That is harmless, but autocompaction comes early.
- **Name mapping:** the endpoint maps `claude-opus*` → `deepseek-v4-pro` and other `claude*` → `deepseek-flash`.
  Non-`claude` unknown names get a 400.

### Unsupported features (DeepSeek, from its Anthropic API page)

| Feature | DeepSeek |
|---|---|
| Ignored fields | `anthropic-beta`, `cache_control` (so no prompt-cache savings), `top_k`, `container`, `mcp_servers`, `citations` |
| `tool_choice` | `any` is treated as `auto`; a named tool is a 400 in thinking mode |
| Images | `deepseek-flash` accepts them in user messages and tool results, but an image in an assistant message is a 400; `deepseek-v4-pro` replaces images with placeholder text |
| Not supported | `document`, `redacted_thinking`, `mcp_tool_use` and other server-content blocks |
| Web search | works, billed by DeepSeek's Search API |
| Token counting | Claude Code made no `count_tokens` call in any run |

None of these broke a run in this spike. Image, web search and document paths were not exercised.

### Bad key: exit code 1
- **Real DeepSeek** (run d4): `Failed to authenticate. API Error: 401 Authentication Fails …`, after about 3 minutes of
  retries.
- **Fake server** (run t10): 11 attempts, then exit 1, with the misleading message `Not logged in · Please run /login`.

### Nonessential traffic
With `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`, the Anthropic URLs found in the 2.1.319 binary are:

| URL | What it is |
|---|---|
| `api.anthropic.com/api/web/domain_info` | WebFetch domain pre-check; turned off by the `skipWebFetchPreflight` setting |
| `api.anthropic.com/api/event_logging/v2/batch` | telemetry, covered by the flag |
| `api.anthropic.com/api/oauth/*` | login flows |
| `claude.ai/api/desktop/*` | desktop app download redirects |

Outbound traffic was not captured, so this list comes from the binary, not observed. Server-side web search goes to the
provider (DeepSeek bills it), not to Anthropic. Recommendation for SP: add `"skipWebFetchPreflight": true` to the
provider layer.

### Remote Control
Not tested, recorded as no: it needs a claude.ai login, and SP turns it off for every provider.

## GLM (z.ai), docs only

All facts are OFFICIAL unless marked:

| Item | Finding | Source |
|---|---|---|
| Base URL (international) | `https://api.z.ai/api/anthropic` | https://docs.z.ai/devpack/tool/claude |
| Base URL (China) | `https://open.bigmodel.cn/api/anthropic` | https://docs.bigmodel.cn/cn/coding-plan/tool/claude |
| Auth | `ANTHROPIC_AUTH_TOKEN` | same guide |
| Other variables | `API_TIMEOUT_MS=3000000`, `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`, `CLAUDE_CODE_AUTO_COMPACT_WINDOW=1000000` | same guide |
| Checked against | Claude Code 2.0.14 | same guide |
| Models | opus and sonnet `glm-5.3[1m]`, haiku `glm-5.3-flash[1m]` | same guide |
| Plan models | the plan may call only GLM-5.3 and GLM-5.3-Flash | https://docs.z.ai/devpack/faq.md |

- **Slot defaults contradict.** The same pages also list `GLM-5.3-Flash` in all three slots as the defaults. Confirm with
  a test.
- **The guide is for the GLM Coding Plan.** Its quota "may only be used within officially supported tools"
  (https://docs.z.ai/devpack/usage-policy.md). Not found: whether a pay-as-you-go key works on `/api/anthropic`.
- **Unsupported Anthropic fields:** none listed officially.
- **Terms:**
  - API content is not used to improve services unless the user opts in (Terms of Use §IV.7).
  - Individual (subscription) users' content may be used (§IV.5).
  - Which clause covers a Coding Plan subscriber is unclear.
  - Processing is "real-time", "not saved", generally in Singapore (privacy policy addendum).
- **Still needed:**
  1. A `zai-api-key` in the Keychain, then rerun the DeepSeek canaries (d1 to d4, plus the fake-server header check is
     already done).
  2. Confirm the endpoint accepts `apiKeyHelper`'s dual `x-api-key` + Bearer headers.
  3. Confirm the slot mapping.
  4. Find out which terms clause applies to the owner's plan.

## Meta (Muse), docs only

| Item | Finding | Status |
|---|---|---|
| Endpoint | `POST https://api.meta.ai/v1/messages`, documented as Anthropic-compatible, so `ANTHROPIC_BASE_URL=https://api.meta.ai` | OFFICIAL (https://dev.meta.ai/docs/protocols/messages; the old `ai.developer.meta.com/docs` redirects to `dev.meta.ai`). Inference: Claude Code appends `/v1/messages` |
| Token counting | `POST /v1/messages/count_tokens` | OFFICIAL |
| Auth | `Authorization: Bearer <MODEL_API_KEY>` | OFFICIAL |
| Claude Code guide | none | not found in Meta's docs |
| Model IDs | `muse-spark-1.3` (recommended), `muse-spark-1.2`, `muse-spark-1.1`, `muse-wonder-1.0` (preview), and `-contributor` variants of Spark 1.3 and 1.2 | OFFICIAL (https://dev.meta.ai/docs/models.md). The plan's third-party values are confirmed |

**Fields Meta documents as 400s:**
- the top-level fields `stop_sequences`, `top_k`, `container`, `inference_geo`, and **any unknown field**
- system blocks that are not text
- `thinking: {type: "disabled"}`
- a named `tool_choice`
- web-search `allowed_domains` / `blocked_domains` / `max_uses`

`budget_tokens` has no effect.

**Compared with Claude Code 2.1.319's actual request** (fake server, run t15):
- Claude Code sends the top-level keys `context_management`, `max_tokens`, `messages`, `metadata`, `model`,
  `output_config`, `stream`, `system`, `thinking`, `tools`.
- It sends `thinking: {type: "adaptive", display: "omitted"}` and text-only system blocks, with no `tool_choice` and no
  `stop_sequences` in these runs.
- **Risk:** whether Meta treats `context_management`, `output_config` or `thinking.type=adaptive` as unknown, and so as
  a 400, is undocumented.

**Terms (OFFICIAL, https://dev.meta.ai/docs/pricing-rate-limits):**
- Standard mode: content is not used to train Meta models.
- `-contributor` models: Meta trains on prompts, code, files and outputs. Muse Code subscriptions default to Contributor
  mode, so the hub must never use a `-contributor` id.
- Not found: a retention period.

**Still needed:**
1. A `meta-model-api-key`.
2. One fake-free canary request to confirm Claude Code's request shape is accepted (above all `context_management` and
   adaptive thinking), whether a dual `x-api-key` header is tolerated, then the d1 to d4 canaries.

Until then, `meta` is no-go and moves to a later story.

## Owner decisions this spike surfaces (not decided here)

1. **`/model` and `--resume` leaks** (both confirmed): SP needs a guard, such as refusing `--resume` / `--continue`
   under a provider, or a per-provider config dir, plus a `/model` note or guard.
2. **The launcher pre-check of the helper is mandatory.** Claude Code does not fail closed when the helper fails at
   startup. Without a key it sends the Anthropic OAuth token to the third-party URL (fake-server proof).
3. **ADR 0002 provider section:** the data-sharing decision per hub, and the vendors' terms. DeepSeek's API terms were
   not researched in this spike.

## Gemini CLI engine (story E1, 2026-11-21; revised after the adversarial review the same day)

A role entry `gemini:<model>` runs in the **Gemini CLI**, not Claude Code: `bin/work --role` / `--provider gemini` (focus
sessions, `bin/dispatch` builders) and `bin/agent --role` (read-only delegation), both through `bin/gemini-run`. The
orchestrator stays on Claude Code. Sources: the official docs (github.com/google-gemini/gemini-cli `docs/`, main, read
2026-11-21: `reference/configuration.md`, `reference/policy-engine.md`, `get-started/authentication.mdx`,
`cli/trusted-folders.md`, `cli/headless.md`, `cli/sandbox.md`, `resources/tos-privacy.md`), `gemini --help`, and runs of the
**real Gemini CLI 0.67.0 offline**: against `tests/fake_gemini_api.py` on 127.0.0.1 (`GOOGLE_GEMINI_BASE_URL`), a fake key,
every other connection sent to a dead proxy. No request reached Google. `tests/test_gemini_real.sh` repeats those runs
(opt-in: `ADE_REAL_GEMINI=1`); `tests/test_engines.sh` covers the hub side with a fake `gemini`.

### How the hub's rules reach the CLI (verified with the real CLI)
- **Not the system-settings slot.** The CLI skips a `GEMINI_CLI_SYSTEM_SETTINGS_PATH` file unless the file and every
  parent folder are owned by root ("Skipping system settings file ... is insecure"), so a normal user cannot use it.
  `bin/gemini-run` removes `GEMINI_CLI_SYSTEM_SETTINGS_PATH` and `GEMINI_CLI_SYSTEM_DEFAULTS_PATH` instead.
- **A user settings layer in a hub-owned home.** `GEMINI_CLI_HOME` is pinned to `<hub>/.local/engines/gemini-<google|key>`
  (the caller's value is ignored); `<home>/.gemini/settings.json` is rewritten for every run: `security.disableYoloMode`
  (verified: `--yolo` then exits 52, "YOLO mode is disabled"), `security.auth.selectedType`/`enforcedType`
  (`oauth-personal` or `gemini-api-key`), `security.environmentVariableRedaction` on with `GEMINI_API_KEY`,
  `GOOGLE_API_KEY`, `GOOGLE_APPLICATION_CREDENTIALS` blocked (verified: a shell tool's `printenv GEMINI_API_KEY` is empty;
  without it, the key shows), `security.folderTrust.enabled`, `advanced.ignoreLocalEnv`, `context.fileName`
  `AGENTS.md`/`CLAUDE.md`/`GEMINI.md`, `tools.discoveryCommand` and `tools.callCommand` empty, `hooksConfig.enabled` false,
  no `mcpServers`, usage statistics and auto-update off. The pinned home also keeps the user's own `~/.gemini` extensions,
  skills, hooks and MCP servers out. Project settings would outrank this layer, so a checkout's `.gemini/` is refused (below).
- **`--admin-policy <home>/hub-policy-<focus|agent>.toml`**, passed first on every run (Admin tier, above user rules;
  supplemental admin policies are not subject to the root-ownership check). Rules: the secret files the Claude path denies
  (`.env`, `.env.*`, `*.pem`, `*.key`, `id_rsa*`, `.npmrc`, `.netrc`, `credentials*`, `.ssh/`, `.aws/`, `secrets/`) are
  denied to `read_file`, `read_many_files`, `glob`, `grep_search`, `list_directory` and `run_shell_command` (verified:
  "Tool execution denied by policy"); in yolo mode every tool asks; `agent` mode denies every tool but the five read tools
  (verified: `write_file` and `run_shell_command` are "not found" to the model). The CLI **skips** a rule whose pattern it
  calls unsafe (nested quantifiers: "Unsafe regex pattern (potential ReDoS)"), so the patterns use no quantifiers; the
  real-CLI test catches a skipped rule. The CLI also **ignores `--admin-policy`** when its standard admin folder
  (`/etc/gemini-cli/policies`, `/Library/Application Support/GeminiCli/policies`) holds a `.toml`: the hub then refuses to
  run Gemini (`gemini_system_refusal`).

### Flags and modes
| Need | Gemini CLI | Used by the hub |
|---|---|---|
| Model | `-m, --model <id>` | `-m <model>` from the role entry (`gemini-*` only) |
| Headless | `-p <text>` appended to stdin; `-o text\|json\|stream-json`; exit 0 ok, 1 error, 42 input, 52 yolo disabled, 53 turn limit, 55 untrusted folder | `bin/agent`: task on stdin, `-p` a fixed instruction, `-o text`, `-e none`, `--allowed-mcp-server-names none` |
| First message | `-i, --prompt-interactive <text>` | `bin/work --prompt` |
| Approval | `--approval-mode default\|auto_edit\|yolo\|plan`, `--approvalMode` (verified: `--approvalMode yolo` auto-approves a shell call), `-y/--yolo`; `plan` documented as not fully functional | `--mode manual` = default, auto/acceptEdits = auto_edit, plan = plan; `bin/agent` = default. Yolo refused in every spelling and letter case (`gemini_yolo_refusal`, in `bin/work` and again in `bin/gemini-run`) |
| Trust | a headless run in an untrusted folder exits 55; `--skip-trust` or `GEMINI_CLI_TRUST_WORKSPACE=true` trusts it for the session; a trusted folder loads the workspace's `.gemini/settings.json`, `.env` and MCP servers | `bin/agent` passes `--skip-trust` only after the checkout's `.gemini/` was refused; a focus session keeps the CLI's own trust prompt; `GEMINI_CLI_TRUST_WORKSPACE` is set empty |
| Sandbox | `-s, --sandbox` (macOS Seatbelt, or a Docker/Podman container; on by default with yolo) | **not used**: it needs a container runtime on Linux and changes where the checkout lives; the hub relies on the policy and the read-only tool set, and never runs yolo |

### Sign-in and the key
- `gemini_auth`: the CLI's own Google login cached in the hub's google home (`<hub>/.local/engines/gemini-google/.gemini/
  oauth_creds.json`; the owner signs in once with `GEMINI_CLI_HOME=<that home> gemini`), else a key stored with
  `bin/keys set gemini`. The login is judged in the same home the CLI gets; `~/.gemini` or another `GEMINI_CLI_HOME` does
  not count. Neither: refused before launch with that hint.
- The CLI takes a key only from its environment (`GEMINI_API_KEY` or a `.env` file); there is no key-helper. `bin/gemini-run`
  reads it once and `exec`s the CLI with it, so it is in that process only: not in argv, the launcher, a settings or policy
  file, a log, or the parent shell (`tests/test_engines.sh` reads the parent's environment).
- **`.env` files.** The CLI loads the first `.env` up from the cwd, then `~/.env` (or `.gemini/.env` variants); a `.env`
  never overrides a variable that is already set. So `bin/gemini-run` sets every credential, backend and trust variable
  (`gemini_scrub_vars`: `GEMINI_API_KEY`, `GOOGLE_API_KEY`, `GOOGLE_GENAI_USE_VERTEXAI`, `GOOGLE_GENAI_USE_GCA`,
  `GOOGLE_APPLICATION_CREDENTIALS`, `GOOGLE_GEMINI_BASE_URL`, `GOOGLE_VERTEX_BASE_URL`, `GOOGLE_CLOUD_PROJECT`,
  `GOOGLE_CLOUD_LOCATION`, `GEMINI_CLI_TRUST_WORKSPACE`, `GEMINI_CLI_TRUSTED_FOLDERS_PATH`, `GEMINI_MODEL`) to empty before
  setting its own; a checkout `.gemini/.env` is refused; `advanced.ignoreLocalEnv` is on.
- **Residual risk:** the CLI's own children that are not tools (an MCP server or hook the CLI might still start) are not
  documented as covered by the redaction; the hub's home has none and the checkout's are refused, but a key run is still
  only as tight as the CLI. Prefer the Google login (no key handled) where its terms fit.
- `AGENT_GEMINI_LOOPBACK_URL=http://127.0.0.1:<port>` (loopback only) points the CLI at a local fake API; only
  `tests/test_gemini_real.sh` sets it.

### The checkout's own configuration: refused
`gemini_checkout_refusal` (in `candidate_refusal`, `bin/work` and `bin/gemini-run`, exit 2) refuses a checkout with any
`.gemini/settings.json`, `.gemini/hooks`, `.gemini/policies` or `.gemini/.env`. A project `settings.json` outranks the hub's
user layer and can set `tools.discoveryCommand` / `tools.callCommand` (commands the CLI runs to find and call tools; their
output and environment are not sanitized), `hooks`, `hooksConfig`, `mcpServers`, `security.*` or yolo-friendly approvals.
A discovery command was not seen to run in a short headless session, but nothing in the CLI promises that, so it is refused.

### Data terms (docs, `resources/tos-privacy.md`)
- Google login: Gemini Code Assist terms (for individuals: Google Terms of Service and the Gemini Code Assist privacy notice).
- API key, unpaid: **Gemini API Terms, Unpaid Services**: Google may use prompts and responses to improve its products.
- API key, paid (billing on): Gemini API Terms, Paid Services: not used to improve products.
- Vertex AI: Google Cloud terms (not used by the hub).
- Hence `gemini` is **owner-only** (`owner_only` 1): a client hub uses it only with `HUB_GEMINI_CLIENT_APPROVED=1` in
  `hub.conf`, set when that client approved it (ADR 0002), and only when `HUB_PROVIDERS_ALLOWED` lists it. `bin/gemini-run`
  checks both again, so a direct call cannot skip them.

### Gaps (stated plainly)
- No Claude Code hooks: no C6 events, no `busy`/`idle` marks in `bin/sessions`, no session-end sync or journal from the
  session itself; no plugins, no BMAD skills, no `--agents`, no Telegram channel, no Remote Control (so no one-session-per-
  folder check from a Remote Control name). The folder's specialist agents are not loaded (said on stderr).
- `--approval-mode plan` is documented as not fully functional; `--sandbox` is not used.
- The Google login is detected by its cached file in the hub's home only; a login kept elsewhere is not seen.
- A policy rule the CLI rejects is skipped with a message on stderr, not a failure; `tests/test_gemini_real.sh` is the
  guard and should run after any change to `gemini_policy_write` or a CLI upgrade.
- The reviewer still runs on Claude Code, and the verification command decides Done.
