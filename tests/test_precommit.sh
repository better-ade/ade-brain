#!/bin/bash
. "$(dirname "$0")/helpers.sh"
# CI installs gitleaks (ci.yml setup), so there the secret block below must run, never skip (story C2)
[ "${CI:-}" = true ] && ! command -v gitleaks >/dev/null && fail "gitleaks is not installed in CI: the pre-commit secret block cannot run"
make_hub; cd "$HUB"; git config core.hooksPath .githooks
mkdir -p repos/x && echo code > repos/x/a.py && git add -f repos/x/a.py
git commit -qm t 2>err && fail "a repos/ file was committed"; assert_contains err "REFUSED" "repos guard"
git reset -q
head -c 1100000 /dev/zero > big.bin && git add big.bin
git commit -qm t 2>err && fail "a 1.1 MB file was committed"; assert_contains err "over 1 MB" "size guard"
git reset -q; rm big.bin
if command -v gitleaks >/dev/null; then   # a secret-looking value is refused (Review Focus 3)
  # the fake key is built from parts so the literal never sits in the repo (it would be a gitleaks finding itself)
  k="AKIA""ZQ3DOSBSRNLJ6ZBW"; s="9fXvPj2LsZqk1Wm8""RtYb3Nc7Hd5Ea0Ug4Ko6Ti2s"
  printf 'aws_access_key_id = %s\naws_secret_access_key = %s\n' "$k" "$s" > creds.txt && git add creds.txt
  git commit -qm t 2>err && fail "a secret was committed"; assert_contains err "gitleaks found a secret" "secret guard"
  git reset -q; rm creds.txt
fi
echo "# fine" > note.md && git add note.md && git commit -qm ok || fail "a normal file was refused"
echo ok
