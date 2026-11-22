# L2: the learning review

Status: Ready for development (2026-11-22). Risk: high (it proposes changes to the rules every agent follows).
Depends on L1. Owner's intent (2026-11-22): "ensure the feedback loops is there ... so the AI agents adapts".
Verification command: `bash tests/run.sh`.

## Goal
Once a week (and on demand, `bin/learn review`) the hub looks over what it has learned about each person and closes
the loop: it tidies, it measures whether guidance is sticking, and it puts proposals in front of the person. It never
changes a rule by itself.

## Acceptance criteria (`tests/test_learn_review.sh`; the model call is faked)
| AC | Criterion | Test |
|---|---|---|
| 1 | `bin/learn review` reads only the person's own learning files and the journal, and writes one dated report under `memory/users/<user>/reviews/`; it changes no other file | `review_reads_only` |
| 2 | The report lists: guidance repeated since the last review ("not sticking"), entries that say opposite things, entries not confirmed for 90 days (`HUB_LEARN_STALE_DAYS`), and near-duplicates it suggests merging | `review_finds` |
| 3 | A proposal to turn guidance into a standing rule (in the hub rules or a role's persona) is written as a proposal with the exact text and the files it would change; nothing is applied until the person says yes with `bin/learn accept <id>`, at their own terminal | `review_proposes_only` |
| 4 | `bin/learn accept <id>` applies exactly the proposed text and journals it; `bin/learn reject <id>` records the no, and the same proposal is not made again | `review_accept_reject` |
| 5 | One number per person is kept over time: repeats per week (how often they had to say something again); the report shows the last eight weeks | `review_measures` |
| 6 | The weekly job is installed by `bin/schedule` like the others, runs one model call per person at most, and sends one short line through the hub's notify path ("3 things learned, 1 not sticking, 1 proposal"); it never sends the content | `review_scheduled` |
| 7 | Text from the learning files is passed to the model as data; a file that tells the reviewer to do something is reported and not obeyed (a fixture tries) | `review_content_is_data` |
