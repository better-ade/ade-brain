# ade-secrets fixtures (story H2)

Pinned from better-ade/ade-secrets tag v0.3.0 (contract v1):

- `delegation-block.sh`: the delegation block from `docs/contract.md`, "The delegation block (bin/secret)", as written
  (after a one-line header naming the tag). `bin/secret` carries it word for word (`tests/test_secret.sh`,
  `secret_block_matches_contract`).
- `claude-settings.json`: `docs/claude-settings.json`, byte for byte. Its rules are merged into the hub's settings
  templates (`tests/test_secret.sh`, `settings_have_secret_rules`).

A new ade-secrets release that changes either file: copy it here with the new tag, then update the hub to match.
