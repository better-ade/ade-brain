#!/bin/bash
# tests/run.sh gives each test file a time limit: a hung file fails with its last output, its process tree is killed,
# and the run goes on (CI runs hung for hours inside one test file)
. "$(dirname "$0")/helpers.sh"
F="$(mktemp -d)"; P="$F/pids"; cp "$REPO/tests/run.sh" "$F/run.sh"
printf '#!/bin/bash\necho fine\necho ok\n' > "$F/test_a_pass.sh"
# a file that never returns: a child, a grandchild and a python child are left running, then it waits forever
cat > "$F/test_b_hang.sh" <<EOF
#!/bin/bash
echo "\$TMPDIR" > "$P.tmpdir"
sleep 300 >/dev/null 2>&1 & echo \$! >> "$P"
bash -c 'sleep 300 & echo \$! >> "$P"; wait' >/dev/null 2>&1 &
python3 -c 'import time; time.sleep(300)' >/dev/null 2>&1 & echo \$! >> "$P"
echo "last words before the hang"
sleep 30
EOF
printf '#!/bin/bash\necho broken\nexit 1\n' > "$F/test_c_fail.sh"
printf '#!/bin/bash\necho ok\n' > "$F/test_d_after.sh"
start=$SECONDS; out=$(TEST_TIMEOUT=2 bash "$F/run.sh" </dev/null 2>&1); st=$?; took=$((SECONDS - start))
assert_eq "$st" 1 "a timed-out or failed file makes the run fail"
[ "$took" -lt 20 ] || fail "the run took ${took}s with a 2-second limit"
echo "$out" | grep -qx "ok    test_a_pass.sh" || fail "the passing file: [$out]"
echo "$out" | grep -qx "FAIL  test_b_hang.sh (timed out after 2s)" || fail "the hung file is reported as timed out: [$out]"
echo "$out" | grep -qx "last words before the hang" || fail "the hung file's last output is shown: [$out]"
echo "$out" | grep -qx "FAIL  test_c_fail.sh" || fail "an ordinary failure is still reported: [$out]"
echo "$out" | grep -qx "ok    test_d_after.sh" || fail "the run goes on after a timeout: [$out]"
n=$(wc -l < "$P" | tr -d ' '); assert_eq "$n" 3 "the hung file recorded its children"
sleep 1; for p in $(cat "$P"); do kill -0 "$p" 2>/dev/null && { kill -9 "$p"; fail "child $p of the hung file still runs"; }; done
[ -d "$(cat "$P.tmpdir")" ] && fail "the hung file's TMPDIR was not removed"
# the limit only stops files that run over it: with the default, the same passing file is ok
rm "$F"/test_b_hang.sh "$F"/test_c_fail.sh
out=$(bash "$F/run.sh" </dev/null 2>&1) || fail "the run fails with only passing files: [$out]"
grep -q 'TEST_TIMEOUT:-600' "$F/run.sh" || fail "the default time limit is not 600 seconds"
rm -rf "$F"
echo ok
