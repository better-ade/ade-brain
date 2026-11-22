# H2: the hub's key store runs ade-secrets

Status: Ready for development (2026-11-22). Risk: high (secrets). Depends on ade-secrets v0.3.0. Needed by ade-cli
A13 (`ade key`) and A14 (`ade vault`), which the owner asked to build on 2026-11-22.
Verification command: `bash tests/run.sh`.

## Goal
When `ade-secrets` is installed, the hub's `bin/secret` hands every call to it, so there is one local key store and
none of it runs inside an agent session. Without `ade-secrets`, or with `HUB_SECRETS=builtin`, the hub behaves exactly
as today. The contract is ade-secrets' `docs/contract.md` (v1): it gives the block to paste and the calls a hub may
make. Where this story and the contract differ, the contract wins: stop and say so.

## Acceptance criteria (`tests/test_secret.sh`, extended, with a fake `ade-secrets` that records its arguments; never the real Keychain)
| AC | Criterion | Test |
|---|---|---|
| 1 | `bin/secret` carries the contract's delegation block word for word, right after its `set -u` line; a test compares it with a pinned copy of the block kept in `tests/fixtures/` | `secret_block_matches_contract` |
| 2 | With `ade-secrets` on `PATH`: `--set`, `--has`, `--forget`, `--list` and a plain name each make the call the contract's table gives, and the exit code comes through | `secret_delegates` |
| 3 | `HUB_SECRETS=builtin`, or no `ade-secrets` on `PATH`: every existing `bin/secret` and `bin/keys` test passes unchanged | `secret_builtin_unchanged` |
| 4 | `bin/keys` reaches the store only through `bin/secret`; its check for the `security` command is skipped when `ade-secrets` is installed; inside an agent session a presence check says "run this in your own terminal" (exit 3), never "missing" | `keys_through_secret` |
| 5 | The key helper path is unchanged: `bin/secret <name>` prints the value and a newline and nothing else, from `ade-secrets get <name>` | `secret_helper_path` |
| 6 | `bin/doctor` says which store is in use (`ade-secrets`, with its version, or the hub's own), never a value | `doctor_names_store` |
| 7 | The hub's settings template gains the permission rules from ade-secrets' `docs/claude-settings.json` (a pinned copy in `tests/fixtures/`), merged with the rules already there; a test fails when one is missing | `settings_have_secret_rules` |
| 8 | It works the same on Linux through the platform layer; the hub's own 0600 file store is used only when `ade-secrets` is absent | `secret_linux` |
| 9 | The docs say plainly: keys already in the hub's old store are not moved, the person enters them again in their own terminal; and the "Owner check" in ade-secrets' contract should be done before a real key is stored. The contract the hub now relies on is recorded in `.ade/context/` | `secret_docs` |

## Out of scope
Any change to ade-secrets. Moving keys between stores automatically. `ade key` and `ade vault` (ade-cli A13, A14).
