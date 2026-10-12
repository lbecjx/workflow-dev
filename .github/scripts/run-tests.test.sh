#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Tests for run-tests.sh: every test script of the repo by default, or only the
# directories it is given.
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
run() { # run <dir> [DIR...]: runs the loop there with those arguments, output in <dir>/out.txt
  local d="$1"
  shift
  (cd "$d" && "$RUN" "$@" > out.txt 2>&1 </dev/null)
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

R="$(mkrepo onlyrepo 0 0)"
run "$R" .github/scripts; rc=$?
check "only .github/scripts: exit 0" [ "$rc" -eq 0 ]
check "only .github/scripts: its script ran" [ -e "$R/ran-b" ]
check "only .github/scripts: the plugin's did not" [ ! -e "$R/ran-a" ]
check "only .github/scripts: the output names only its file" not grep -q '=== scripts/a.test.sh' "$R/out.txt"

R="$(mkrepo onlyplugin 0 0)"
run "$R" scripts; rc=$?
check "only scripts: exit 0" [ "$rc" -eq 0 ]
check "only scripts: its script ran" [ -e "$R/ran-a" ]
check "only scripts: the other did not" [ ! -e "$R/ran-b" ]

R="$(mkrepo bothdirs 0 0)"
run "$R" scripts .github/scripts/; rc=$?
check "both directories named: exit 0" [ "$rc" -eq 0 ]
check "both directories named: the first ran" [ -e "$R/ran-a" ]
check "both directories named: the second ran" [ -e "$R/ran-b" ]
check "a trailing slash is accepted" grep -q '=== .github/scripts/b.test.sh' "$R/out.txt"

R="$(mkrepo emptydir 0 0)"
mkdir -p "$R/other"
run "$R" other; rc=$?
check "a named directory without test scripts: exit 1" [ "$rc" -eq 1 ]
check "a named directory without test scripts: says which" grep -q "no test scripts in 'other'" "$R/out.txt"
check "a named directory without test scripts: nothing else ran" [ ! -e "$R/ran-a" ]

R="$(mkrepo missingdir 0 0)"
run "$R" .github/scrpts; rc=$?
check "a named directory that does not exist: exit 1" [ "$rc" -eq 1 ]
check "a named directory that does not exist: says which" grep -q "no test scripts in '.github/scrpts'" "$R/out.txt"

R="$(mkrepo missingthenreal 0 0)"
run "$R" nope .github/scripts; rc=$?
check "a missing directory before a real one: exit 1" [ "$rc" -eq 1 ]
check "a missing directory before a real one: the real one still ran" [ -e "$R/ran-b" ]

R="$(mkrepo namedfails 0 1)"
run "$R" .github/scripts; rc=$?
check "a failing script in the named directory: exit 1" [ "$rc" -eq 1 ]
check "a failing script in the named directory: says so" grep -q 'one or more test scripts failed' "$R/out.txt"

finish
