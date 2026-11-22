# The key store through ade-secrets (contract, story H2)

The hub relies on better-ade/ade-secrets' `docs/contract.md` **v1**, as released in ade-secrets **v0.3.0**. Pinned
copies of what the hub takes from it live in `tests/fixtures/ade-secrets/` (the delegation block and
`docs/claude-settings.json`, with the tag they came from); `tests/test_secret.sh` checks the hub against them. A new
ade-secrets release that changes either: update the pinned copies first, then the hub.

## When the hub delegates
- `bin/secret` carries the contract's delegation block word for word, right after its `set -u` line (before `bin/lib.sh`
  is sourced). It delegates when `ade-secrets` is on `PATH` and `HUB_SECRETS` is not `builtin`; `secret_delegated` in
  `bin/lib.sh` is the same test, for `bin/keys` and `bin/doctor`.
- `HUB_SECRETS=builtin` is read from the **environment** only. It keeps the hub's own store (`secret_store`: the Keychain,
  pass or the file store, story V1) exactly as before. With no `ade-secrets` on `PATH` nothing changes either.
- `HUB_SECRETS` in `hub.conf` is a different, older key: the secret names `bin/doctor` checks. `bin/lib.sh` reads it as
  `HUB_SECRET_NAMES` and restores the environment's `HUB_SECRETS` afterwards, so hub.conf never replaces the switch
  that `bin/secret` inherits. `HUB_SECRETS` is in `checkout_gate_vars` (a checkout's settings may not set it).

## The calls (contract table)
| bin/secret | ade-secrets | exit |
|---|---|---|
| `--set <name>` | `ade-secrets set <name> --helper --kind api-key --used-by hub` (it prompts on the terminal; the hub reads nothing) | passed on |
| `--has <name>` | `ade-secrets list --names`, then an exact match of the name | 0 stored, 1 not, else ade-secrets' exit |
| `--forget <name>` | `ade-secrets forget <name>` | passed on |
| `--list` | `ade-secrets list --names` | passed on |
| `<name>` | `ade-secrets get <name>`: the value and a newline, nothing else (the key helper path) | passed on |
| no argument, `-*` | the hub's own usage (exit 2) | |

Exit codes are ade-secrets': 0 ok, 1 failed, 2 usage or store, 3 refused (an agent session, or an entry not set
`--helper`), 4 no clipboard, 5 the age store locked.

## What the hub does with them
- `bin/keys` reaches the store only through `bin/secret`. Its check for the hub's own store (the `security` command,
  pass, the file store's folders) is skipped while delegating. A presence check that ade-secrets refuses (exit 3, inside
  an agent session) prints "run this in your own terminal" and exits 3, never "missing".
- `bin/doctor` names the store in use: `ade-secrets <version>` (from `ade-secrets --version`, the one command every
  context may run; `ade-secrets (version unknown)` when it fails), else the hub's own store as before. A refused presence
  check is `WARN ... not checked here`, never `MISSING`. It never reads a value.
- The apiKeyHelper line is unchanged (`HUB=... AGENT_KEYCHAIN_SERVICE=... <hub>/bin/secret <name>`); `bin/secret`
  execs `ade-secrets get <name>`. ade-secrets keeps one entry per name for the machine: `HUB_KEYCHAIN_SERVICE` /
  `AGENT_KEYCHAIN_SERVICE` do not separate hubs there.
- The root `.claude/settings.json` and `templates/folder-settings.json` carry every rule of ade-secrets'
  `docs/claude-settings.json` (deny: `Read(~/.ade-secrets/**)`, `Bash(security find-generic-password*)`,
  `Bash(security dump-keychain*)`, `Bash(pass show*)`, `Bash(pbpaste*)`; ask: `Bash(ade-secrets *)`), next to their own.

## Moving to ade-secrets
Keys already in the hub's own store are not moved. The person enters each again in their own terminal
(`bin/keys set <tool>`). Before a real key is stored, the contract's "Owner check" is done by hand with throwaway values.

## Tests
Never the real ade-secrets: `make_hub` (tests/helpers.sh) drops every `PATH` folder holding an `ade-secrets`, except a
fake named in `ADE_SECRETS_FAKE_DIR`. `tests/test_secret.sh` uses a fake that records its arguments.
