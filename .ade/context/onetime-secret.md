# Onetime Secret: the calls bin/keys makes (story I6)

Checked 2026-11-25 against the source of `onetimesecret/onetimesecret` (main; the docs site answered HTTP 500), read
only. Nothing was posted to a real instance; hosts were probed with GET `/api/v1/status` and `/api/v3/status` only.
Contract for the commands: `.ade/context/keys-share.md`, "One-time link".

## Which API
- v1 (`POST /api/v1/share`, form fields) is frozen; the project's `docs/architecture/rest-api.md` says not to use it for
  a new integration. bin/keys uses the **v3 guest routes**: anonymous (`auth=noauth`), no account, no API key; anonymous
  API calls are not CSRF-checked. An instance can switch them off (`site.interface.api.guest_routes.{enabled,conceal,
  reveal}`, e.g. `API_GUEST_ROUTES_ENABLED=false`); then share falls back to printing the block.
- Hosts: `https://onetimesecret.com/api/*` answers 404 (HTML); the public instance's API is on its regional hosts,
  `https://us.onetimesecret.com` and `https://eu.onetimesecret.com` (both answer `/api/v1/status` and `/api/v3/status`
  200). The default `HUB_ONETIME_URL` is `https://us.onetimesecret.com`; the link names the same host.

## Create (share)
```
POST <HUB_ONETIME_URL>/api/v3/guest/secret/conceal
Content-Type: application/json
{"secret":{"ttl":<seconds>,"secret":"<armored block, lines joined by \n>"}}
-> 200 {"success":true,"record":{"receipt":{…},"secret":{"identifier":"<id>","key":"<id>",…}},"details":{…}}
```
- The id is `record.secret.identifier` (else `record.secret.key`); the link is `<HUB_ONETIME_URL>/secret/<id>`, the web
  page the service itself shows for a secret.
- Anonymous TTL ceiling: 7 days (`ttl_max_anonymous` 604800); a longer one is clamped by the service.

## Retrieve (receive)
```
POST <HUB_ONETIME_URL>/api/v3/guest/secret/<id>/reveal
Content-Type: application/json
{"continue":true}
-> 200 {"record":{"secret":{…,"state":"revealed"},"secret_value":"<armored block>"},…}
-> 404 once revealed, burned or expired (Onetime::MissingSecret)
```
The first reveal destroys the secret.

## Tests
`tests/fake_onetime.py` fakes exactly these two routes (and logs each request) on `127.0.0.1`; modes `ok`, `error`
(500) and `hang`. No test reaches a real instance.
