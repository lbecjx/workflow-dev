#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Tests for run-tests.sh, the loop that runs every test script of the repo.
# Run directly: bash .github/scripts/run-tests.test.sh

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/test-lib.sh"
RUN="$HERE/run-tests.sh"

# mkrepo <name> <outcome of scripts/a> <outcome of .github/scripts/b>: a folder
# with two fake test scripts; each leaves a file behind when it runs.
mkrepo() {
  local d="$TMP/$1"
  mkdir -p "$d/scripts" "$d/.github/scripts"
  printf '#!/bin/bash\ntouch ran-a\nexit %s\n' "$2" > "$d/scripts/a.test.sh"
  printf '#!/bin/bash\ntouch ran-b\nexit %s\n' "$3" > "$d/.github/scripts/b.test.sh"
  echo "$d"
}
run() { # run <dir>: runs the loop there, output in <dir>/out.txt
  (cd "$1" && "$RUN" > out.txt 2>&1 </dev/null)
}

R="$(mkrepo allpass 0 0)"
run "$R"; rc=$?
check "all pass: exit 0" [ "$rc" -eq 0 ]
check "all pass: both ran" [ -e "$R/ran-a" ] && [ -e "$R/ran-b" ]
check "all pass: the output names each file" grep -q '=== scripts/a.test.sh' "$R/out.txt" && grep -q '=== .github/scripts/b.test.sh' "$R/out.txt"

R="$(mkrepo firstfails 1 0)"
run "$R"; rc=$?
check "the first fails: exit 1" [ "$rc" -eq 1 ]
check "the first fails: the second still ran" [ -e "$R/ran-b" ]
check "the first fails: says so" grep -q 'one or more test scripts failed' "$R/out.txt"

R="$(mkrepo lastfails 0 1)"
run "$R"; rc=$?
check "the last fails: exit 1" [ "$rc" -eq 1 ]
check "the last fails: the first ran" [ -e "$R/ran-a" ]

R="$TMP/empty"
mkdir -p "$R"
run "$R"; rc=$?
check "no test scripts at all: exit 0" [ "$rc" -eq 0 ]

finish
