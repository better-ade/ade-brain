# K2: a key pasted into a Claude prompt is stopped before it is sent

Status: **Approved** (owner, 2026-11-26: "whenever they enter a key, we need to ensure they don't accidentally paste it").
Risk: **high** (secrets path). Verification: `bash tests/run.sh`.

## Goal
A key belongs at a hidden prompt (`ade keys set`, `bin/keys set`). If someone pastes one into a Claude session in the
hub (the root or a folder session) by mistake, the prompt is blocked by a `UserPromptSubmit` hook before the model sees
it, and they are told where the key goes instead:

    That looks like a key (<kind>), so it was not sent. Store it at a hidden prompt: ade keys set <tool>
    (or bin/keys set <tool>). If it was real and already shared somewhere, rotate it.

The hook never prints, logs or stores the key; the message names only the kind (e.g. "Anthropic key"). The prompt is
not added to the conversation.

## What counts as a key (default; one list in one file, shared with redact where it fits)
- Known prefixes: Anthropic `sk-ant-`, OpenAI-style `sk-`/`sk-proj-`, GitHub `ghp_` `gho_` `ghu_` `ghs_` `ghr_`
  `github_pat_`, GitLab `glpat-`, Slack `xox[abprs]-`, AWS `AKIA`/`ASIA` + 16, Google `AIza` + 35, Telegram bot token
  (`digits:35 chars`), a PEM private key header (`-----BEGIN ... PRIVATE KEY-----`), GLM-style `<32 hex>.<16 chars>`.
- Not: git SHAs, UUIDs, base64 in code blocks without a prefix, long words: no generic "long random string" rule
  (too many false positives).
- `HUB_PASTE_GUARD=off` in hub.conf turns it off (hub.conf only, never the environment); default on.

## Acceptance criteria (tests in `tests/test_paste_guard.sh`)
1. **guard_blocks_known**: each kind above, alone or inside a sentence, is blocked (the hook's block output for
   UserPromptSubmit) with the message naming its kind.
2. **guard_passes_normal**: ordinary prompts, a git SHA, a UUID, a code block with a long hash, and the word "sk-learn"
   pass untouched (exit 0, no output).
3. **guard_never_echoes**: the key appears nowhere in the hook's stdout, stderr, logs or any file it writes.
4. **guard_installed**: the hub root `.claude/settings.json` and `templates/folder-settings.json` run it on
   UserPromptSubmit (before `bin/changes`), and `bin/init` and `bin/setup` keep it there; a hub made by bin/init has it.
5. **guard_off**: `HUB_PASTE_GUARD=off` in hub.conf lets prompts through; the same in the environment does not.
6. **guard_fails_open_safely**: a malformed hook input or a missing python exits 0 without blocking normal work, and
   says nothing about any key.

README: one line under "Keeping your keys safe" (when K1 has merged; otherwise next to `bin/keys set`).

## Out of scope
Telegram messages to the bot (a follow-up), shell history, the ade-skills guard plugin for projects outside a hub.
