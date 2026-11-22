# Browser automation on the server (contract, story V3)

Agents on the server use the Playwright MCP with headless Chromium. The ade-skills `browser` plugin owns the ask-first
rules (no form submit, purchase or message without the owner's word, asked over Telegram on the server); the hub runs
each folder's MCP server and says where its browser state and files live. `ade browser login|forget` (ade-cli) runs
`<hub>/bin/browser login|forget`.

## Wiring (the per-folder MCP override)
- `bin/new` (and `bin/new --settings <folder>`, which keeps a `.bak`) writes `<folder>/.mcp.json` from
  `templates/folder-mcp.json`: a `playwright` server whose command is `<hub>/bin/browser run <folder>`, and the folder
  settings set `"enabledMcpjsonServers": ["playwright"]`. The plugin's skill uses this server when the folder has it
  (tools `mcp__playwright__*`), and its own `plugin:browser:playwright` server only elsewhere.
- `bin/browser run <folder>` execs `npx -y @playwright/mcp@0.0.84` (`browser_mcp_pkg` in `bin/lib.sh`, the one pin)
  with that folder's arguments. `bin/server install` installs Chromium with that same package's Playwright:
  `npx -y @playwright/mcp@0.0.84 install-browser --with-deps chromium` (system libraries via sudo).

## `bin/browser`
- The hub is the one the script lives in; `$HUB` counts only when `AGENT_PLATFORM_TEST=1` (tests).
- `mcp <folder>` prints `{"args": [...]}`, the arguments `run` uses: `--browser chromium --headless`, then `--isolated`
  (default: no logins) or `--user-data-dir <profile> --config <profile>/ade-mcp.json` (profile mode; the config sets
  Chromium's `--disk-cache-dir=<profile>/cache`), then `--output-dir <hub>/<folder>/reports/browser`. Before anything is
  made, neither `reports` nor `reports/browser` may be a link, and afterwards the real path must be
  `<real folder>/reports/browser` (else exit 1). `projects/*/reports/browser/` and `ops/*/reports/browser/` are in
  `.gitignore`. No flag that loosens the plugin's rules is ever added.
- `login <folder> <url>` (profile mode only, else exit 2 naming the switch; `http(s)` URLs only; refused while the
  profile is open): checks `127.0.0.1:${HUB_BROWSER_VIEW_PORT:-6080}` is free, writes an MIT-MAGIC-COOKIE-1 cookie
  into a private temp folder, starts Xvfb with `-displayfd`, `-auth <cookie>` and `-nolisten tcp` (and `kill -0`s it),
  Chromium on the profile (`XAUTHORITY`, `--disk-cache-dir=<profile>/cache`), x11vnc `-auth <cookie> -localhost
  -nevershared` with a one-time password from a 0600 file it deletes (`rm:`), and websockify (noVNC) on 127.0.0.1.
  Only when x11vnc and websockify are alive and listening does it print the `ssh -N -L` tunnel, the address and the
  password; otherwise it stops everything, prints no password and exits 1. Enter, closing the browser, or
  `HUB_BROWSER_VIEW_MINUTES` (default 10) ends the view and every process it started; the temp folder is removed.
- `forget <folder>` deletes the profile (cache included); refused (exit 1) when the profile root or the profile is a
  link, or while its `SingletonLock` names a live process.
- `status` prints `ready  chromium <path>` or `missing ...` (exit 1).

## Profiles
- `${AGENT_BROWSER_DIR:-${XDG_CONFIG_HOME:-~/.config}/ade/browser}/<key>/`, key = the full folder path with `/` as `-`
  (`projects/acme` -> `projects-acme`, `ops/x` -> `ops-x`, `projects/ops-x` -> `projects-ops-x`), 0700 and the user's.
- Profile mode is opt-in per folder in `hub.conf`: `HUB_BROWSER_PROFILE_<KEY>=1` (key upper-case, `-` as `_`:
  `HUB_BROWSER_PROFILE_PROJECTS_ACME`). Every `HUB_BROWSER_PROFILE_*` is unset before `hub.conf` is sourced, so the
  environment cannot turn it on. Folder names are `[a-z0-9-]` (bin/new), so no two folders share a key.
- Chromium is Playwright's (`${PLAYWRIGHT_BROWSERS_PATH:-~/.cache/ms-playwright}/chromium-*/chrome-linux*/chrome`).

## Isolation is policy, not a Unix boundary
Every folder's agent runs as the same Unix user, so the OS does not stop one folder's agent from reaching another
folder's profile. The separation is policy, held by Claude Code permissions in the hub root and every folder's
settings: `deny` `Read(~/.config/ade/browser/**)` and `Edit(~/.config/ade/browser/**)`; `ask` for the Playwright
tools that act (`browser_click`, `browser_type`, `browser_fill_form`, `browser_file_upload`, `browser_press_key`,
`browser_select_option`, `browser_evaluate`, as `mcp__playwright__*` and `mcp__plugin_browser_playwright__*`), for
`Bash(*bin/browser login*)`, `Bash(*bin/browser forget*)`, `Bash(*ade browser*)`, and for edits to `hub.conf`
(`Edit(...hub.conf)`, `Bash(*hub.conf*)`), which holds the profile switches. A Bash command that reads a profile
by another path is not caught by these rules; true separation needs one Unix user per folder.

## Install and status (`bin/server`, `.ade/context/server.md`)
- `bin/server install` adds `xvfb x11vnc novnc websockify` to its packages and, when Chromium is missing, runs the
  install-browser command above; Chromium must be found afterwards.
- `bin/server status` adds a `browser` row: `ready (headless Chromium, <path>)` or `missing (bin/server install)`.
