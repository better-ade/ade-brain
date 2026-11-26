#!/bin/bash
# CI runs the real secret scan (story C2): both ci.yml jobs install gitleaks in their own setup (the shared verify
# workflow deletes its copy before the tests), and the tests that use it fail under CI=true when it is missing.
. "$(dirname "$0")/helpers.sh"

ci_gitleaks_installed() {   # AC1
  python3 - "$REPO/.github/workflows/ci.yml" <<'PY' || fail "ci.yml setups install gitleaks: $(cat "$REPO/.github/workflows/ci.yml")"
import re, sys
t = open(sys.argv[1]).read()
jobs = dict(re.findall(r"^  ([\w-]+):\n((?:    .*\n?)*)", t, re.M))
# macOS: brew installs it; Ubuntu (whose package is too old for `gitleaks stdin`): the pinned release, checked, on PATH
need = {"ci": [r"brew install [^&;|]*\bgitleaks\b"],
        "ci-linux": [r"curl [^&;|]*/v8\.30\.1/gitleaks_8\.30\.1_linux_x64\.tar\.gz", r"sha256sum -c",
                     r"tar xzf \S+ -C /usr/local/bin gitleaks\b"]}
for name, pats in need.items():
    s = re.search(r'setup: "([^"]*)"', jobs.get(name, ""))
    assert s, (name, "no setup")
    for p in pats:
        assert re.search(p, s.group(1)), (name, p, s.group(1))
    assert "bash tests/run.sh" in jobs[name], name
PY
}

# runs a test file under CI=true with a PATH that has no gitleaks: it must fail at once, naming gitleaks
ci_without_gitleaks() {   # $1 test file
  local out rc; PATH=/usr/bin:/bin command -v gitleaks >/dev/null && { echo "note: gitleaks in /usr/bin or /bin; $1 under CI without it not checked" >&2; return 0; }
  out=$(cd "$REPO/tests" && env CI=true PATH=/usr/bin:/bin bash "$1" 2>&1 </dev/null); rc=$?
  [ "$rc" -ne 0 ] || fail "$1 passed under CI without gitleaks: [$out]"
  echo "$out" | grep -q "gitleaks is not installed in CI" || fail "$1 says gitleaks is missing in CI: [$out]"
}
precommit_secret_runs() { ci_without_gitleaks test_precommit.sh; }   # AC2
learn_real_scan_runs() { ci_without_gitleaks test_learn.sh; }        # AC3

ALL="ci_gitleaks_installed precommit_secret_runs learn_real_scan_runs"
for t in ${@:-$ALL}; do "$t"; done
echo ok
