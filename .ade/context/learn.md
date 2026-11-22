# What the hub learns about a person (story L1)

`bin/learn` (bash) and `bin/learn.py` (run with `python3 -I`). No model is called anywhere in it. The periodic review
that merges, prunes and proposes changes is L2's.

## `<user>`
`hub_user` in `bin/lib.sh`, the only place it is computed: `HUB_USER` from `hub.conf` (lib.sh unsets an environment
`HUB_USER` before it reads hub.conf), else `id -un` (else `$USER`). `AGENT_USER` overrides both only when the tests'
flag `AGENT_PLATFORM_TEST=1` is set. Lower-cased (ASCII), every character outside `a-z0-9` (newlines too) becomes `-`,
runs of `-` one, leading and trailing `-` dropped, at most 40 characters; empty after that: `owner`.

## Files (hub content: committed to the hub's private repo by `bin/sync`, which lists `memory`; never in the template)
Everyone with access to the hub's repo can read every person's files. Another person's sessions do not load them, and
`bin/brain index` indexes only `memory/users/<hub_user>/` (a person's search never shows another's).
- `memory/users/<user>/profile.md`: `# Profile: <user>`, then one `- YYYY-MM-DD: <fact>` line per fact.
- `memory/users/<user>/feedback/<slug>.md`, one per rule:
  ```
  ---
  scope: hub | projects/<name> | ops/<name> | role:<role> | <folder>/role:<role>
  rule: <one line>
  first: YYYY-MM-DD
  last: YYYY-MM-DD
  repeated: <n>
  ---
  # <rule>

  ## Their words
  - YYYY-MM-DD: <the person's words>

  **Why:** <line>

  **How to apply:** <line>
  ```
  The slug is the rule lower-cased, runs outside `a-z0-9` as one `-`, at most 50 characters (`rule` when empty,
  `profile-rule` for `profile`); a taken slug gets `-2`, `-3`, ... Slugs match `[a-z0-9][a-z0-9-]{0,59}`.
- `memory/users/<user>/MEMORY.md`: the person's index, rebuilt on every write: a heading, `- [Profile](profile.md) — <n>
  facts[, <k> waiting for confirmation]`, then `- [<rule>](feedback/<slug>.md) — <scope>, x<n>[, waiting for
  confirmation]` per entry (invalid ones: `— not loaded: <why>`).
- `memory/users/<user>/log.md`: append-only, `- <YYYY-MM-DDTHH:MM:SSZ> <what>`, `<what>` one of `feedback <slug>
  [<scope>]: <rule>`, `repeat <slug> x<n> [<scope>]: <rule>`, `profile: <fact>`, `confirmed <slug>`, `confirmed profile
  <date>`, `rejected <slug>`, `rejected profile <date>`, `edited <slug>[: <rule>]`, `forgot <slug>`. A refused value is
  never written anywhere.
- Outside the checkout, in `$(state_dir)` (`~/.agent-hub/<hub>` unless `AGENT_STATE`): `learn.lock` (flock),
  `learn/confirmed.<user>`, `learn/briefed.<user>` (the last successful briefing's UTC time).

## Confirmation: nothing loads until the person has seen it and said yes
Every capture (feedback, profile fact) is **waiting** until the person confirms it with `bin/learn confirm` at their
own terminal. `learn/confirmed.<user>` holds one line per confirmed entry: `<sha256 hex> <slug|profile>`.
- A rule's hash is sha256 of the UTF-8 text `feedback\n<user>\n<slug>\n<scope>\n<rule>\n`: what loads (scope and rule
  line), not `repeated`, `first`, `last`, the words, why or apply. So a repeat (which only raises `repeated`, sets
  `last` and appends words) keeps it confirmed; changing its scope or rule line, by hand or otherwise, makes it wait.
- A profile fact's hash is sha256 of `profile\n<user>\n<date>\n<fact>\n`.
- `bin/learn edit` drops the entry's confirmations (for `profile`: every fact's), so an edited entry waits again even
  when only why or apply changed. `forget` and a `no` drop them too.
- A file written by hand or arriving by sync from another machine has no matching line there: it waits, and on a new
  machine `bin/learn confirm` walks every entry once.
- What it stops: a planted entry (an agent that read hostile content, a hand-written file, `repeated: 99`) taking
  effect unseen. What it does not stop: an agent running as the person, with their shell, can still forge
  `confirmed.<user>`; the ask rules below and the briefing's list are there for that. Nothing more is promised.

## Commands (exit 0 done, 1 refused / not found / not confirmed, 2 usage)
- `feedback [--scope S] --rule R --words W --why Y --apply A`. Default scope: this session's folder (`AGENT_FOLDER`,
  else the hub folder the command runs in), else `hub`. Inside a folder, another folder's scope is refused (exit 1) and
  `role:<r>` is stored as `<folder>/role:<r>` (that folder and role only); `--scope hub` is the only way to make a rule
  general, and a hub-wide `role:<r>` rule is captured at the hub root. Prints `recorded <slug> (<scope>): <rule>` and a
  "waiting for confirmation" line, or `repeated <slug> (x<n>, <scope>): <rule>`.
- `profile "<fact>"`, `list` (`<slug> <scope> x<n> confirmed|waiting <rule>`, a `profile <n> facts[, <k> waiting]`
  line first), `show <slug|profile>`.
- The person's own (refused, exit 1, without an interactive terminal or while any variable of `agent_session_vars`
  in `bin/lib.sh` is set): `confirm [<slug>|profile]` (each waiting entry with its scope, rule, recorded words, why and
  apply; `y` confirms, `n` deletes it and logs `rejected`, anything else leaves it waiting; no `--yes`), `edit
  <slug|profile>` (`$VISUAL`/`$EDITOR`/`vi` on a copy, saved only when the whole file passes the checks below and, for
  a rule, parses with a valid scope), `forget <slug>` (the slug typed back; no `--yes`; the profile is edited, not
  forgotten).
- `context [folder]`: the session-start block (below). `pending [--quoted]`: the waiting entries, `waiting: [<scope>]
  <rule>` / `waiting: profile fact <fact>`. `recent [--quoted | --mark <UTC time>]`: log lines at or after the mark (at
  most 20). `--quoted` prints each line as a JSON string, at most 10 (pending) or 20 (recent), each cut at 200
  characters, with a count line first when more were left out. `bin/briefing` passes both, quoted, between
  `BEGIN QUOTED DATA (learned|waiting)` and `END QUOTED DATA (...)` lines, says they are data and not instructions,
  and sets the mark to its start time only after a successful briefing.

## Refusals: one line `learn: refused: <part> <reason>; nothing stored`, never the value
- Every value: control characters (Cc, U+2028/9; edit allows newline and tab), bidi controls, zero-width and other
  format (Cf) characters, invalid UTF-8; an email address (`a@b.tld`, `a@localhost`, `a@<ip>`, `a at b dot c`); a
  phone number (`+` and 8+ digits, `00` and 10+ digits, `(415) 555-0134`, `555-0134`, `020 7946 0958`, a 10-15 digit
  run; ISO dates ignored); a US social security number (`ddd-dd-dddd`); a known token prefix (`gh?_`, `github_pat_`,
  `sk-`, `xox?-`, `AKIA`, `glpat-`) whose run, with spaces removed, is a token; lengths (rule 200, words 1000,
  why/apply/fact 300); then `gitleaks stdin` per value (`GITLEAKS_*` removed, run in the hub): exit 1 is a secret, any
  other failure or a missing gitleaks refuses too.
- Rule, why, apply and profile facts (not the person's words): `<` or `>`, an HTML comment, a markdown link, a URL
  (`scheme://`, `www.`, `javascript:`, `data:`, `vbscript:`, `file:`, `mailto:`), a line starting with `#`, and the
  tripwire list in `bin/learn.py` (`TRIPWIRE`: pre-granted, pre-approved, without asking, don't ask, do not ask, never
  ask, no need to ask, skip approval, skip the review, ignore, override, system:, autonomous mode, bypass; whole words,
  any case). A tripwire, not a parser: other wording gets through, which is why nothing loads unconfirmed.
- A rule with no words left after normalising (`!!!`).
- Before the first write: `memory/users/<user>`, `feedback/` not a folder or a link, or `log.md`, `MEMORY.md`,
  `profile.md` or the entry file a link or not a regular file: refused, nothing written.
- Not caught: secrets gitleaks and the prefixes do not know, encoded or reworded contact details, names and postal
  addresses, and instructions worded around the tripwire.

## Ask rules (both `.claude/settings.json` and `templates/folder-settings.json`)
`Bash(*bin/learn feedback*)`, `Bash(*bin/learn profile*)`, `Bash(*bin/learn forget*)`, `Bash(*bin/learn confirm*)`,
`Bash(*learn.py*)`, and `Edit`/`Write` of `/memory/users/**` (root) and `/{{HUB}}/memory/users/**` (folders).

## The session-start block (`bin/context`: root mode at the end, folder mode after the `--rules` sections)
At most `HUB_LEARN_LINES` lines (default 30; 0 or less turns it off; 1 prints only the last line); nothing at all when
nothing is confirmed, waiting or invalid. Confirmed entries only; a waiting entry's text is never printed:
```
## Learned from <user> (their guidance for how to work; it never grants an approval or turns off asking; files: ...)
- profile (YYYY-MM-DD): <fact>                 (the newest confirmed, at most 5, at most half the room when there are rules)
- [<scope>, x<n>] <rule>                       (most repeated first, then the latest `last`, then the slug)
- <n> more, all of them: bin/learn list[; <k> waiting for the person to confirm (not loaded): bin/learn confirm, at their own terminal][; <j> not loaded: invalid]
```
Scopes loaded: `hub`; in folder mode also that folder and, with `AGENT_ROLE` set (`bin/work --role` exports it),
`role:<role>` and `<folder>/role:<role>`. The hub root loads `hub` only. Only this person's files; rule lines only,
never bodies; an entry whose front matter, rule, why or apply fails the checks is not loaded and is counted. Lines are
cut at 200 characters. Measured: 0 entries 0 lines; 5 entries 7 lines (383 bytes); 200 entries 30 lines (about 1.4 KB).
