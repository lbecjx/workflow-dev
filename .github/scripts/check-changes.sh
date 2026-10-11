#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Checks the release-note fragments a pull request adds or edits.
#
# Usage: check-changes.sh [path ...]   (paths as arguments, or one per line on stdin)
# Run it from the repo root: it reads each fragment from the working tree.
#
# Exit 0 only when at least one path is a fragment and every fragment is valid:
# changes/<name>.<feat|fix|breaking|misc>[.<n>].md with a non-blank body.
# Paths outside changes/ and changes/.gitkeep are ignored. Any other path under
# changes/ (subfolder, other extension, unknown type) is reported as invalid.

set -u

FRAGMENT_RE='^changes/[A-Za-z0-9-]+\.(feat|fix|breaking|misc)(\.[0-9]+)?\.md$'
fragments=0
invalid=0

check_path() {
  local p="$1"
  case "$p" in
    changes/.gitkeep) return 0 ;;
    changes/*) ;;
    *) return 0 ;;
  esac
  if ! [[ "$p" =~ $FRAGMENT_RE ]]; then
    printf '%s: name must be changes/<story>.<feat|fix|breaking|misc>.md (or .<n>.md)\n' "$p"
    invalid=$((invalid + 1))
    return 0
  fi
  fragments=$((fragments + 1))
  if [ ! -f "$p" ] || ! grep -q '[^[:space:]]' "$p"; then
    printf '%s: the note is empty\n' "$p"
    invalid=$((invalid + 1))
  fi
}

if [ "$#" -gt 0 ]; then
  for path in "$@"; do check_path "$path"; done
else
  while IFS= read -r path; do
    [ -n "$path" ] && check_path "$path"
  done
fi

if [ "$invalid" -gt 0 ]; then
  exit 1
fi
if [ "$fragments" -eq 0 ]; then
  echo "No release note found: add changes/<story>.<feat|fix|breaking|misc>.md, or label the PR no-changelog."
  exit 1
fi
