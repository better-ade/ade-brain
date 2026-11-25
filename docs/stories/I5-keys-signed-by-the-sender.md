# I5: a sealed keys block is signed by its sender, and receive checks it

Status: **Approved** (owner, 2026-11-25). Risk: **high** (secrets).
Depends on I4 (merged, #88).
Found by: I4's adversarial review. `age` has no sender authentication, so anyone who knows a person's public SSH key
can seal a block to them. I4 shows the sender as "not verified" and asks before storing; I5 lets the recipient know.
Verification: `bash tests/run.sh`.

## Goal
`bin/keys share` signs the block's contents with the sender's SSH key (`ssh-keygen -Y sign`, namespace
`ade-keys`) before sealing, so the signature is inside the sealed block. `bin/keys receive` checks it against the
sender's public keys and says who sent it.

- `share` signs with `~/.ssh/id_ed25519` (or `-i <key>`, or the key in `ssh-agent` with its `.pub`). It records the
  sender's GitHub user (`--as <github-user>`, defaulting to `gh api user` when signed in) in the block.
- `receive` checks the signature against the keys GitHub publishes for that user (`AGENT_GITHUB_KEYS_URL` in tests,
  https only, as I4).
  - Good signature: `from: <user> (verified: signed by SHA256:…)`.
  - Bad signature, or one from a key that user doesn't publish: refused, nothing stored, non-zero exit.
  - No signature (an I4 block): shown as today, "not verified", and still asks before storing.
  - `--from <github-user>`: the recipient says who they expect; a block signed by anyone else is refused.
- Nothing about the values changes: still never printed, never in a file outside the store, never in an argument.

## Acceptance criteria (tests in `tests/test_keys_share.sh`; real `age` and `ssh-keygen`)
1. A signed block from A opens for B, and B sees `verified` with A's key fingerprint; the values match.
2. A block whose inner contents were changed after signing is refused; nothing is stored.
3. A block signed with a key A does not publish is refused; nothing is stored.
4. `--from A` refuses a block signed by C; nothing is stored.
5. An unsigned (I4) block still opens with the "not verified" line and the confirm prompt.
6. No value appears on stdout or stderr, in files under either HOME other than the store, or in process arguments
   (the I4 checks, rerun with signing).
7. E2E `tests/e2e_keys.sh`: A shares signed, B receives and sees `verified`.

## Out of scope
Keys that live only in 1Password or a hardware key without an agent (they can still share unsigned). Signing for
anyone but GitHub users. Revocation.
