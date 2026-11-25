# I6: a sealed keys block travels as a one-time link

Status: **Approved** (owner, 2026-11-25: option 2, "a thin --link only": no self-hosted service; replaces the earlier
self-hosted version). Risk: **high** (it is on the keys path; the rules make anything touching secrets high, whatever
its size).
Depends on I4 and I5 (merged; same file, `bin/keys`).
Verification: `bash tests/run.sh`.

## Goal
The block `bin/keys share` prints is already sealed to one person and signed by the sender, so whoever holds the link
can read only ciphertext. A one-time link makes the block easier to send, and it is gone once opened. ADE runs no
server for it: the link goes to any Onetime Secret instance, by default the public onetimesecret.com.

- **Share:** `bin/keys share … --link` posts the armored, sealed block to `HUB_ONETIME_URL` (default
  `https://onetimesecret.com`; https only) as an anonymous secret, with an expiry of 7 days, matching the block. It
  prints the link instead of the block. It needs no account.
- **Receive:** `bin/keys receive <link>` fetches the block once (the link then burns) and goes on exactly as I4/I5:
  it checks the signature and asks before storing anything. It takes only links on `HUB_ONETIME_URL`'s host.
- `hub.conf` carries `HUB_ONETIME_URL` (a location only).
- Before building, the builder checks the instance's current API (anonymous create and retrieve) and records the calls
  used in `.ade/context/` (a small factual file).

## Acceptance criteria (tests run `curl` against a local fake API; nothing reaches the internet)
1. `--link` uploads only the armored, sealed block (the fake API records the body: no value, no plain header) and
   prints one https link. A non-https `HUB_ONETIME_URL` is refused before any request.
2. `receive <link>` opens the block, checks it as I5 does and asks; on yes the values are stored. A second fetch of the
   same link fails with "already opened or expired", and nothing is stored.
3. A link on another host than `HUB_ONETIME_URL`'s is refused before any request.
4. No value appears on stdout or stderr, in files outside the store, in process arguments or in the fake API's log.
5. A service error or timeout on share prints the block as before (nothing lost) and says the link failed.
6. E2E: A shares with `--link` to the fake service; B receives by the link; a second receive fails.

## Out of scope
Running an instance (self-hosting), accounts, a passphrase on the link, and sending plain values through it.
