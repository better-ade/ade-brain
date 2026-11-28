# X1: agents reach servers through ssh-agent, never holding a key or a password

Status: **Approved** (owner, 2026-11-28). Risk: **high** (secrets, access, production). Verification: `bash tests/run.sh`.
Owner's intent (2026-11-28): "a way for developers to also check DB and Servers - securely. so ssh keys, passwords
needs to be either on the secrets or thru clipboard"; the flow: the developer asks the agent to connect, and is asked
to put any password in the secure store, never to paste it in the terminal or chat. Order: X1, then X2 (databases),
then ade-cli A13 (`ade key`, the clipboard).

## Goal
`bin/ssh <name> [command]` connects to a server the hub knows by name. Key servers go through the developer's
ssh-agent (the key is loaded once by the developer; the agent never reads `~/.ssh`, which `bin/agent` already denies).
Password servers take the password from the hub's secret store (`bin/secret`, the Keychain on macOS) through an
`SSH_ASKPASS` helper, so it is never in an argument, the environment, output, a log or chat. When something is
missing, `bin/ssh` stops and prints the one command the developer runs in their own terminal; the agent relays it.

## Acceptance criteria (tests/test_ssh.sh; a fake `ssh` that records its arguments, environment and askpass output)
1. **ssh_registry**: `ops/access/<name>.conf` holds names and locations only (`HOST`, `USER`, `PORT`, `JUMP`, `AUTH=key|password`,
   `PROD=0|1`); `bin/ssh` refuses a file holding anything else (a key-shaped value, a `PASSWORD` key), and a name that
   is not `^[a-z0-9][a-z0-9-]{0,31}$`. The format is recorded in `.ade/context/access.md`.
2. **ssh_agent_only**: for `AUTH=key`, `bin/ssh` runs ssh with `BatchMode=yes`, `IdentitiesOnly`-free agent use,
   `StrictHostKeyChecking=yes` and no `-i`; with no key in the agent it exits 3 and prints, for the developer:
   `load your key once, in your own terminal: ssh-add --apple-use-keychain <key>` (Linux: `ssh-add <key>`).
3. **ssh_password_store**: for `AUTH=password`, the password reaches ssh only through `bin/askpass` (`SSH_ASKPASS`,
   `SSH_ASKPASS_REQUIRE=force`) reading `bin/secret ssh.<name>`; the test finds it in no argument, no environment
   variable, no file the run leaves, and nothing printed.
4. **ssh_missing_secret**: with no `ssh.<name>` stored, `bin/ssh` exits 3 before connecting and prints: ask the
   developer to run, in their own terminal, `bin/secret --set ssh.<name>` (a hidden prompt); never ask for it in chat.
5. **ssh_trust**: an unknown host key stops the run (exit 3) with `bin/ssh --trust <name>`, which shows the host's
   fingerprint and adds it only on the developer's typed yes at a terminal; an agent session cannot run `--trust`.
6. **ssh_asks**: a PreToolUse hook (hub root and folder settings) asks before every `bin/ssh` to a `PROD=1` host and
   before any raw `ssh`, `scp`, `sftp`, `rsync -e ssh` or `sshpass` command; `bin/ssh` to a non-production host does not ask.
7. **ssh_rule**: the hub's CLAUDE.md template and the ops persona text say: never ask for a password, key or passphrase in
   chat; when one is missing, relay the command `bin/ssh` printed.

## Out of scope
Databases (X2), the clipboard and `ade key` (A13), installing keys on servers, session recording.
