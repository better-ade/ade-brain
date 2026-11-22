# Changelog

## 1.0.0

The core: a hub whose agents work by role, hand work to each other, survive a crash, and can be reached from Telegram, on macOS and on an Ubuntu server.

- **Method from ade-method (C1):** the hub takes its rules, roles and skills from ade-method, pinned (v2.1.0) and synced.
- **Work by role (C2) and dispatch (C3):** `bin/work --role` opens a session on that role's provider and model; `bin/dispatch` starts builders on ready tickets and holds high-risk ones for the owner.
- **Project context in the brain (C4):** `bin/brain index` also reads each project's `.ade/context` and `.ade/knowledge`, so a question about a past decision is answered from the brain.
- **Telegram (C5, C7):** `bin/chat` puts the orchestrator on Telegram, with formatting, approvals and messages to running focus agents.
- **Agents notify each other (C6):** focus agents sync and tell each other about changes through hooks.
- **Crash-proof continuity (R1):** `bin/recover` brings sessions back after a crash or a restart; session ends are safe under a lock (S1b).
- **Monitor triage (M1):** a new alert from `bin/monitor` runs one read-only triage by the monitor role, journaled and notified.
- **Gemini engine (E1):** the Gemini CLI can run builders and focus agents. The Codex engine story (E2) was removed.
- **Hub interface (H1):** the commands that ade-cli's `ade setup` and `ade ui` call, recorded as a contract in `.ade/context/`.
- **Linux and servers (V1, V2, V3):** the hub runs on Linux through a platform layer; `bin/server install` and `bin/server status` set up and check an Ubuntu server, with a safety check and no public port; `bin/browser` gives agents a headless browser there, isolated by default, with a per-folder profile the owner signs in to.
- **Lean sessions:** skills are listed by ade-method's lists; worktrees live outside the repo.
- **Tests and CI:** CI runs on macOS and Ubuntu; each test file has a time limit (`TEST_TIMEOUT`, 600 s) and cleans its temp folder; a newer push cancels the older run.
- MIT license.

## 0.9.0

- The hub template in the better-ade org: focus sessions in ADE, providers behind Claude Code (DeepSeek), role-based models (bin/roles, bin/agent --role, bin/models), provider keys (bin/keys), session end without a hook (S1), coordination reports, sessions status.
- Stories for the core: method from ade-method (C1), work by role (C2), dispatch (C3), project context in the brain (C4), Telegram (C5); monitor triage (M1).
