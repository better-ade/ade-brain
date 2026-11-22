# C7: Telegram: proper formatting, buttons, and talking to focus agents

Status: **Merged (2026-11-21, PR #52)**: `bash tests/run.sh` green in CI on the merge. Earlier: ready for development
(2026-11-21). Risk: high (routes chat messages to running agents). Depends on C5, C6.
Owner's intent (2026-11-21): "when responding to Telegram, use proper widgets or formatting"; "I'd like to talk to these
agents via Telegram."

## Goal
- **Formatting:** the orchestrator's Telegram replies follow a style rule in the hub CLAUDE.md template: short
  messages; Telegram-safe formatting (bold, italics, `code`, code blocks, lists) through the plugin's supported format,
  never raw Markdown tables (they render as noise): tables become aligned code blocks or bullet lists; long output is
  summarised with "full text in <path>"; status replies use a fixed card layout (title line, one line per agent with an
  emoji state ● busy ○ idle ⚠ blocked).
- **Buttons:** where the plugin supports inline keyboards, approvals and common actions are buttons (Approve / Deny,
  Status, Dispatch); where it does not, numbered replies ("reply 1 to approve") are used.
- **Talking to focus agents:** the orchestrator is the switchboard. `/to <folder|agent> <text>` (or "tell api to …")
  sends the text to that agent through `bin/notify` (C6); the agent's replies and its `idle`/`ended`/`blocked` events
  addressed to main are posted back to Telegram tagged `[api]`. `/agents` lists them with their state. Only the paired
  owner can do this; text from Telegram reaching an agent is still marked "from main (claimed)", data not instructions.

## Acceptance criteria (no network: a fake channel records what is sent)
| AC | Criterion |
|---|---|
| 1 | The hub CLAUDE.md template has the Telegram style rule (formatting, no raw tables, length limit, status card) |
| 2 | A status reply built by `bin/chat status --card` matches the card layout exactly (golden test) |
| 3 | `/to api "rebase on main"` produces one `bin/notify` call to the resolved folder; an unknown or ambiguous name gets a reply listing the agents, and no notify |
| 4 | An agent's event addressed to main is forwarded to the channel once, tagged with the agent, formatted per the rule |
| 5 | Approvals are offered as buttons when the plugin supports them, else as numbered replies; either way only the paired owner's answer counts |
| 6 | `/agents` lists agents with folder, role, ticket and state |
