#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Runs every test script of the repo, so that tests.yml and the release workflow
# run exactly the same ones. Run it from the repo root. A failing script does not
# stop the others; the exit code is 1 when any of them failed.

set -u

fail=0
for t in scripts/*.test.sh .github/scripts/*.test.sh; do
  [ -f "$t" ] || continue
  printf '\n=== %s\n' "$t"
  bash "$t" </dev/null || fail=1
done

if [ "$fail" -ne 0 ]; then
  echo
  echo "one or more test scripts failed"
  exit 1
fi
