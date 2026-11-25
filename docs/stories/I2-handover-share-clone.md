# I2: bin/adopt takes over, joins or copies a hub (handover, share, clone)

Status: **Approved** (owner, 2026-11-25). Depends on I1 (merged) and I4 (keys step). Risk: **high** (who the owner is: approvals and
personal data in `memory/users/`).
Found by: the owner wants three ways to take a hub from someone: handover, sharing, clone.
Verification: `bash tests/run.sh`.

## Today and the gap
The owner's name is written by `bin/init` into `hub.conf` (`HUB_OWNER`) and baked into the hub `CLAUDE.md`,
`ACCESS.md`, `README.md`, `persona-agent.md`, and each folder's `ACCESS.md`/`agent.md`. Nothing changes it later.
Each person's learned facts live in `memory/users/<user>/`. The Keychain service, `~/.agent-hub/<name>/` and launchd
jobs are keyed by `HUB_NAME`, so two hubs with one name on one machine collide.

## Goal
`bin/adopt <mode>`, run in a fresh clone on the new person's machine (after I1's `bin/setup`):
- `--share`: nothing about the hub changes. The person keeps their own `memory/users/<them>/`, keys, bot and
  schedule; the owner and their approvals stay. It checks and reports what this machine still needs.
- `--handover --owner <name>`: the owner becomes `<name>` everywhere `bin/init`/`bin/new` put it; the previous owner's
  `memory/users/<them>/` leaves the tree (still in git history, said so); one journal line records the handover.
- `--clone --owner <name> --name <new>`: a new hub: new name, new owner, a fresh git history (one first commit, no
  remote), no journal, no `memory/users/`, every folder's `STATE.md` reset, `.ade/session.md` emptied; personas,
  folders, ACCESS tables, rules and skills kept.
Every mode ends by listing what to do by hand: keys to set (`bin/keys`), `ade setup --telegram` for the person's own
bot, `bin/schedule install`, and for a handover the GitHub repo transfer (the previous owner's step).

## Acceptance criteria (tests in `tests/test_adopt.sh`)
1. `--handover --owner B`: `HUB_OWNER=B`, no tracked file names the old owner where `bin/init`/`bin/new` wrote it;
   the old owner's `memory/users/` is gone from the tree; the journal has one handover line.
2. `--share`: no tracked file changes; the "what's left" list names the missing keys.
3. `--clone --owner B --name n2`: `HUB_NAME=n2`, one commit, no remote, no journal, no `memory/users/`, `STATE.md`
   files reset, personas and folders identical to the source.
4. A clone named like a hub already on this machine (`~/.agent-hub/<name>/` exists) is refused with the reason.
5. Every mode refuses a dirty tree, an unknown mode, and a missing `--owner`/`--name` where needed, changing nothing.
6. **End to end** (`tests/e2e_adopt.sh`, run by `tests/run.sh`): a hub made in scratch HOME A with a learned fact and
   journal; in HOME B each mode on its own clone, then `bin/setup` and `bin/doctor` pass and `bin/work` starts a
   folder session (fake claude) under the new owner.
7. Keys (story I4, `.ade/context/keys-share.md`): `--handover` and `--share` print exactly
   `Keys: bin/keys share <new person> --all   (they run: bin/keys receive)`; `--handover` also prints, in the old
   owner's list, `Replace the shared keys at their source (each provider's console), then bin/keys forget <tool> for each.`

## Out of scope
Moving the keys themselves (story I4's `bin/keys share`; adopt only names the step); transferring the GitHub repo; several owners at once.
