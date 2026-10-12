#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Tests for release-guard.sh: it refuses while a release branch or an open
# release pull request exists, and fails closed when it cannot check.
# Run directly: bash .github/scripts/release-guard.test.sh

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/test-lib.sh"

install_gh_stub

GUARD="$HERE/release-guard.sh"
run() { # run <dir>: the guard from that directory; output in <dir>/out.txt
  (cd "$1" && "$GUARD" > out.txt 2>&1 </dev/null)
}

W="$(mkremote clean)"
run "$W"; rc=$?
check "nothing open: exit 0" [ "$rc" -eq 0 ]

W="$(mkremote withbranch)"
git -C "$W" push -q origin main:refs/heads/release/v1.49.2 2>/dev/null
run "$W"; rc=$?
check "a release branch on the remote: exit 1" [ "$rc" -eq 1 ]
check "a release branch on the remote: it is named" grep -q 'release/v1.49.2' "$W/out.txt"

W="$(mkremote otherbranch)"
git -C "$W" push -q origin main:refs/heads/feature/x 2>/dev/null
run "$W"; rc=$?
check "a branch that is not release/*: exit 0" [ "$rc" -eq 0 ]

W="$(mkremote withpr)"
STUB_PRS_JSON='[{"number":7,"headRefName":"release/v1.49.2","url":"https://github.com/lbecjx/workflow-dev/pull/7","isCrossRepository":false}]' run "$W"; rc=$?
check "an open release pull request: exit 1" [ "$rc" -eq 1 ]
check "an open release pull request: it is named" grep -q 'pull/7' "$W/out.txt"

W="$(mkremote forkpr)"
STUB_PRS_JSON='[{"number":8,"headRefName":"release/v9.9.9","url":"https://github.com/lbecjx/workflow-dev/pull/8","isCrossRepository":true}]' run "$W"; rc=$?
check "a pull request from a fork named release/...: exit 0" [ "$rc" -eq 0 ]

W="$(mkremote otherpr)"
STUB_PRS_JSON='[{"number":9,"headRefName":"feature/x","url":"https://github.com/lbecjx/workflow-dev/pull/9","isCrossRepository":false}]' run "$W"; rc=$?
check "an open pull request that is not a release: exit 0" [ "$rc" -eq 0 ]

W="$(mkremote ghfails)"
STUB_FAIL=1 run "$W"; rc=$?
check "gh failing: exit 1 (it fails closed)" [ "$rc" -eq 1 ]
check "gh failing: says it could not check" grep -q 'cannot list the open pull requests' "$W/out.txt"

W="$(mkremote noremote)"
git -C "$W" remote set-url origin "$TMP/does-not-exist.git"
run "$W"; rc=$?
check "an unreachable remote: exit 1 (it fails closed)" [ "$rc" -eq 1 ]

finish
