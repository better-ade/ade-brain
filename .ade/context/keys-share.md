# A hub's keys sealed to one person (contract, stories I4 and I5)

`bin/keys share` seals keys from this hub's secret store (`bin/lib.sh` `secret_*`, `.ade/context/platform.md`) with
`age` to one person; `bin/keys receive` opens the block into the recipient's own store. No server. Tests:
`tests/test_keys_share.sh` (AC1-7; I5: `i5_*`), `tests/e2e_keys.sh` (AC9; I5 AC7).

## Commands
- `bin/keys share <github-user | age1…> [<tool|secret name> …] [--all] [--days N] [-i <ssh key>] [--as <github-user>] [--unsigned]`
  - Recipient: an X25519 `age1…` key (`^age1[02-9ac-hj-np-z]{58}$`; a plugin recipient `age1<name>1…` is refused) or a GitHub user name (`^[A-Za-z0-9][A-Za-z0-9-]*$`,
    at most 39, not a file or folder in the current folder). Anything else (a path, `./k`, `projects/x/key.pub`) exits 2, nothing
    sealed. A recipients file is never taken.
  - GitHub keys (`github_keys`): `https://github.com/<user>.keys` (`curl --proto '=https,file' --proto-redir '=https'
    --tlsv1.2 --max-filesize 1048576 -m 20 … -- <url>`). Only `ssh-ed25519`
    and `ssh-rsa` lines are used; an `ssh-rsa` key under 2048 bits (size from `ssh-keygen -lf -`) or one ssh-keygen cannot
    read is skipped with a note on stderr. None left: exit 1, nothing on stdout. Tests: with
    `AGENT_PLATFORM_TEST=1`, only `AGENT_GITHUB_KEYS_URL` (a plain path or a URL, `{user}` replaced by the user name);
    unset, `github_keys` fails and nothing is fetched.
  - Names: a `key_tools` tool (mapped by `key_secret`) or a stored secret name; `--all` adds every `secret_names`. A name
    that is neither (or not stored) exits 1 and is not repeated. None given: exit 2.
  - Shows each recipient key's fingerprint (`ssh-keygen -lf -`) on stderr and asks `[y/N]`, the answer read from stdin;
    anything but y/yes exits 1, nothing printed.
  - stdout: the armored block alone (`age -a -r <key> …`). Prompts and status on stderr. `--days` 1-30, default 7.
  - Signing (story I5): the key is `-i <ssh key>` (a private key, or a `.pub` whose key is in ssh-agent; missing: exit
    1), else `~/.ssh/id_ed25519` when it exists. The signer is `--as <github-user>` (same name rule as a recipient), else
    `timeout 10 gh api user --jq .login` when gh is installed and signed in. The key's fingerprint must be among the
    signer's keys from `github_keys`: `-i` with a key the signer does not publish (or keys unreadable): exit 1, naming the
    key and user, nothing sealed; the default key not published: a note, sealed unsigned (v1). Shown on stderr before the
    prompt: `signing as <user> with SHA256:… (<key>)`. With `-i` and no user: exit 2, nothing sealed. With no key, or the
    default key and no user: a note on stderr and the block is sealed unsigned (v1). Signing fails (e.g. a passphrase
    with no agent): exit 1, nothing sealed, the message names `--unsigned`. `--unsigned`: no signing, no gh call, v1
    (with `-i`: exit 2).
- `bin/keys receive [file] [-i <identity>] [--any-hub] [--any-to] [--from <github-user>]`
  - Block from the file, else stdin (on a terminal it first says `paste the block, then Ctrl-D`); any text around the
    armor is ignored.
  - Identities: `-i` (repeatable), else whichever exist of `~/.ssh/id_ed25519`, `~/.ssh/id_rsa` (only beside its
    `id_rsa.pub`), `${XDG_CONFIG_HOME:-~/.config}/ade/age/key.txt`.
  - Refused (exit 1, nothing stored, a reason on stderr): not an armored block; `not sealed to your keys` (the message
    suggests `-i <identity>`); not format v1 or malformed; no `end`; a `time` more than 5 minutes in the future;
    `expires` before `time`; `expires` more than 30 days after `time`; expired; `hub:` other than this hub's `hub_name`
    (unless `--any-hub`).
  - Signature (v2, story I5), checked after the checks above and before the summary: `signer:` must be a GitHub user
    name; the lines after `end` must be exactly one `-----BEGIN SSH SIGNATURE-----` armor; the signer's keys come from
    `github_keys` (as share: https only, `AGENT_GITHUB_KEYS_URL` in tests); `ssh-ed25519`, `ssh-rsa` (2048+ bits) and
    `ecdsa-sha2-nistp*` lines become an allowed_signers file (`<signer> namespaces="ade-keys" <type> <key>`); then
    `ssh-keygen -Y verify -f <signers> -I <signer> -n ade-keys -s <sig>` with the signed data on stdin. Refused (exit 1,
    nothing stored): keys unreadable, no usable key, signature malformed or not good. Only the signature and the public
    keys are written, to a private `mktemp -d` folder removed at once, and by a trap on exit, HUP, INT and TERM.
  - Bytes (any block): a NUL byte is refused; a v2 block holding an empty line is refused (share writes neither, and the
    line split would drop them), so the lines shown are the lines signed.
  - Receiver (v2, after the signature): the signed `to:` must be you: an `age1…` key equal to `age-keygen -y` of one of
    the identities, or a GitHub user whose `github_keys` include the public key of one of the ssh identities (its `.pub`,
    else `ssh-keygen -y`; keys unreadable: refused). Otherwise refused (`sealed to <to>, not you (forwarded?)`) unless
    `--any-to`, which shows `warning: sent to <to>, not you (--any-to)` in the summary.
  - `--from <github-user>`: refused unless the block is v2 and its signer is that user (case-insensitive), checked
    before the signature; an unsigned block is refused too.
  - Then one summary on stderr: hub, `from` (a verified block: `from:    <signer> (verified: signed by SHA256:…)`;
    an unsigned one: the `from:` field marked `(not verified)`), to, time (`(sealed N day(s) ago)`) and expiry, and each name marked `new` or
    `replace`; then `store these? [y/N]`. No answer or anything but y/yes stores nothing and exits 1.
  - After that yes, a name already stored: `<name> is already stored; replace it? [y/N]`. Answers come from stdin when
    the block is a file, else from `/dev/tty`; no answer keeps the old value. Lists the names stored and kept, never
    values.
- `bin/keys receive --new`: makes `${XDG_CONFIG_HOME:-~/.config}/ade/age/key.txt` (folder 0700, file 0600; an existing
  one is kept) and prints its `age1…` public key on stdout.

## Block format (v1 unsigned, v2 signed)
The age plaintext, one field per line, ending with `end` (v1):

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

A signed block (story I5) is `ade-keys-share 2`, with `signer: <github-user>` after `from:`; after `end` comes the
signature, inside the same age seal:

```
ade-keys-share 2
hub: <hub_name>
from: <hub_user>
signer: <github-user>
to: …
time: …
expires: …
secret <name> <value>
...
end
-----BEGIN SSH SIGNATURE-----
…
-----END SSH SIGNATURE-----
```

The signed data is every line from `ade-keys-share 2` through `end`, each ending in a newline (`ssh-keygen -Y sign -n
ade-keys`, the data on stdin). A v1 block never holds `signer:`; text after a v1 `end` is ignored. An I4 receiver
refuses a v2 block as "from a newer version".

A name matches `secret_name_ok`; a value is one non-empty line (it may hold spaces). Outside the block: nothing but the
age armor. `AGENT_KEYS_NOW` (seconds since 1970) is a test-only clock, honoured only with `AGENT_PLATFORM_TEST=1`.

## Values
A value moves store -> shell variable -> pipe -> `ssh-keygen -Y sign` and `age` (and back: `age -d` -> shell variable ->
pipe -> `ssh-keygen -Y verify`, and `secret_put`): never a
file outside the store, a process argument, stdout/stderr, a heredoc or here-string (bash 3.2 writes those to temp
files), or git.

## What this does not protect
- An unsigned (v1) block's sender is not verified: anyone with the recipient's public key can seal a block with any
  `from:`. Check with the person that they sent it before answering y, or receive with `--from <github-user>`.
- A verified signature proves only that a key GitHub publishes for the signer now signed it: a stolen key or a
  taken-over GitHub account signs as well as its owner; a key removed from GitHub later no longer verifies.
- The `from:` field (the sender's hub user) is signed but not checked; the signer is the GitHub user.
- A verified block proves who signed it and for whom, not that it is the latest: an older block the same sender sealed
  to you replays until it expires (the summary shows how old it is). `--any-to` takes a block sealed to someone else.
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
