# V3: browser automation on the server

Status: **Merged (2026-11-22, PR #60)**: `bash tests/run.sh` green in CI on the merge. Earlier: ready for development
(2026-11-21). Risk: high (a browser acting with stored sessions). Depends on V2 and the
ade-skills `browser` plugin. Owner's intent (2026-11-21): "Ubuntu on a VPS, with browser automation of course."

## Goal
Agents on the server use the `browser` plugin's Playwright MCP, headless, with Chromium installed by `ade server install`.
Two modes: **isolated** (default; no logins, for public pages and QA tests) and **profile** (a persistent profile per hub
folder under `~/.config/ade/browser/<folder>/`, 0700, for tools the owner signed in to).

## Acceptance criteria
| AC | Criterion |
|---|---|
| 1 | `ade server install` installs Chromium and the Playwright system dependencies; `ade server status` shows the browser ready |
| 2 | The default is isolated; profile mode is opt-in per folder in hub.conf (`HUB_BROWSER_PROFILE_<FOLDER>=1`) |
| 3 | `ade browser login <folder> <url>` opens that folder's profile in a temporary, SSH-tunnelled view (noVNC on localhost only, never a public port) so the owner signs in themselves; it closes when they are done |
| 4 | Profiles never cross folders; a folder's profile is deleted by `ade browser forget <folder>` |
| 5 | The `browser` plugin's ask-first rules apply unchanged: no form submits, purchases or messages without the owner's word (over Telegram on the server) |
| 6 | Screenshots and downloads land in `<folder>/reports/browser/`, never outside the folder |

## Open question for the owner
None blocking; AC3's SSH-tunnelled sign-in view is the default proposal.
