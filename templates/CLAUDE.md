# {{NAME}}

What this work is, in two lines: (fill in when the folder is created).

The hub's rules: copies of the hub root's CLAUDE.md and the files it imports, kept in `.claude/hub/` and
refreshed by `bin/work` on every start (edit the originals in the hub root, never the copies).

@.claude/hub/CLAUDE.md

Rules on top of the hub's root CLAUDE.md:
- Code changes happen only in this folder's repos (see ACCESS.md), on a branch, as a draft PR.
- At the end of a session, or before compaction: update STATE.md and add a journal entry
  (`../../bin/journal {{FOLDER}} "what was done, decided, pending"`).

@ACCESS.md
@memory/MEMORY.md
@STATE.md
