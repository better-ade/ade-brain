# O1: review a brain you load

risk: medium (a new read-only script that adopt and import call; it reads names, never the key store or a secret)
Status: **Approved** by the owner's own words (2026-11-28): "Yes please both". The ask (2026-11-28): "As part of loading a brain, we
need a way for user to review / summarize the existing brain (if its existing, shared or handed over)".

## Story
As a person who loads a hub someone else built (shared with me, handed over, or my own on a new machine), I want one
plain summary of what the brain holds before I start work in it, so I know whose it is, what is in progress, what it
remembers and what it can reach, without reading every folder.

## Design
A new read-only `bin/review` prints the summary to stdout; it writes nothing, runs no network call and never opens
the key store. Sections, each skipped when empty:

1. **Hub**: name, owner, persona title, suggested model (from `hub.conf` and the persona front matter).
2. **In progress**: each folder with the first item of its STATE.md "Live", "Open" and "Waiting on" (bin/context's
   reading, not a new one); folders whose STATE is still the template are counted, not listed.
3. **Recent**: the last 5 journal entries (folded, story J1) and the last commit: date and author.
4. **Memory**: the number of entries in `memory/MEMORY.md` and its first 10 index lines; the people with a
   `memory/users/<name>/` folder (names only).
5. **Reach**: the repos in the `## Code` rows of the ACCESS.md files; the key *names* in `HUB_SECRETS` (whether each is
   stored here stays in adopt's "Left to do by hand"); the schedules `bin/schedule` would install (names and times).
6. **Agents and skills**: the agent and skill names under `.claude/`.

`bin/adopt` prints it after its work and before "Left to do by hand:" in every mode, so `ade hub import` (which runs
adopt) shows it too. A person can run `bin/review` any time; `bin/review <folder>` limits sections 2 and 3 to one
folder. Content is data: lines taken from STATE, journal and memory are printed as text, cut at 200 characters.

## Acceptance criteria
1. **review_sections** (tests/test_review.sh): on a test hub with a folder in progress, journal entries, memory and a
   `## Code` row, `bin/review` prints the six sections with those values.
2. **review_read_only** (tests/test_review.sh): the hub's tracked and untracked files are byte-identical after a run,
   and it makes no `security`/`secret-tool`/`bin/secret` call (stub records any).
3. **review_empty_hub** (tests/test_review.sh): a fresh hub from bin/init prints Hub and Agents and skills only, exit 0.
4. **review_folder** (tests/test_review.sh): `bin/review projects/demo` shows that folder only; an unknown folder
   exits 2 and names it.
5. **review_cut** (tests/test_review.sh): a 500-character STATE line prints at most 200 characters.
6. **adopt_shows_review** (tests/test_adopt.sh): share, handover and clone each print the review before
   "Left to do by hand:"; after a handover it names the new owner.
7. The verification command passes (`bash tests/run.sh`).

## Out of scope
An `ade hub review` command in ade-cli and the Better Terminal view (follow-on stories once this output is settled);
an AI-written summary (bin/briefing already does that, and it needs a model call); changing what adopt rewrites.
