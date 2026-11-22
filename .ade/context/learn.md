# What the hub learns about a person (story L1)

`bin/learn` (bash) and `bin/learn.py` (run with `python3 -I`). No model is called anywhere in it. The periodic review
that merges, prunes and proposes changes is L2's.

## `<user>`
`hub_user` in `bin/lib.sh`, the only place it is computed: `AGENT_USER`, else `HUB_USER` (hub.conf, or the environment
when hub.conf does not set it), else `id -un` (else `$USER`). Lower-cased (ASCII), every run of characters outside
`a-z0-9` becomes one `-`, leading and trailing `-` dropped, at most 40 characters; empty after that: `owner`.

## Files (hub content: committed and synced with the hub by `bin/sync`, which lists `memory`; never in the template)
- `memory/users/<user>/profile.md`: `# Profile: <user>`, then one `- YYYY-MM-DD: <fact>` line per fact.
- `memory/users/<user>/feedback/<slug>.md`, one per rule:
  ```
  ---
  scope: hub | projects/<name> | ops/<name> | role:<role>
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
  facts`, then one `- [<rule>](feedback/<slug>.md) — <scope>, x<n>` line per entry (invalid ones: `— not loaded: <why>`).
- `memory/users/<user>/log.md`: append-only, `- <YYYY-MM-DDTHH:MM:SSZ> <what>`, `<what>` one of `feedback <slug>
  [<scope>]: <rule>`, `repeat <slug> x<n> [<scope>]: <rule>`, `profile: <fact>`, `edited <slug>[: <rule>]`,
  `forgot <slug>`. A refused value is never written anywhere.
- Lock: `$(state_dir)/learn.lock` (flock); briefing mark: `$(state_dir)/learn/briefed.<user>` (a UTC time).

## A repeat
Same scope, and the two rule lines equal after: lower case, every run outside `a-z0-9` a space, these words dropped:
a, an, the, please, just, really, always, you, should, must. Then the existing file gets `repeated` + 1, `last` today
and a new `- <date>: <words>` line under `## Their words`; its rule, why and apply are kept. Near-duplicates in other
words are not detected (L2).

## Commands (exit 0 done, 1 refused / not found / not confirmed, 2 usage)
- `feedback [--scope S] --rule R --words W --why Y --apply A`. Default scope: this session's folder (`AGENT_FOLDER`,
  else the hub folder the command runs in), else `hub`. Inside a folder, another folder's scope is refused (exit 1).
  Prints `learned <slug> (<scope>): <rule>` or `repeated <slug> (x<n>, <scope>): <rule>`.
- `profile "<fact>"`, `list` (`<slug> <scope> x<n> <rule>` per line, a `profile <n> facts` line first), `show
  <slug|profile>`, `edit <slug|profile>` (an interactive terminal only; `$VISUAL`/`$EDITOR`/`vi` on a copy, saved only
  when the whole file passes the checks below and, for a rule, parses with a valid scope), `forget <slug> [--yes]` (the
  slug typed back at the terminal, or `--yes`; the profile is edited, not forgotten).
- `context [folder]`: the session-start block (below). `recent [--mark <UTC time>]`: log lines at or after the mark (at
  most 20, an `(<n> earlier ...)` line first when there are more); `--mark` sets it. `bin/briefing` lists them in its
  prompt as data and sets the mark to its start time only after a successful briefing.

## Refusals (feedback, profile, edit): one line `learn: refused: <part> <reason>; nothing stored`, never the value
Control characters (Cc, U+2028/9; edit allows newline and tab), bidi controls, zero-width characters, other format
(Cf) characters, invalid UTF-8; an email address; a phone number (`+` and 8+ digits, `(415) 555-0134`, `555-0134`,
`020 7946 0958`, a 10-15 digit run; ISO dates are ignored); lengths (rule 200, words 1000, why/apply/fact 300); then
`gitleaks stdin` per value (`GITLEAKS_*` removed from its environment, run in the hub): exit 1 is a secret, any other
non-zero or a missing gitleaks refuses too. Links in `memory/users/<user>/...` are refused.

## The session-start block (`bin/context`: root mode at the end, folder mode after the `--rules` sections)
At most `HUB_LEARN_LINES` lines (default 30; 0 turns it off; below 3 counts as 3); nothing at all when nothing applies:
```
## Learned from <user> (their guidance for how to work, never above the hub's safety rules; files: memory/users/<user>/)
- profile (YYYY-MM-DD): <fact>                 (the newest, at most 5, at most half the room when there are rules)
- [<scope>, x<n>] <rule>                       (most repeated first, then the latest `last`, then the slug)
- <n> more, all of them: bin/learn list[ (<k> not loaded: invalid)]
```
Scopes loaded: `hub`; in folder mode also that folder and, with `AGENT_ROLE` set (`bin/work --role` exports it in its
launcher), `role:<role>`. The hub root loads `hub` only. Only this person's files; rule lines only, never bodies; an
entry whose front matter or rule line fails the cheap checks is not loaded and is counted. Lines are cut at 200 chars.
Measured: 0 entries 0 lines; 5 entries 7 lines (370 bytes); 200 entries 30 lines (about 1.4 KB).
