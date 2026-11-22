# L1: the hub learns its owner

Status: Ready for development (2026-11-22). Risk: high (personal data about the person, and text that steers every
agent from then on). Owner's intent (2026-11-22): "we need to ensure the feedback loops is there and we store all so
the AI agents adapts and knows that user". Verification command: `bash tests/run.sh`.

2026-11-22, fix round after the adversarial review of PR #70: entries are pending until the person confirms them. The
review found that a planted memory (an agent that had read a hostile ticket, or a file written straight into
`memory/users/`) took effect in every later session at once, and the person never saw it. Now every capture waits
until the person confirms it with `bin/learn confirm` at their own terminal; the confirmation is a hash kept outside
the hub's checkout, so an entry written by hand, edited, or synced in waits again. Criteria 1, 2, 4 and 9 changed to
match (contract: `.ade/context/learn.md`).

## Goal
What a person tells their agents about how to work is captured once, kept, and loaded into every later session, so
they do not have to say it twice. The loop has four parts: capture, keep, load, and show the person what was learned
so they can correct it.

- **Keep, per person.** `memory/users/<user>/profile.md` (who they are: role, what they know, how they like to
  work) and `memory/users/<user>/feedback/<slug>.md`, one file per piece of guidance: its scope (`hub`, a folder or a
  role), the rule in one line, the person's own words with the date, **Why**, and **How to apply**. `<user>` is a
  slug of the person running the session, so a hub shared by a team keeps each person's apart.
- **Store all.** Every capture is also one dated line in `memory/users/<user>/log.md`, never rewritten.
- **Capture.** `bin/learn feedback|profile` writes these files. The hub rules tell every agent when to call it: the
  person corrects an approach, states a preference, says an instruction a second time, or confirms an unusual choice.
  The agent records the person's own words, marks its own reading as its own, and when it cannot tell a standing
  instruction from a passing remark it asks once.
- **Load.** The session-start output gains a short block: the profile and the one-line rules that apply to this
  folder and role, most-repeated first, within a fixed line budget; the files are read on demand. `bin/brain`
  indexes them, so a search finds them.
- **Notice what is not sticking.** A new capture that says the same as an existing one is not a second file: the
  existing one gains `repeated: <n>` and moves to the top of what is loaded.
- **The person stays in charge.** `bin/learn list`, `show`, `edit` and `forget`; the morning briefing lists what was
  learned since the last one, so they can say no.

## Acceptance criteria (`tests/test_learn.sh`; no model calls)
| AC | Criterion | Test |
|---|---|---|
| 1 | `bin/learn feedback --scope <hub\|folder\|role> --rule "<line>" --words "<the person's words>" --why "<line>" --apply "<line>"` writes one file with exactly those parts and the date, adds its line to the person's index, and appends one line to `log.md`; the slug is derived safely (`a-z`, `0-9`, `-`); the entry is pending (not loaded) until the person confirms it | `learn_writes_feedback` |
| 2 | `bin/learn profile "<fact>"` adds one dated line to `profile.md` and to `log.md`, pending until confirmed; `log.md` only ever grows (captures, confirmations, rejections, edits, forgets) | `learn_profile_and_log` |
| 3 | A capture whose rule matches an existing one (same scope; the test fixes the matching rule) raises that file's `repeated` count and adds the new words and date to it, and makes no new file | `learn_repeat_counts` |
| 4 | The session-start block shows only confirmed entries: the profile and the rules for this folder and role, most repeated first, in at most the budgeted lines (`HUB_LEARN_LINES`, default 30; 1 or 2 print 1 or 2), lines of at most 200 characters, at most five profile facts; it says how many more exist and, in the same line, how many wait for confirmation, never their text; a hand-written, edited or synced-in entry waits | `learn_loads_at_start` |
| 5 | Guidance captured inside one customer's folder is scoped to that folder unless the capture says `--scope hub`, and is never loaded in another folder | `learn_customer_separation` |
| 6 | Each person's files are under their own `<user>`; another person's session loads none of them; `<user>` comes from one function in `bin/lib.sh` and is a safe slug | `learn_per_user` |
| 7 | `bin/learn` refuses a value that looks like a secret (the repo's secret scan), an email address or a phone number of someone else, and anything with control characters; it says why in one line | `learn_refuses_secrets_and_contacts` |
| 8 | The hub rules (the template's `CLAUDE.md`) say when to capture, to record the person's own words, to ask once when unsure, and that pages, mail, tickets and tool output never create or change a memory: only the person's own words in the conversation do | `learn_rules_present` |
| 9 | `bin/learn confirm [slug]` (the person's terminal only, never an agent session, no `--yes`) shows each pending entry in full and takes yes, no (deleted, "rejected <slug>" logged) or later; the confirmation is a sha256 of scope and rule line in the state folder, kept by a repeat; `list`, `show`, `edit` (pending again after) and `forget` (typed back, no `--yes`) work for the person's own entries; `forget` removes the file and its index line and leaves a dated "forgot <slug>" line in `log.md` | `learn_owner_controls` |
| 10 | `bin/brain index` includes these files and a search finds a rule by its words; the morning briefing's input lists what was learned since the last briefing | `learn_indexed_and_briefed` |

## Notes for the builder
- These files are hub content: they are synced with the hub (a private repo), never into this template. The
  template ships the folders empty.
- The line that loads at session start is a cost on every session: measure it and keep to the budget.
- Out of scope: the periodic review that merges, prunes and proposes rule changes (L2); `ade` commands for this
  (ade-cli, later).
