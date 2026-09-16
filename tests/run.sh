#!/bin/bash
# Runs all sandbox tests. No docker needed.
set -uo pipefail
cd "$(dirname "$0")"
FAIL=0
for t in test-git-wrapper.sh test-sbx-git.sh test-sync-vorgaben.sh; do
    echo "== $t"
    bash "$t" || FAIL=1
done
[ "$FAIL" = 0 ] && echo "all tests: ok"
exit "$FAIL"
