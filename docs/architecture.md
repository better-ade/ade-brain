# ade-brain: architecture

A template for a Claude Code "agent hub": one private repo of Bash and Markdown that holds the context, state and
history of one technical persona's work for one client. `bin/init` turns it into a hub: it writes `hub.conf` (who the
agent is and what it can reach), renders `CLAUDE.md`, `ACCESS.md`, `README.md` and the persona agent from
`templates/hub/` and `personas/<slug>.md`, and pins the Claude install and its config dir and the default models, and creates one folder per work area (`projects/<name>`, `ops/<name>`) with
CLAUDE.md, ACCESS.md, STATE.md, `memory/` and a named agent. Client code lives in its own repos, never in the hub. `bin/brain` indexes the hub's Markdown into `.local/brain.db`
(SQLite FTS5 + vectors from a local Ollama model), rebuilt from the files and never committed.

Lineage: generalized from two working hubs (a multi-client ops hub and a single-client staff-engineer hub).

## Verification command

```
bash tests/run.sh
```

Green means every `tests/test_*.sh` and `tests/e2e_*.sh` prints `ok` (run by `tests/run.sh`) and the command exits 0.
The e2e scripts joined the gate with the owner's approval of story I1, AC7. Changing it needs the owner's approval.
