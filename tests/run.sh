#!/bin/bash
# each test file gets its own TMPDIR and a time limit (TEST_TIMEOUT seconds, default 600): a file that runs over is
# killed with every process under it, reported as FAIL with its last output, and the run goes on with the next file.
# Works on macOS /bin/bash 3.2 (no `timeout` there) and bash 5. Test files read no terminal: stdin is /dev/null, as in CI.
cd "$(dirname "$0")"; rc=0; limit="${TEST_TIMEOUT:-600}"
# $1 and every process under it, from one ps snapshot (children, theirs, ...)
tree() { ps -A -o pid= -o ppid= | awk -v root="$1" '{ kids[$2] = kids[$2] " " $1 }
  END { n = 1; q[1] = root; for (i = 1; i <= n; i++) { print q[i]; m = split(kids[q[i]], k, " "); for (j = 1; j <= m; j++) q[++n] = k[j] } }'; }
# stop the whole tree first (so nothing forks while it is collected), then kill it
kill_tree() { local all="" p r; for r in 1 2 3; do p=$(tree "$1"); all="$all $p"; kill -STOP $p 2>/dev/null; done; kill -KILL $all 2>/dev/null; }
for t in test_*.sh; do
  T=$(mktemp -d "${TMPDIR:-/tmp}/ade-test.XXXXXX"); O=$(mktemp "${TMPDIR:-/tmp}/ade-test-out.XXXXXX")
  TMPDIR="$T" bash "$t" < /dev/null > "$O" 2>&1 & pid=$!
  n=0; while kill -0 "$pid" 2>/dev/null && [ "$n" -lt $((limit * 10)) ]; do sleep 0.1; n=$((n + 1)); done
  if kill -0 "$pid" 2>/dev/null; then
    kill_tree "$pid"; wait "$pid" 2>/dev/null; echo "FAIL  $t (timed out after ${limit}s)"; tail -n 20 "$O"; rc=1
  elif wait "$pid" && [ "$(tail -n 1 "$O")" = ok ]; then echo "ok    $t"
  else echo "FAIL  $t"; tail -n 5 "$O"; rc=1; fi
  rm -rf "$T" "$O"
done
exit $rc
