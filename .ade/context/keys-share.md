# A hub's keys sealed to one person (contract, story I4)

`bin/keys share` seals keys from this hub's secret store (`bin/lib.sh` `secret_*`, `.ade/context/platform.md`) with
`age` to one person; `bin/keys receive` opens the block into the recipient's own store. No server. Tests:
`tests/test_keys_share.sh` (AC1-7), `tests/e2e_keys.sh` (AC9).

## Commands
- `bin/keys share <github-user | age1…> [<tool|secret name> …] [--all] [--days N]`
  - Recipient: an X25519 `age1…` key (`^age1[02-9ac-hj-np-z]{58}$`; a plugin recipient `age1<name>1…` is refused) or a GitHub user name (`^[A-Za-z0-9][A-Za-z0-9-]*$`,
    at most 39, not a file or folder in the current folder). Anything else (a path, `./k`, `projects/x/key.pub`) exits 2, nothing
    sealed. A recipients file is never taken.
  - GitHub keys: `https://github.com/<user>.keys` (`curl --proto '=https,file' --tlsv1.2 … -- <url>`). Only `ssh-ed25519`
    and `ssh-rsa` lines are used; an `ssh-rsa` key under 2048 bits (size from `ssh-keygen -lf -`) or one ssh-keygen cannot
    read is skipped with a note on stderr. None left: exit 1, nothing on stdout. Tests: `AGENT_GITHUB_KEYS_URL` (a plain path or a URL), honoured only with
    `AGENT_PLATFORM_TEST=1`.
  - Names: a `key_tools` tool (mapped by `key_secret`) or a stored secret name; `--all` adds every `secret_names`. A name
    that is neither (or not stored) exits 1 and is not repeated. None given: exit 2.
  - Shows each recipient key's fingerprint (`ssh-keygen -lf -`) on stderr and asks `[y/N]`, the answer read from stdin;
    anything but y/yes exits 1, nothing printed.
  - stdout: the armored block alone (`age -a -r <key> …`). Prompts and status on stderr. `--days` 1-30, default 7.
- `bin/keys receive [file] [-i <identity>] [--any-hub]`
  - Block from the file, else stdin (on a terminal it first says `paste the block, then Ctrl-D`); any text around the
    armor is ignored.
  - Identities: `-i` (repeatable), else whichever exist of `~/.ssh/id_ed25519`, `~/.ssh/id_rsa` (only beside its
    `id_rsa.pub`), `${XDG_CONFIG_HOME:-~/.config}/ade/age/key.txt`.
  - Refused (exit 1, nothing stored, a reason on stderr): not an armored block; `not sealed to your keys` (the message
    suggests `-i <identity>`); not format v1 or malformed; no `end`; a `time` more than 5 minutes in the future;
    `expires` before `time`; `expires` more than 30 days after `time`; expired; `hub:` other than this hub's `hub_name`
    (unless `--any-hub`).
  - Then one summary on stderr: hub, `from` marked `(not verified)`, to, time and expiry, and each name marked `new` or
    `replace`; then `store these? [y/N]`. No answer or anything but y/yes stores nothing and exits 1.
  - After that yes, a name already stored: `<name> is already stored; replace it? [y/N]`. Answers come from stdin when
    the block is a file, else from `/dev/tty`; no answer keeps the old value. Lists the names stored and kept, never
    values.
- `bin/keys receive --new`: makes `${XDG_CONFIG_HOME:-~/.config}/ade/age/key.txt` (folder 0700, file 0600; an existing
  one is kept) and prints its `age1…` public key on stdout.

## Block format (v1)
The age plaintext, one field per line, ending with `end`:

```
ade-keys-share 1
hub: <hub_name>
from: <hub_user>
to: <recipient as given>
time: <UTC ISO 8601, e.g. 2026-11-25T10:00:00Z>
expires: <UTC ISO 8601>
secret <name> <value>
...
end
```

A name matches `secret_name_ok`; a value is one non-empty line (it may hold spaces). Outside the block: nothing but the
age armor. `AGENT_KEYS_NOW` (seconds since 1970) is a test-only clock, honoured only with `AGENT_PLATFORM_TEST=1`.

## Values
A value moves store -> shell variable -> pipe -> `age` (and back: `age -d` -> shell variable -> `secret_put`): never a
file outside the store, a process argument, stdout/stderr, a heredoc or here-string (bash 3.2 writes those to temp
files), or git.

## What this does not protect
- The sender is not verified: anyone with the recipient's public key can seal a block with any `from:`. Check with
  the person that they sent it before answering y.
- The expiry binds only honest software: anyone with the identity can open the block with `age -d` directly, at any time.
- The block reveals a tag of the recipient's key (for an SSH recipient) and its rough size (about how many keys).
- A GitHub recipient: the block is sealed to every `ssh-ed25519` and `ssh-rsa` (2048+ bits) key on that account; any
  of them opens it.
- bin/keys starts with `set +x; unset BASH_ENV`, so an inherited xtrace or BASH_ENV does not print or run code next to
  the values.

## Needed tool
`age` (with `age-keygen`): `bin/doctor` row `age` (MISSING: `tool_install_line age`, `brew install age` on macOS,
`sudo apt-get install age` on Linux); `bin/setup` warns; `bin/server install` installs it (`server_packages`); CI
installs it through `verify.yml`'s `setup` input.

## I2 hook (AC8, deferred: `bin/adopt` does not exist yet)
`bin/adopt --handover` and `bin/adopt --share` print this step for keys, exactly:

```
Keys: bin/keys share <new person> --all   (they run: bin/keys receive)
```

`bin/adopt --handover` also prints, in the old owner's list, exactly:

```
Replace the shared keys at their source (each provider's console), then bin/keys forget <tool> for each.
```

I2's test checks both lines.
