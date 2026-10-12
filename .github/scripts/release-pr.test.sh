#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Tests for release-pr.sh: the pull request it opens, the hint when GitHub
# refuses to let Actions open one, and the clean-up of the pushed branch.
# Run directly: bash .github/scripts/release-pr.test.sh

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/test-lib.sh"

install_gh_stub

PR="$HERE/release-pr.sh"

# prepare <name>: a clone with the release branch pushed, and a notes file.
prepare() {
  local w
  w="$(mkremote "$1")"
  git -C "$w" push -q origin main:refs/heads/release/v1.50.0 2>/dev/null
  printf -- '- A feature.\n' > "$w/notes.md"
  echo "$w"
}
run() { # run <dir>: the script from that directory; output in <dir>/out.txt
  : > "$GH_LOG"
  (cd "$1" && VERSION=1.50.0 BRANCH=release/v1.50.0 NOTES_FILE="$1/notes.md" GITHUB_OUTPUT="$1/gh-out.txt" "$PR" > out.txt 2>&1 </dev/null)
}
branch_on_remote() { [ -n "$(git -C "$1" ls-remote --heads origin release/v1.50.0)" ]; }

W="$(prepare ok)"
run "$W"; rc=$?
check "success: exit 0" [ "$rc" -eq 0 ]
check "success: prints the pull request URL" grep -q 'pull/99' "$W/out.txt"
check "success: writes pr_url to the output" grep -qx 'pr_url=https://github.com/lbecjx/workflow-dev/pull/99' "$W/gh-out.txt"
check "success: creates the label no-changelog" grep -q '^label create no-changelog' "$GH_LOG"
check "success: base main, head the release branch" grep -q -- '--base main --head release/v1.50.0' "$GH_LOG"
check "success: title is 'Release 1.50.0'" grep -q -- '--title Release 1.50.0' "$GH_LOG"
check "success: the description is the notes file" grep -q -- "--body-file $W/notes.md" "$GH_LOG"
check "success: the label is added to the pull request that was opened" grep -q '^pr edit https://github.com/lbecjx/workflow-dev/pull/99 --add-label no-changelog' "$GH_LOG"
check "success: the pull request is created without asking for the label" not grep -q -- 'pr create.*--label' "$GH_LOG"
check "success: the release branch stays on the remote" branch_on_remote "$W"

W="$(prepare labelfails)"
STUB_LABEL_FAIL=1 run "$W"; rc=$?
check "the label cannot be created: warns and goes on" [ "$rc" -eq 0 ] && grep -q 'could not create the label' "$W/out.txt"

W="$(prepare editfails)"
STUB_EDIT_FAIL=1 run "$W"; rc=$?
check "the label cannot be added: the pull request still stands and the branch stays" [ "$rc" -eq 0 ] && grep -q 'could not add the label' "$W/out.txt" && grep -q 'pull/99' "$W/out.txt" && branch_on_remote "$W"

W="$(prepare denied)"
STUB_DENY=1 run "$W"; rc=$?
check "refused by the repository setting: exit 1" [ "$rc" -eq 1 ]
check "refused by the repository setting: names the setting" grep -q "Allow GitHub Actions to create and approve pull requests" "$W/out.txt"
check "refused by the repository setting: says where" grep -q 'Settings > Actions > General > Workflow permissions' "$W/out.txt"
check "refused by the repository setting: the pushed branch is deleted" not branch_on_remote "$W"

W="$(prepare otherfail)"
STUB_FAIL=1 run "$W"; rc=$?
check "another failure: exit 1 and the error is shown as it came" [ "$rc" -eq 1 ] && grep -q 'boom: something else' "$W/out.txt"
check "another failure: the hint about the setting is not shown" not grep -q 'Allow GitHub Actions' "$W/out.txt"
check "another failure: the pushed branch is deleted" not branch_on_remote "$W"

W="$(prepare prexists)"
STUB_PR_EXISTS=1 STUB_FAIL=1 run "$W"; rc=$?
check "a pull request already exists for the branch: exit 1, the branch is kept" [ "$rc" -eq 1 ] && branch_on_remote "$W" && grep -q 'exists already, so the branch was kept' "$W/out.txt"

W="$(prepare nonotes)"
rm "$W/notes.md"
run "$W"; rc=$?
check "missing notes file: exit 1 before gh runs" [ "$rc" -eq 1 ] && [ ! -s "$GH_LOG" ]
W="$(prepare emptynotes)"
: > "$W/notes.md"
run "$W"; rc=$?
check "empty notes file: exit 1 before gh runs" [ "$rc" -eq 1 ] && [ ! -s "$GH_LOG" ]
check "empty notes file: the branch is not touched" branch_on_remote "$W"

W="$(prepare novars)"
(cd "$W" && env -u VERSION -u BRANCH NOTES_FILE="$W/notes.md" "$PR" > out.txt 2>&1 </dev/null); rc=$?
check "no VERSION or BRANCH: exit 1 and says so" [ "$rc" -eq 1 ] && grep -q 'is not set' "$W/out.txt"

finish
