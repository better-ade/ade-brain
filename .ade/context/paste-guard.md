# Paste guard (story K2)

- `bin/paste-guard` is a `UserPromptSubmit` command hook in the hub root `.claude/settings.json` and in
  `templates/folder-settings.json`, listed before `bin/changes`. It takes no argument.
- A prompt holding a key shape gets, on stdout with exit 0:
  `{"decision": "block", "reason": "<message>", "hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "suppressOriginalPrompt": true}}`.
  `suppressOriginalPrompt` keeps Claude Code's block message from repeating the prompt (it would show the key).
  The reason names only the kind(s) and `ade keys set <tool>` / `bin/keys set <tool>`; never the key.
- Anything else, a malformed input, a missing `python3` or an internal error: exit 0, nothing on stdout (the prompt goes on).
- The key shapes are one list, `KEYS` in `bin/paste-guard`: Anthropic, OpenAI-style `sk-`, GitHub, GitLab, Slack, AWS
  `AKIA`/`ASIA`, Google `AIza`, Telegram bot token, PEM or PGP private key header, GLM `<32 hex>.<16>`. No generic
  long-random-string rule. The prompt is checked as given and after removing escapes and zero-width characters, NFKC
  folding, dash lookalikes, and joining a key hard-wrapped over two lines.
- `HUB_PASTE_GUARD=off` in the committed hub.conf turns it off. The hook reads it itself, from its own hub's hub.conf
  alone (a subshell), never the environment, `.local/hub.conf` or a hub `$HUB` names. It is also a policy key in
  `hub_policy_vars` (bin/lib.sh), so other scripts see the committed value too.
- Sharp edges kept on purpose: a key glued to a letter is caught for the specific prefixes (sk-ant-, gh*_, glpat-, AIza)
  but not for generic `sk-`, AWS or Slack; `sk-` and Slack need a digit (and `sk-` a 20+ run with no `-`), so kebab-case
  text passes; AWS documentation ids ending in EXAMPLE pass. Prose quoting a PEM private key header is blocked.
- `bin/doctor` warns for a folder whose settings lack it; `bin/new --settings <folder>` adds it.
- Limit (Claude Code): a blocked prompt can still be in local files such as the session transcript and prompt history.
- `bin/paste-guard --scan` (story X1): the same `KEYS` over plain text on stdin, for bin/ code (the access registry):
  exit 10 when it holds a key shape, 0 when not, anything else when it cannot tell (no python3, an error: callers
  refuse); prints nothing. It never reads hub.conf: the `HUB_PASTE_GUARD` switch does not apply to it.
