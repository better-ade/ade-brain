# I4: a hub's keys go to one person, sealed to them (handover and share)

Status: **Approved** (owner, 2026-11-25). Risk: **high** (secrets). Independent of I1; I2 points to it.
Found by: the owner wants handover and sharing of a hub, keys included, to be secure.
Verification: `bash tests/run.sh`.

## Today and the gap
Each machine keeps the hub's keys in its own secret store (`bin/lib.sh` `secret_*`, story V1: the macOS Keychain,
`pass`, or the 0600 file store). `bin/keys` and `bin/secret` set, check and forget them. Nothing moves them to another
person, so a handover or share ends with "send me your keys" over chat or email, in plain text.

## Goal
`bin/keys share` seals chosen keys to one person with `age`. The recipient is either a GitHub user, sealed to the
public SSH keys GitHub publishes at `https://github.com/<user>.keys`, or an `age1…` key the person prints with
`bin/keys receive --new`. The sealed text can travel any way (chat, email). Only that person's private key opens it.
`bin/keys receive` opens it straight into their own secret store. No value is ever printed, written to a file outside
the store, or put in git. There is no server.

- `bin/keys share <github-user | age1…> [tool|secret name …] [--all]`:
  - It shows the recipient's key fingerprints and asks before sealing (a typo'd user is caught here).
  - It prints an armored block on stdout.
  - Inside the block: the hub name, the sender, the time, an expiry (default 7 days) and the values. Outside it: nothing
    but the armor.
  - Values go from the store into `age` through a pipe, never into a file or an argument.
- `bin/keys receive [file]` (or stdin):
  - It opens the block with `~/.ssh/id_ed25519`, `id_rsa`, `-i <identity>`, or the identity made by `--new`.
  - It refuses an expired block, or one for another hub (unless `--any-hub`).
  - It asks before replacing a key already stored, stores each key, and lists the names stored, never the values.
- `bin/keys receive --new`: makes a one-off age identity under `~/.config/ade/age/` (0700 folder, 0600 file) for people
  whose SSH key `age` cannot use (in 1Password or a hardware key). It prints the public key to send to the sender.
- **I2 hook:** `bin/adopt --handover` and `--share` list `bin/keys share <new person>` as the step for keys.
  `--handover` adds "replace the shared keys at their source" to the old owner's list.
- `age` is a needed tool: `bin/setup` and doctor report it, and `bin/server install` and the Homebrew/apt steps
  install it.

## Acceptance criteria (tests in `tests/test_keys_share.sh`, a real `age`, `ssh-keygen` keys, the file store)
1. Share then receive with an ed25519 SSH key: every value matches in the recipient's store (checked through
   `bin/secret`). The block holds no value in clear text.
2. A GitHub user: the keys come from `AGENT_GITHUB_KEYS_URL` (a test file). Only `ssh-ed25519` and `ssh-rsa` lines
   are used, and the fingerprints are shown. A user with none is refused, and nothing is printed.
3. `receive --new`: the identity file is 0600 in a 0700 folder. A block sealed to its public key opens.
4. Refusals:
   - a block sealed to someone else, an expired block, or a block for another hub;
   - a recipient given as a path inside the hub.
   Each is refused with a reason, nothing is stored, and the exit code is non-zero.
5. Replacing an already stored key asks first. "No" keeps the old value.
6. No value appears:
   - on stdout or stderr of either command;
   - in any file under either HOME other than the store;
   - in the process arguments (checked with a fake `age` that records its argv);
   - in `git grep` of the hub.
7. `bin/doctor` reports `age` missing, with the install line for this platform.
8. `bin/adopt --handover` / `--share` (when I2 is in) print the `bin/keys share` step. `--handover` also prints the
   replace-at-source reminder.
9. E2E `tests/e2e_keys.sh` (run by tests/run.sh, offline):
   - Two HOMEs, A with three keys, B with an SSH key served as B's "GitHub keys".
   - A shares, B receives, and B's `bin/keys` shows the three as stored.
   - A second receive of the same block asks before each replace.

## Out of scope
A hosted one-time-secret service (a later story if wanted). Sharing keys with someone outside ADE. Moving keys between
two machines of the same person (they can use this too, sealed to themselves). Revoking a key already handed over:
it is replaced at its source.
