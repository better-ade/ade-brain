# K1: users are told how their keys are kept safe

Status: **Approved** (owner, 2026-11-26: "yes to all go", on the drafted text). Risk: **high** (it changes `bin/keys`,
which is on the secrets path; the rules make anything touching secrets high, whatever its size).
Verification: `bash tests/run.sh`.

## Goal
How a key is secured is spread over the README's sharing section and one line elsewhere. A user should learn it in one
place, and hear it at the moment they store a key.

1. README: a section **"Keeping your keys safe"**, placed just before "Handing keys to another person", with this text
   (owner-approved; keep it):

   - **Type a key once, in your own terminal.** `bin/keys set <tool>` asks at a hidden prompt, or reads stdin. Never put
     a key on a command line, in a chat with an agent, or in a file such as `.env`: agents are told never to ask for one.
   - **It lives in a real secret store.** The macOS Keychain by default; on Linux a file store only you can read
     (folders `0700`, files `0600`; `bin/doctor` calls it the weaker store). Choose `pass` with `HUB_SECRET_STORE` in
     `hub.conf`, the only place that can set it.
   - **It is never shown or copied out.** A value moves only on stdin or in the script's own variables: never the
     environment, a log, git, or a file outside the store. `bin/keys` shows only stored or missing;
     `bin/keys forget <tool>` removes one.
   - **Agents can't read it.** Delegated agents have read-only tools, and deny rules keep secret files (`.env*`,
     `*.pem`, `.ssh/` and others) from them.
   - **To give a key to someone, seal it.** Use `bin/keys share` (below), never a chat message or an email with the
     value in it.

2. `bin/keys set <tool>`: after the key is stored, one line on stderr:
   `keys: <tool> stored in <store label>; agents never see it. Share it sealed: bin/keys share <github-user> <tool>`
   (store label from `secret_store_label`). Nothing on a failed or cancelled store. Never the value.

## Acceptance criteria (tests in `tests/test_keys.sh` unless named)
1. **readme_keys_safe**: the README has the section, before "Handing keys to another person", and every command and
   setting it names exists (`bin/keys set`, `bin/keys forget`, `bin/keys share`, `HUB_SECRET_STORE`, the deny patterns
   named appear in the hub's deny rules, `0700`/`0600` match lib.sh).
2. **set_says_where**: `bin/keys set glm` (value on stdin) prints the line above with the store's label, on stderr, and
   stores the key.
3. **set_fail_quiet**: a refused or failed store prints no "stored in" line and exits non-zero.
4. **set_no_value**: the value never appears on stdout, stderr, in process arguments of anything `bin/keys` starts, or in
   files outside the store (same style as the existing no-leak tests).

## Out of scope
Changing how keys are stored or shared; the website (story W-keys-safe).
