# C8: `bin/chat send`, an image or a file to the owner

Status: In review (2026-11-23; one fix round after the adversarial review). Risk: high (a file leaves the machine, in
a request that carries the bot token). Depends on C5 (the orchestrator on Telegram) and the chat lock (`lock_of`, the
auto-mode rule). Owner's intent (2026-11-23): "Ade should have a screenshot tool as well for proofs", then "Can be
attached to tg as well": ade-cli's `ade shot --tg` (its story A20) sends through this command.
Verification command: `bash tests/run.sh`. Contract: `.ade/context/chat.md`, "Sending an image or a file".

## Goal
`bin/chat send [--document] <file>`, the caption on stdin, sends one image (PNG or JPEG, at most 10 MB) or, with
`--document`, one file (at most 20 MB) to the paired owner, and only while the bot is locked to the owner. The token is
handled as `say` handles it. Files that hold keys, sign-ins or the hub's state are never sent, whoever asks.

## Acceptance criteria (`tests/test_chat_send.sh`; a stand-in Bot API on 127.0.0.1, a fake `security`; fake values built at runtime)
| AC | Criterion | Test |
|---|---|---|
| 1 | A PNG or JPEG (by its first bytes) of at most 10 MB goes to the one locked owner with `sendPhoto`, as one multipart request with the caption; the send is journaled and exits 0 | `send_photo_to_locked_owner` |
| 2 | `--document` sends any one file of at most 20 MB with `sendDocument`; a larger one is refused | `send_document` |
| 3 | Without `--document`, a file that is not a PNG or JPEG, is over 10 MB, is empty or is missing is refused (exit 2), and nothing is sent | `only_images_as_photos` |
| 4 | Nothing is sent unless `lock_of` says locked (pairing policy, two ids, a group, a JSON number id, the older `policy` key, unreadable JSON, no file, a linked or loosely writable access file): exit 2 with the reason | `refused_unless_locked` |
| 5 | Never sent: a link, a folder, a pipe, a `.env` (`.env`, `.env.*`, `*.env`), and a file whose real path is under the state folder, `~/.agent-hub`, `~/.ssh`, `~/.config`, `~/.aws`, `~/.gnupg` or `~/.claude`, also when reached through a linked folder | `never_sent_files` |
| 6 | The token is in no argument of any process, no output, no log and no journal line, also when the send fails; a failure says the Bot API's own reason and keeps nothing; with no token stored, exit 1 | `token_never_shown` |
| 7 | The Bot API host is pinned: `AGENT_TELEGRAM_API` is honoured only as `http://127.0.0.1:<port>` or `http://localhost:<port>`; any other value is refused with one line by `send` and by `say`, and no request is made | `host_pinned` |
| 8 | The opened file is the one judged: a hard link to a refused file, `/dev/fd/<n>` or `/dev/stdin` redirected from one, and a `/proc` path are refused | `opened_file_judged` |
| 9 | The caption is one line with control characters removed and keys hidden, cut to 1024; the file's name in the request holds only letters, digits, `.`, `_` and `-` | `caption_cleaned` |
| 10 | The hub root's and the focus folders' `permissions.ask` cover `bin/chat send`, `ade chat send`, `ade shot screen` and `ade shot ... --tg`; the contract, the README and the usage name the command | `needs_owner_permission`, `documented` (and `fake_channel` for the suite's fake channel) |

## Out of scope
- Keeping a failed send for a retry (the file stays where it was).
- Sending to anyone but the one locked owner; groups.
- The ask rules as a boundary: they match text, so a spacing or quoting variant is not prompted. The lock, the host pin
  and the refused files are the boundary.
