# E1: Gemini CLI as an engine for builders and focus agents

Status: **Merged (2026-11-21, PR #54)**: `bash tests/run.sh` green in CI on the merge. Earlier: ready for development
(2026-11-21). Risk: high (a second CLI with its own keys, sandbox and data terms).
Owner's decisions (2026-11-21): builders and focus agents can use DeepSeek, GLM, Muse (through Claude Code, as today)
and **Gemini**; the orchestrator stays on Claude Code; GPT/Codex stays paused. Earlier record: ADR 0002 (providers and
engines), `.ade/context/engines.md`, deferred-work "Gemini through Gemini CLI" (2026-11-19).
Verification command: `bash tests/run.sh`.

## Goal
A role can name `gemini:<model>` (e.g. `HUB_ROLE_BUILDER="gemini:gemini-2.5-pro anthropic:opus"`). `bin/work --role`
and `bin/agent --role` then run that work in the **Gemini CLI** inside the same checkout, with the hub's rules, and
with every safety rule the Claude Code path has.

- **Engine table** in `bin/lib.sh`: `claude` (today) and `gemini`. Each engine defines its command, how it gets the
  project rules (Gemini: `GEMINI.md`, or settings pointing it at `AGENTS.md`/`.ade/rules.md`), how the model is
  passed, its approval mode, and how it is signed in.
- **Sign-in:** a Google account login (the CLI's own) or a Gemini API key stored with `bin/keys set gemini` and given
  to the CLI only in the way that keeps it out of child processes where the CLI allows; where it does not, document the
  residual risk in engines.md (the builder verifies against the Gemini CLI docs at build time).
- **Never yolo:** the CLI's auto-approve-everything mode is refused, like `--dangerously-skip-permissions`.
- **Data sharing:** Gemini is opt-in per hub and owner-only by default (`HUB_PROVIDERS_ALLOWED`, `owner_only`), like
  DeepSeek: a customer's hub uses it only when that customer approved it.
- **Gaps stated plainly:** no Claude Code hooks (C6 events), plugins, BMAD skills or Telegram channel in a Gemini
  session; the reviewer (Claude Code) still runs the verification command that decides Done.

## Acceptance criteria (`tests/test_engines.sh`, fake `gemini` CLI, no network)
| AC | Criterion |
|---|---|
| 1 | A role entry `gemini:<model>` is accepted by the role table; `bin/roles` shows it with its engine |
| 2 | `bin/work --role builder` with a gemini pick launches the fake `gemini` in the checkout with the model and the rules file, never Claude Code flags |
| 3 | The yolo / auto-approve-all mode is refused (argument or setting), exit 2 |
| 4 | No sign-in and no stored key: refused before launch with the `bin/keys set gemini` hint; nothing falls back silently |
| 5 | A stored key reaches only the gemini process, never argv, a file in the repo or a log; a fake child sees it only where engines.md says it must |
| 6 | Gemini is refused in a hub that does not allow it (`HUB_PROVIDERS_ALLOWED`) and in a client hub unless enabled |
| 7 | `bin/agent --role` with a gemini pick runs read-only, as the Claude path does |
| 8 | `bin/sessions` shows the engine for a gemini session; `bin/dispatch` can start a gemini builder |
| 9 | engines.md and ADR 0002 record the Gemini engine, its sign-in, its data terms and its gaps |
