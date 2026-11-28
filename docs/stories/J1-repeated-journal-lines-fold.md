# J1: repeated journal lines fold into one

risk: low (bin/context's read-only summary; no secret, data or live system)
Status: **Approved** by the owner's own words (2026-11-28): "Yes", to the journal merge, after "i don't want to
compromise quality".

## Story
As the owner, I want the "Recent journal" a session starts with to show one line for a run of identical notes (the
PreCompact hook writes the same "(compaction ...)" note at every compaction), so the window shows real work entries
instead of eight copies of one note, and every session start and compaction carries fewer tokens. Nothing the agent
reads is lost: the folded line keeps the note, the folder, the first and last time and the count.

## Design
In `bin/context`, between `entries` and `lastn`: consecutive entries with the same folder and the same body fold into
one entry headed `## <first> to <last> UTC · <folder> (<n>×)`. Different bodies or folders never fold; a fold never
spans entries that were not consecutive. The journal files themselves are unchanged (bin/journal still writes every
entry; the fold is display only). Applies to both the hub summary and the per-folder view.

## Acceptance criteria
1. **journal_fold_repeats** (tests/test_context.sh): three consecutive identical hub entries at 10:53, 11:06, 12:04
   show as one entry `## 10:53 to 12:04 UTC · hub (3×)` with the note once.
2. **journal_fold_keeps_work** (tests/test_context.sh): with 8 identical compaction notes followed by 2 work entries
   and 1 more compaction note, the "Recent journal" shows both work entries (they were crowded out before), in order.
3. **journal_no_fold_different** (tests/test_context.sh): consecutive entries with different bodies, or the same body
   from different folders, stay separate and unchanged.
4. **journal_fold_folder_view** (tests/test_context.sh): `bin/context <folder>` folds that folder's repeats the same way.
5. The verification command passes (`bash tests/run.sh`).

## Out of scope
Changing what bin/journal or the PreCompact hook writes; trimming CLAUDE.md (dropped by the owner: quality first).
