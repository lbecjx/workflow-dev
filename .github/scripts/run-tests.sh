#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Runs the test scripts of the repo. Run it from the repo root.
#
# Usage: run-tests.sh [DIR...]
#
# With no argument it runs every test of the repo (scripts/*.test.sh and
# .github/scripts/*.test.sh), as tests.yml does on every push and pull request.
# With directories it runs only DIR/*.test.sh for each, in order: the release
# workflow passes .github/scripts, the tests of what a release can break, since
# a release changes no plugin code and that code already passed the full run.
# A directory named on purpose that holds no test script is an error, so a typo
# there cannot turn into a green run of nothing.
#
# A failing script does not stop the others; the exit code is 1 when any of
# them failed.

set -u

fail=0

run_one() {
  printf '\n=== %s\n' "$1"
  bash "$1" </dev/null || fail=1
}

if [ "$#" -eq 0 ]; then
  for t in scripts/*.test.sh .github/scripts/*.test.sh; do
    [ -f "$t" ] || continue
    run_one "$t"
  done
else
  for dir in "$@"; do
    dir="${dir%/}"
    found=0
    for t in "$dir"/*.test.sh; do
      [ -f "$t" ] || continue
      found=1
      run_one "$t"
    done
    if [ "$found" -eq 0 ]; then
      echo "run-tests.sh: no test scripts in '$dir'"
      fail=1
    fi
  done
fi

if [ "$fail" -ne 0 ]; then
  echo
  echo "one or more test scripts failed"
  exit 1
fi
