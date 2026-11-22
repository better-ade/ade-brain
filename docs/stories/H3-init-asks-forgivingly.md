# H3: `bin/init` asks forgivingly and can be run again

Status: Ready for development (2026-11-22). Risk: medium. Needed by ade-cli A18 (the guided first run).
Owner's intent (2026-11-22): "we need a guide for the user so they can set this up", "an interactive cli".
Verification command: `bash tests/run.sh`.

## What the owner's first test showed
Asked "Persona for this hub (one of the names above)", they typed the persona's title with spaces. `bin/init` said
`no persona '...'` and stopped, leaving a copy that is not yet a hub, and the caller printed a command with
placeholders in it.

## Acceptance criteria (`tests/test_init.sh`, extended; a pseudo-terminal where a question is asked)
| AC | Criterion | Test |
|---|---|---|
| 1 | The persona question numbers the personas and accepts the number, the slug, the title, either ignoring case, spaces, hyphens, underscores and `/`, or a prefix only one persona has; anything else is asked again with one line saying what is accepted | `init_persona_forgives` |
| 2 | `--persona` on the command line accepts the same forms; an unknown value names the closest personas and exits 2 | `init_persona_flag` |
| 3 | The client and owner questions refuse an empty answer and control characters by asking again, and say in a few words what each is used for | `init_asks_again` |
| 4 | End of input at any question stops with exit 1 and one line that gives the exact command to continue, with the answers already given filled in (quoted), never a placeholder | `init_resume_line` |
| 5 | Run again in a copy where an earlier run stopped, `bin/init` finishes it: nothing is asked twice that was given on the command line, and nothing already rendered is damaged | `init_runs_again` |
| 6 | Without a terminal and without the three values, it lists what is missing in one line and exits 2, as today | `init_no_terminal` |
