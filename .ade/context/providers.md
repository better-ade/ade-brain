# Providers behind Claude Code (contract, story SP)

Claude Code stays the CLI; a provider changes only the endpoint and models. Written by SP; S3a (`bin/agent`) reads the
same table, never a copy. Findings: `engines.md`. Decision and terms: `decisions/0002-providers-and-engines.md`.

## Ids
`anthropic` (default; Claude Code's own login; no row), `deepseek`, `glm` (disabled). `meta` is absent.

## The table (`bin/lib.sh`)
- `providers` prints the row ids. `provider_field <p> <field>` prints a field; it returns 1 for an unknown pair.
- Fields: `base_url` (https, no trailing `/` or `/v1`), `secret` (Keychain name for `bin/secret`), `label` (doctor),
  `model`, `opus`, `sonnet`, `haiku`, `small` (slot values), `owner_only` (`1` = only in a hub with `HUB_OWNED_BY_OWNER=1`).
- deepseek: `https://api.deepseek.com/anthropic`, `deepseek-api-key`, main/sonnet/haiku/small `deepseek-flash`, opus
  `deepseek-v4-pro`, `owner_only` 1. glm: `https://api.z.ai/api/anthropic`, `zai-api-key`, models `unconfirmed`.
- `provider_feature_go <p> <focus|agents|delegation|effort|remote>`: exit 0 = go. deepseek: focus, agents, delegation,
  effort go; remote no. glm: all no. One go per `case` line.
- `provider_no_go_reason <p> <feature>` names "S0 item 21, .ade/context/engines.md".
- `provider_model_ok <p> <m>`: a slot alias (`opus`, `sonnet`, `haiku`) or a row id. `provider_model_id` resolves an alias.
- `provider_hub_refusal <p>`: prints the reason this hub may not use `<p>` (empty = it may). Fails closed: only
  `owner_only` `0` opens a row to client hubs; a missing value counts as owner-only. glm is `owner_only` 1.
- `provider_scrub_vars`: the names that beat `apiKeyHelper` or switch Claude Code's backend (`ANTHROPIC_AUTH_TOKEN`,
  `ANTHROPIC_API_KEY`, `ANTHROPIC_CUSTOM_HEADERS`, `CLAUDE_CODE_USE_BEDROCK`, `CLAUDE_CODE_USE_VERTEX`,
  `CLAUDE_CODE_USE_FOUNDRY`, `CLAUDE_CODE_OAUTH_TOKEN`). `bin/agent` never passes them (allowlisted environment).
- No base URL override exists (`HUB_<P>_BASE_URL` is never read).

## `hub.conf` keys
- Read only from `hub.conf` (unset in `lib.sh` before sourcing): `HUB_PROVIDER` (default `anthropic`),
  `HUB_PROVIDERS_ALLOWED` (space-separated, default `anthropic`), `HUB_OWNED_BY_OWNER` (`1` = the owner's own hub).
- `HUB_<P>_MODEL`, `HUB_<P>_SMALL_MODEL` (`<P>` upper-case, `-` as `_`): main and small-fast slot overrides, checked
  like `--model`.
- `HUB_MODEL` and `HUB_AGENT_MODEL` are not passed to a provider session.

## Roles (`bin/roles`, `bin/agent`)
- Table in `bin/lib.sh`: `roles`, `role_candidates <role>` (exit 2: unknown role, bad entry, provider without a row, empty
  list), `candidate_refusal <p:m> [dir] [has|read]` (prints the reason, empty = usable), `role_pick <role> [dir] [has|read]`
  (sets `ROLE_PICK`, `ROLE_SKIPS`; 0 picked, 1 none usable, 2 bad table).
- Defaults: `routine` = `anthropic:sonnet deepseek:sonnet`; `triage` = `anthropic:haiku deepseek:haiku`; `reviewer` =
  `deepseek:sonnet anthropic:sonnet`; `architect`, `builder` = `anthropic:opus`. An `anthropic:` model must be `opus`,
  `sonnet`, `haiku` (optional `[1m]`) or `claude-*`. `HUB_ROLE_<ROLE>` in `hub.conf` replaces a list or adds a role (`-` as `_`); every `HUB_ROLE_*` is unset
  before `hub.conf` is sourced.
- `candidate_refusal` makes `bin/work --provider`'s checks with the `delegation` feature: allowlist, row,
  `provider_hub_refusal`, own hub, plain `claude`, go, model, `hub.conf` slot models, config dir, checkout settings, key.
  `anthropic` needs only the allowlist. `bin/roles` uses `--has`; `bin/agent` reads the key once before the run.
- `bin/work --role R <folder>` (story C2): `role_pick R` (`has`, no checkout dir) sets `--provider` and `--model`, then the
  same path and gates as `--provider` (focus go, key read, checkout settings). Excludes `--model`/`--provider` (exit 2);
  unknown role exit 2; none usable exit 1 with each skip. The pick wins over `HUB_MODEL`. Recorded as `role=` in the
  session entry; `bin/sessions` shows it in the ROLE column after STARTED (`-` when none).
- `bin/agent --role R --folder F`, task on stdin, runs in the folder's first checkout (else the hub folder). Exit 0 report;
  1 failed, timed out or killed, never retried elsewhere; 2 refused, nothing ran.
- Engine: `claude -p --output-format text --no-session-persistence --model M --tools Read,Grep,Glob --safe-mode --restricted
  --strict-mcp-config --disable-slash-commands`, plus `--settings <file>` for a provider (mode 600, removed, same layer as a
  provider session, with `disableAllHooks`, `ENABLE_TOOL_SEARCH=false` and `permissions.deny` `Read(**/<name>)` for `.env`,
  `.env.*`, `*.pem`, `*.key`, `id_rsa*`, `.ssh/**`, `.aws/**`, `.npmrc`, `.netrc`, `credentials*`, `secrets/**`). Not `--bare`:
  it never reads the Claude login and offers a provider run only `Read`.
- Environment: cleared, then only `HOME USER SHELL PATH LANG TMPDIR HTTPS_PROXY NO_PROXY SSL_CERT_FILE NODE_EXTRA_CA_CERTS`,
  `AGENT_FOLDER` and `CLAUDE_CONFIG_DIR` (provider: its own dir; Anthropic: `claude_home`, left unset when it is the default).
- Lifetime: own process group plus a watchdog in it; timeout (`AGENT_TIMEOUT`, default 540, cap 570), TERM, INT, HUP or the
  death of `bin/agent` end the group (TERM, KILL after 5 s).
- Output: `agent: role=... bytes=... truncated=... timeout=... full=<path>`, then `<<<AGENT-OUTPUT nonce=<32 hex> ...>>>`,
  at most 20 KiB, and `<<<END-AGENT-OUTPUT nonce=<same>>>` as the last line. Full text: `.local/agent-out/` (mode 600, 30
  days). Journal: `journal/delegations-YYYY-MM.md`, no task text; `bin/context` and `bin/changes` do not read it.
- `orchestrator_endpoint_warning`: `bin/doctor` (`WARN`) and hub-root `bin/context` (`WARNING:`), host only, not in a focus
  session (`AGENT_FOLDER`).

## Keys (`bin/keys`)
- `bin/keys` lists each `key_tools` entry: `anthropic` (`anthropic-api-key`, optional, story H1: a stored key is used by
  `bin/agent --live-test` through `apiKeyHelper` only, never an environment variable, and by role runs only with
  `HUB_AGENT_ANTHROPIC_KEY=1` in `hub.conf`; otherwise the Claude login; ADR 0002), `deepseek`, `glm`, `muse`
  (`meta-model-api-key`), `gemini` (`gemini-api-key`), `telegram` (`telegram-bot-token`, the bot for `bin/chat`, .ade/context/chat.md), with stored or missing and what the tool still needs for `bin/agent`. Never a value. `key_tools`, `key_secret` and
  `key_source` are in `bin/lib.sh`; `muse` and `gemini` have no provider row, so they show "not connected yet".
- `bin/keys set <tool>` reads the key from a hidden prompt or stdin through `bin/secret --set`; `bin/keys forget <tool>` removes
  it. Exit 2 for an unknown tool or extra argument, so a key on the command line is refused. Storing a key enables nothing.
- `bin/secret --set` passes the value to `security -i` on stdin, never as an argument, and reads it back to confirm; a failed store exits 1.

## A provider session (`bin/work --provider <p>`)
- Refused (exit 2): not allowed; no row; owner-only in a client hub; a command other than plain `claude`; a feature
  without a go; `--resume`, `--continue`, `-r`, `-c`; a model not allowed; `HUB` (environment) naming another hub
  than the script's own; `<hub>/.local`, the config dir or its `projects/` resolving outside `<hub>/.local`; the
  checkout's `.claude/settings.json` or `settings.local.json` setting a `provider_scrub_vars` name in `env`. Missing or empty key: exit 1 with the
  `bin/secret --set <secret>` hint, before Claude Code starts. Dry runs never read the key.
- Command: `cd '<dir>' && env -u <each provider_scrub_vars name> AGENT_FOLDER='<F>'
  CLAUDE_CONFIG_DIR='<hub>/.local/providers/<p>' claude --settings '<merged>'`, no `--remote-control`. A dry run
  (`WORK_DRY=1`) prints the command, then the merged settings JSON, and keeps no file.
- Merged settings (mktemp, mode 600, removed by the launcher's trap, or by `bin/work`'s own trap on any exit before
  the hand-off): the folder's settings minus any `provider_scrub_vars` name in `env`, plus `apiKeyHelper`
  (`HUB='<hub>' AGENT_KEYCHAIN_SERVICE='<svc>' '<hub>/bin/secret' <secret>`, the hub and Keychain service the key
  pre-check used), `skipWebFetchPreflight: true`, and an `env` block (provider keys win) with
  `ANTHROPIC_BASE_URL`, `ANTHROPIC_MODEL`, `ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL`, `ANTHROPIC_SMALL_FAST_MODEL`,
  `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`, `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1`. Never `CLAUDE_CODE_SUBAGENT_MODEL`,
  never a key.
- Config dir `<hub>/.local/providers/<p>` holds memory links like `bin/setup`'s:
  `projects/<encode_path hub>/memory -> <hub>/memory`, `projects/<encode_path dir>/memory -> <hub>/<F>/memory`.
- Agents: front matter `provider:` absent or equal stays in `--agents`; another provider is left out, with
  `work: delegatable (not in --agents): <name> (provider <p>)` on stderr.
