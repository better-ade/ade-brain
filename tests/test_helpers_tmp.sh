#!/bin/bash
# story X2: a test file run directly leaves nothing in the caller's TMPDIR; the folder goes when the test process ends
source "$(dirname "$0")/helpers.sh"
OUT="$(mktemp -d)"   # the "caller's TMPDIR" for the files below (itself inside this test's own, removed with it)
mk() {   # mk NAME BODY: a small test file that sources helpers.sh
  printf '#!/bin/bash\nsource "%s/tests/helpers.sh"\n%s\n' "$REPO" "$2" > "$OUT/$1.sh"
}
direct() { env -u ADE_TEST_TMP_OWNED TMPDIR="$OUT" bash "$OUT/$1.sh" </dev/null; }   # as a builder runs it
ls_new() { ls -A "$OUT" | grep -v -e '\.sh$' -e '\.hub$'; }
empty() { [ -z "$(ls_new)" ]; }
gone() { ade_wait empty; }

# 1. tmp_direct_run_clean: plain, with its own EXIT trap, and failing
mk plain 'make_hub; [ -d "$HUB" ]; echo "$HUB" > "$0.hub"; echo ok'
mk trapped 'make_hub; sleep 0.1 & wait; trap "rm -rf \"$HUB\"" EXIT; echo ok'
mk failing 'make_hub; echo nope; exit 1'
for f in plain trapped failing; do
  out="$(direct $f 2>&1)"; rc=$?   # returns at once: the watcher holds no stream of the caller
  [ "$f" = failing ] && assert_eq "$rc" 1 "$f exit" || assert_eq "$rc" 0 "$f exit"
  gone || fail "tmp_direct_run_clean: $f left $(ls_new)"
  # a bare `mktemp -d` (make_hub's hub) must land in TMPDIR too, not in the machine's own temp folder
  [ ! -f "$OUT/$f.sh.hub" ] || ade_wait test ! -d "$(dirname "$(cat "$OUT/$f.sh.hub")")" || fail "tmp_direct_run_clean: hub of $f left behind"
done

running() { [ -n "$(find "$OUT" -name running 2>/dev/null)" ]; }
# 2. tmp_killed_clean: SIGKILL gives the process no chance to clean up; the watcher removes the folder within 5 s
mk killed 'make_hub; touch "$TMPDIR/running"; exec sleep 60'
env -u ADE_TEST_TMP_OWNED TMPDIR="$OUT" bash "$OUT/killed.sh" </dev/null >/dev/null 2>&1 & kp=$!
ade_wait running || fail "tmp_killed_clean: test never started"
kill -KILL "$kp"; wait "$kp" 2>/dev/null
n=0; while [ -n "$(ls_new)" ] && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
[ -z "$(ls_new)" ] || fail "tmp_killed_clean: left $(ls_new)"

# 3. tmp_all_files_source_helpers: every test file sources helpers.sh, or is listed here with a reason
EXEMPT=""   # "name.sh:reason" entries; none today
for f in "$REPO"/tests/test_*.sh "$REPO"/tests/e2e_*.sh; do
  [ -e "$f" ] || continue; b="${f##*/}"
  grep -q 'helpers\.sh' "$f" || case " $EXEMPT " in *" $b:"*) ;; *) fail "tmp_all_files_source_helpers: $b";; esac
done
echo ok
