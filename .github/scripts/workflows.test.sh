#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Tests that tests.yml and changelog-check.yml recognize the release pull request
# the same way. GitHub Actions has no expression shared between workflows, so
# each file carries its own copy of the condition, and only this test keeps the
# two copies from drifting apart.
# Run directly: bash .github/scripts/workflows.test.sh

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/test-lib.sh"

TESTS="$HERE/../workflows/tests.yml"
CHANGELOG="$HERE/../workflows/changelog-check.yml"

# clause <file>: the release clause, from "!(github.event.pull_request.user.login"
# to the line that closes the expression, one line each, with the indentation
# and what comes before "!(" on its first line taken off.
clause() {
  awk '/!\(github\.event\.pull_request\.user\.login/ { on = 1 }
       on { sub(/^[ \t]+/, ""); sub(/^.*!\(/, "!("); print }
       on && /\) }}$/ { exit }' "$1"
}

# lines_before <file>: the two lines above the clause's first line.
lines_before() {
  awk '/!\(github\.event\.pull_request\.user\.login/ { print b2; print b1; exit }
       { b2 = b1; b1 = $0 }' "$1"
}

# line_after <file>: the line below the clause's last one. Still inside the
# folded if (indented 6 or more), it would add text after "}}" and turn the
# condition into a string, which is always true.
line_after() {
  awk 'on { print; exit }
       /!\(github\.event\.pull_request\.user\.login/ { c = 1 }
       c && /\) }}$/ { on = 1 }' "$1"
}

T_CLAUSE="$(clause "$TESTS")"
C_CLAUSE="$(clause "$CHANGELOG")"
EXPECTED="!(github.event.pull_request.user.login == 'github-actions[bot]'
&& startsWith(github.head_ref, 'release/v')
&& github.event.pull_request.head.repo.full_name == github.repository) }}"

check "tests.yml has the release clause" [ "$T_CLAUSE" = "$EXPECTED" ]
check "changelog-check.yml has the release clause" [ "$C_CLAUSE" = "$EXPECTED" ]
check "the two clauses are identical" [ "$T_CLAUSE" = "$C_CLAUSE" ]
check "tests.yml negates it as the whole condition" grep -qxF -- '      ${{ !(github.event.pull_request.user.login == '"'github-actions[bot]'" "$TESTS"
check "changelog-check.yml joins it to the label clause" grep -qxF -- '      && !(github.event.pull_request.user.login == '"'github-actions[bot]'" "$CHANGELOG"
check "nothing follows the clause inside the if of tests.yml" not grep -q '^      ' <<< "$(line_after "$TESTS")"
check "nothing follows the clause inside the if of changelog-check.yml" not grep -q '^      ' <<< "$(line_after "$CHANGELOG")"
check "tests.yml puts it in the if of the scripts job" [ "$(lines_before "$TESTS")" = "  scripts:
    if: >-" ]
check "tests.yml does not skip on a label" not grep -qF 'pull_request.labels' "$TESTS"
check "tests.yml still runs on push" grep -qx '  push:' "$TESTS"
check "tests.yml still runs on pull requests" grep -qx '  pull_request:' "$TESTS"
check "tests.yml runs every test, not a directory" grep -qx '        run: bash .github/scripts/run-tests.sh' "$TESTS"

finish
