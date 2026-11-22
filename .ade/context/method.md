# The method comes from ade-method (story C1)

ade-method (`https://github.com/better-ade/ade-method`) is the only home of the method (ADR 0004). The hub keeps no
copy of its own: `bin/method sync` copies it in, and a test fails when the copies drift.

- **Files:** ade-method's `rules.md` becomes `.ade/rules.md`; its `bmad/custom/*.toml` become `_bmad/custom/*.toml`
  and each `ade.json` `install_templates` entry (`"<source>": "<target>"`, both plain relative paths: no `..`, no
  absolute path, not under `.git`) is copied to its target (v2.1.0: `.github/pull_request_template.md`,
  `.ade/commit-template.txt`), recorded with its hash so `bin/method check` covers it. A bad entry or a missing source
  exits 1 before any hub file changes.
  (`_bmad/custom/.gitignore` and `*.user.toml` are the hub's own and are left alone). Edit them in ade-method, not here.
- **Pin:** `method_pin` in `bin/lib.sh` (now `v2.1.0`) is the tag the template pins. `bin/init` writes it to hub.conf as
  `HUB_METHOD_REF` and syncs at it. To move the template to a new release: change `method_pin`, run
  `bin/method sync <tag>`, commit the result (`template_matches_pin` in `tests/test_method.sh` checks both agree).
- **Ref:** `bin/method sync [ref]` uses the argument, else `HUB_METHOD_REF`, else `method_pin`. A tag or branch name.
- **Repo:** `method_repo` in `bin/lib.sh`; `AGENT_METHOD_REPO` overrides it. Tests always point it at a local fixture
  (`make_hub` builds one from the template's own files; `method_repo` in `tests/helpers.sh` builds tagged fixtures).
- **Record:** `.ade/method-version` holds `ref <ref>`, `commit <sha>` and one `file <sha256> <path>` line per copied file.
  A sync removes the `_bmad/custom/*.toml` files the previous record lists that the new ref no longer ships (never a
  file the method did not install).
- **Check:** `bin/method check` is offline: it compares each recorded file's sha256, prints `differs: <path>` for each
  changed or missing one and exits 1; 0 when all match. `bin/doctor` shows it as one `method` row (file names only).
- **Failure:** an unknown ref, an unreachable repo or a ref with no `rules.md` exits 1 before any hub file changes.
  When `bin/init`'s sync fails for any reason, it keeps the template's copy and appends `synced no <pin>` to
  `.ade/method-version`; `bin/method check` then prints `not synced at <pin>` and exits 1, and `bin/doctor`'s `method`
  row says the same, until a `bin/method sync` succeeds (it rewrites the record).
