# Access registry and bin/ssh (story X1)

Agents reach servers without ever holding a key or a password. The registry says where; the developer's ssh-agent or
the hub's secret store says how; neither ever passes through the agent.

## The registry: `ops/access/<name>.conf`
- `<name>` matches `^[a-z0-9][a-z0-9-]{0,31}$`. `ops/access` is reserved: never an agent folder (`folders()` skips it,
  `bin/new` and `bin/init` refuse it).
- A plain file (not a link), at most 4 KB, one `KEY=value` a line; blank lines and `#` comments are skipped. Never
  sourced: `access_read <name> <kind>` in `bin/lib.sh` parses it and sets `ACC_KIND ACC_HOST ACC_USER ACC_PORT ACC_JUMP
  ACC_AUTH ACC_PROD`. A refusal (exit 2) names the file and the line, never a value.
- Names and locations only. Refused: a key shape anywhere (`bin/paste-guard --scan`, the one `KEYS` list), a line that
  is not `KEY=value` (`^[A-Z][A-Z_]*=`), a key given twice, a key its KIND does not list (a `PASSWORD`, `KEY` or
  `IDENTITY` is never one), and a value outside its grammar:

  | Key | Value | Required |
  |---|---|---|
  | `KIND` | `ssh` (default when missing) | no |
  | `HOST` | host name `[A-Za-z0-9][A-Za-z0-9.-]*` (≤253) or IPv6 address | yes |
  | `USER` | `[A-Za-z_][A-Za-z0-9_.-]*` (≤32) | no |
  | `PORT` | 1-65535 | no |
  | `JUMP` | `[user@]host[:port]` (no IPv6) | no |
  | `AUTH` | `key` or `password` | yes |
  | `PROD` | `0` or `1` (missing counts as `1`) | no |

- KIND picks the allowed keys (`access_keys <kind>`). Another kind (X2: `KIND=db`) adds its row to `access_keys` and its
  value grammars to `access_read`; `access_read <name> ssh` refuses a file of another kind, and the other kind's reader
  refuses an ssh file.
- Committed with the hub, like the rest of `ops/` (names and locations only, nothing secret). Written by the developer;
  there is no helper to create one yet. Until a change is committed it is unconfirmed: while `git status -- ops/access`
  shows anything (changed, staged, new or ignored files), bin/ssh-guard asks before every `bin/ssh`, `PROD=0` or not.
- Edits ask: `Edit`/`Write` of `ops/access/**` are in the root and folder settings' `ask` lists, and bin/ssh-guard asks
  for any Bash command naming `ops/access`.

## `bin/ssh <name> [command...]`
- OpenSSH keeps the first value it gets for an option, so bin/ssh never gives one twice: `StrictHostKeyChecking=yes`
  on a connection, `=ask` on `--trust`, each first on its own path and never in the shared options.
- Every run: `-o ConnectTimeout=10 -o ForwardAgent=no -o ForwardX11=no
  -o PermitLocalCommand=no -o ClearAllForwardings=yes -o ControlMaster=no -o ControlPath=none`, `-l USER`, `-p PORT`,
  `-J JUMP`, then `-- HOST command...` (nothing after `--` is an ssh option). The system's ssh is found first in PATH.
- No command and no terminal on stdin: exit 2 (an interactive shell would wait forever).
- `AUTH=key`: `-o BatchMode=yes`; the developer's ssh-agent, no `-i`, no `IdentitiesOnly`. No agent reachable
  (`ssh-add -l` exit 2): exit 3, `no ssh-agent is reachable (SSH_AUTH_SOCK)`. No key in the agent: exit 3, `load your key once, in your own terminal: ssh-add --apple-use-keychain <key>` (Linux:
  `ssh-add <key>`).
- `AUTH=password`: the password is `ssh.<name>` in the hub's store (`bin/secret`). Not stored: exit 3 before connecting,
  `bin/secret --set ssh.<name> (a hidden prompt); never ask for it in chat`. Stored: ssh runs with `SSH_ASKPASS=<hub>/bin/askpass`,
  `SSH_ASKPASS_REQUIRE=force`, `ADE_SSH_ASKPASS_NAME=<name>`, and
  `BatchMode=no PubkeyAuthentication=no PreferredAuthentications=password,keyboard-interactive NumberOfPasswordPrompts=1`.
- An unknown host key: exit 3, `bin/ssh --trust <name>`. A changed one: exit 3, "has CHANGED": the server's admin
  confirms first, then the developer runs `ssh-keygen -R <host>` and `bin/ssh --trust <name>`. With a `JUMP`, the
  message says the key may be the jump host's.
- Exit: ssh's own; 2 a bad name, registry file or use; 3 the developer must act (the command is printed for the agent
  to relay, never to run). bin/ssh's own 2 and 3 always come with an `ssh:` or `access:` line on stderr; a 2 or 3
  without one is the remote command's.

## `bin/ssh --trust <name>`
- Refused (exit 2) in an agent session (`in_agent_session`) and without a terminal on stdin and stderr. Runs ssh with
  `StrictHostKeyChecking=ask`, no password, no askpass: ssh shows the fingerprint and saves it only on a typed `yes`.
  Exit 0 saved (or already known), 3 not trusted.

## `bin/askpass <prompt>`
- Prints `ssh.<name>` on stdout (ssh's pipe) and nothing else. Refuses (exit 1, empty stdout) unless: one argument,
  `SSH_ASKPASS_REQUIRE=force`, `SSH_ASKPASS` is this file, a valid `ADE_SSH_ASKPASS_NAME` whose registry file says
  `AUTH=password`, stdout not a terminal, its parent process is named `ssh` (a fake ssh script only under
  `AGENT_PLATFORM_TEST=1`), and the prompt is exactly `<user>@<host>'s password: ` or `(<user>@<host>) …Password:`,
  where `<user>@<host>` comes from the registry through `ssh -G` (`access_login` in `bin/lib.sh`), never from the
  environment. A jump host's prompt, a
  host-key question or a key passphrase gets nothing.
- `bin/secret ssh.<name>` refuses to print in an agent session; `--set`, `--has` and `--forget` work as for any name.

## `bin/ssh-guard` (PreToolUse hook, matcher `Bash`)
- Wired in `.claude/settings.json` (`"$CLAUDE_PROJECT_DIR"/bin/ssh-guard`) and `templates/folder-settings.json`
  (`"$CLAUDE_PROJECT_DIR"/../../bin/ssh-guard`). Asks with
  `{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "ask", "permissionDecisionReason": …}}`.
- Asks before: any raw `ssh scp sftp sshpass rsync slogin autossh mosh ssh-copy-id sshfs ssh-keyscan ssh-keygen`, in
  any letter case (quotes and backslashes removed, `$(…)` and backticks split, `env`/`command`/`bash -c`/paths
  included); `proxycommand`, `sshcommand`, `git_ssh`, `ssh_askpass`, `localcommand`, `askpass`,
  `known_hosts`, `secret_get`, `ade/secrets` or `find-generic-password` anywhere; `ops/access` after normalising the
  path (`ops//access`, `ops/./access`, `x/../`), and `access` with a `cd`; `ssh.<name>` anywhere except in exactly
  `bin/secret --set|--has ssh.<name>` as the shell splits it (a comment, `env -i` or `env -u` in front, or any other
  command asks); a `bin/ssh` that is not this hub's (resolved against the input `cwd`; a relative one after `cd`); a
  `bin/ssh` that is not the first word of a simple command, or that follows a command other than `cd` or another
  `bin/ssh` (`xargs`, `find -exec`, `timeout`, `nohup`, `time`, `sudo`, `bash -c`, `true; bin/ssh` all ask); any
  `bin/ssh` while the registry differs from HEAD; `bin/ssh` with `--trust`, `$(…)` or backticks, an environment change before it (`X=…`, `env`, `export`, `eval`, `source`, `.`,
  `unset`…), or a first argument that is not a plain name as both the guard and the shell (`shlex`) split it (so a
  redirection such as `bin/ssh >dev prod` asks); `bin/ssh` to a `PROD=1` host or one `access_read` refuses (20 s for
  all lookups). `bin/ssh` to a `PROD=0` host does not ask, whatever its remote command holds. An unreadable input, or
  no python3, asks when the input names ssh.

## Limits kept on purpose
- The agent runs as the developer: a determined same-user process can still read the store (Keychain, file store)
  directly, or hide a command from the hook (`${x}sh`, a script it wrote). The hook narrows mistakes; it is not a sandbox.
- A hook "ask" follows Claude Code's permission mode (a bypass mode does not ask).
- A jump host's own host key is checked by the developer's ssh config, not `--trust`.
- A committed registry change passes: the guard trusts `ops/access` as committed at HEAD. A commit that flips `PROD`
  shows in review and history, not in the hook; so does a change made outside the hook's sight (a script the agent
  wrote) once committed.
- `bin/ssh --trust`'s agent-session refusal reads environment variables: a process that drops them (`env -u`, a Python
  `pty.fork()` that clears the CLAUDE* variables and types `yes`) gets past it, and the hook asks only when it sees
  `--trust` in the command. Like bin/secret's refusal and askpass's parent check, it is a guard against mistakes.
- bin/askpass's parent check reads the process name: a same-user process named `ssh` passes it. It is a guard against
  mistakes, not a boundary; so is `bin/secret ssh.<name>`'s agent-session refusal (`env -u` defeats it). Both yield
  only what the store already yields to that user.
