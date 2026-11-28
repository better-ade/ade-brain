# T1: in your own terminal, the hub makes sure ade is there and the agent knows its commands

Status: **Approved** (owner, 2026-11-28: "if the user prefers to use their terminal and they load the brain, make sure
we download the ade so it'll know how to use the commands"). Risk: **medium** (it downloads and runs ade's published
installer; no secret, sign-in, data or money).
Verification: `bash tests/run.sh` (docs/architecture.md).

## The problem
A person who opens the hub with `claude` in their own terminal (not ADE) may not have `ade` installed, and the hub's
rules name only the `bin/` scripts, so the agent neither has `ade` nor knows its commands (`ade hub`, `ade project`,
`ade shot`, `ade web`, ...).

## The change
1. **Session start installs it.** The SessionStart hook (`bin/context`) checks `command -v ade` (and
   `~/.local/bin/ade`). When it is missing, it starts ade's published installer (`install.sh` from better-ade/ade-cli,
   which installs the tagged release into `~/.local/bin`) in the background, once at a time (a lock), logging to a file
   in the hub's per-machine state, and prints one line: ade is being installed, the log's path, and that `bin/`
   scripts do the same jobs until it lands. It never blocks the session start, never asks for sudo, and a failure is
   reported on the next start with the log's last line. `HUB_ADE_INSTALL=off` in hub.conf turns it off (then the line
   says how to install it by hand). The installer's address is overridable (`ADE_CLI_INSTALL_URL`) for tests only.
2. **The agent knows the commands.** When ade is there, the hook prints one line: `ade <version>` is installed and
   `ade help` lists its commands; run it before the first ade command in a session. The hub rules' Tools section
   (`templates/hub/CLAUDE.md`) gets an **ade** line naming what it is for (hubs, projects, dispatch, proof shots, the
   web dashboard, the tab view) and that `ade <command>` runs the same `bin/` script where one exists.
3. **Setup and doctor.** `bin/setup` installs ade the same way when it is missing (in the foreground; it already runs
   at a terminal); `bin/doctor` reports `ade` as OK with its version, or MISSING with the install line.

## Acceptance criteria (each named by its test)
1. **ade_missing_installs** (test_context.sh): with no ade on PATH and a fake installer URL, the session start returns
   at once, prints the installing line, and the fake installer ran once in the background; a second start while it
   runs does not start another.
2. **ade_install_failed** (test_context.sh): a failed install is reported on the next start with the log's last line.
3. **ade_install_off** (test_context.sh): with `HUB_ADE_INSTALL=off`, nothing is downloaded and the line gives the
   install command.
4. **ade_present_help** (test_context.sh): with a fake ade on PATH, the hook prints its version and the `ade help`
   line, and starts no install.
5. **ade_rules_line** (test_init.sh): a rendered hub's CLAUDE.md Tools section has the ade line.
6. **ade_setup_doctor** (test_setup.sh or test_doctor.sh): setup installs a missing ade via the fake installer;
   doctor shows ade OK or MISSING.

## Out of scope
Upgrading an installed ade, ADE's own terminal, Windows, putting `ade help`'s full text into every session.

## Addendum (owner, 2026-11-28: "we need to emphasize these types of task somewhere", words approved as drafted)
4. **Who does the work.** The hub rules (`templates/hub/CLAUDE.md`, "The main agent") and `templates/hub/README.md`
   carry the four ways a task runs, and the main agent names the one it picks when it starts a task:
   - **Ask in plain words** (a subagent): the main session hands the task to that project's agent and reports back. The usual way.
   - **Deep work** (a focus agent): a full session in the project's code, in its own tab, reporting to the main session.
   - **`ade dispatch`**: one focus agent per ready ticket; a high-risk ticket waits for your yes.
   - **A second opinion** (a role run): read-only work on another AI model; it reports, never edits.
7. **work_kinds** (test_init.sh): a rendered hub's CLAUDE.md and README.md carry the four lines.
