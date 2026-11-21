# Build worktrees (contract)

Parallel builds use git worktrees **outside** the repository: `../<repo>-wt/<name>` (for this template,
`~/Project/ai-agent-hub-template-wt/<name>`). A worktree under `.claude/worktrees/` carries its own `.claude/skills/`,
and Claude Code lists every skill again per worktree, which multiplies the skill listing in every session. Remove a
worktree when its branch is merged.

Skill listing: `.claude/settings.json` `skillOverrides` applies ade-method's `ade.json` lists: default skills stay on,
on-demand skills are `name-only`, persona, party-mode and metadata skills are `off`. The template ships no `.claude/agents/` (bin/init renders a hub's agents
from its personas); the four core roles are installed per user as `ade-product`, `ade-architect`, `ade-developer`,
`ade-reviewer` in the user's Claude agents folder (front matter added; body from ade-method).
