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
#
# Scripts run in parallel, RUN_TESTS_JOBS at a time (default 4): run one by one
# the suite took about six minutes, almost all of it in three scripts. Each
# script's output is kept apart and printed whole, in the usual order, so the
# log reads the same as a sequential run. Some tests time real waits (a lock, a
# hook's budget), so the default stays near a CI runner's core count rather than
# starting every script at once.

set -u

fail=0
jobs="${RUN_TESTS_JOBS:-4}"
# A positive number up to 99; anything else (empty, 00, text, too big) is 4.
case "$jobs" in ''|*[!0-9]*|???*) jobs=4 ;; esac
jobs=$((10#$jobs))
[ "$jobs" -ge 1 ] || jobs=4

tests=()
if [ "$#" -eq 0 ]; then
  for t in scripts/*.test.sh .github/scripts/*.test.sh; do
    [ -f "$t" ] || continue
    tests+=("$t")
  done
else
  for dir in "$@"; do
    dir="${dir%/}"
    found=0
    for t in "$dir"/*.test.sh; do
      [ -f "$t" ] || continue
      found=1
      tests+=("$t")
    done
    if [ "$found" -eq 0 ]; then
      echo "run-tests.sh: no test scripts in '$dir'"
      fail=1
    fi
  done
fi

if [ "${#tests[@]}" -gt 0 ]; then
  out="$(mktemp -d)"
  trap 'rm -rf "$out"' EXIT
  # Start the biggest scripts first: size tracks run time closely here, and the
  # slowest script started last would set the length of the whole run.
  order=()
  while read -r _ i; do order+=("$i"); done < <(
    for i in "${!tests[@]}"; do
      printf '%s %s\n' "$(wc -c < "${tests[$i]}" | tr -d ' ')" "$i"
    done | sort -rn
  )
  # bash 3.2 (macOS) has no `wait -n`, so poll: a free slot takes the next
  # script as soon as any running one ends.
  pids=()
  running=()
  launched=0
  while [ "$launched" -lt "${#order[@]}" ] || [ "${#running[@]}" -gt 0 ]; do
    if [ "$launched" -lt "${#order[@]}" ] && [ "${#running[@]}" -lt "$jobs" ]; then
      i="${order[$launched]}"
      # Progress goes to stderr as it happens, so a script that hangs still
      # shows in the CI log; the full output follows on stdout at the end.
      echo "run-tests.sh: started ${tests[$i]}" >&2
      bash "${tests[$i]}" </dev/null > "$out/$i.log" 2>&1 &
      pids[$i]=$!
      running+=("$i")
      launched=$((launched + 1))
      continue
    fi
    still=()
    for i in "${running[@]}"; do
      if kill -0 "${pids[$i]}" 2>/dev/null; then
        still+=("$i")
      else
        wait "${pids[$i]}"
        rc=$?
        echo "$rc" > "$out/$i.rc"
        echo "run-tests.sh: finished ${tests[$i]} (exit $rc)" >&2
      fi
    done
    # Nothing ended since the last look: sleep instead of spinning.
    [ "${#still[@]}" -eq "${#running[@]}" ] && sleep 0.1
    running=(${still[@]+"${still[@]}"})
  done
  for i in "${!tests[@]}"; do
    printf '\n=== %s\n' "${tests[$i]}"
    cat "$out/$i.log"
    [ "$(cat "$out/$i.rc")" -eq 0 ] || fail=1
  done
fi

if [ "$fail" -ne 0 ]; then
  echo
  echo "one or more test scripts failed"
  exit 1
fi
