#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Refuses to start a release while another one is still open: a release/* branch
# on the remote, or an open pull request from one of this repository's own
# branches (a pull request from a fork whose branch is named release/... does not
# count: it cannot be a release made here). Two releases at once would
# conflict (both consume the same fragments).
#
# Run from the repo root. Needs git and gh (GH_TOKEN in CI). REMOTE names the
# remote to look at (default origin). Exit 0: nothing open. Exit 1: something is
# open, or it could not be checked (it fails closed, never open).

set -u

here="$(cd "$(dirname "$0")" && pwd)"
. "$here/release-lib.sh"

remote="${REMOTE:-origin}"

branches="$(git ls-remote --heads "$remote" "refs/heads/${RELEASE_BRANCH_PREFIX}*")" \
  || { echo "release-guard.sh: cannot list the branches of $remote" >&2; exit 1; }
if [ -n "$branches" ]; then
  echo "A release branch is still on $remote. Merge its pull request or delete the branch, then run the release again:"
  printf '%s\n' "$branches" | sed 's#.*refs/heads/#  #'
  exit 1
fi

prs="$(gh pr list --state open --base main --json number,headRefName,url,isCrossRepository \
  --jq '.[] | select(.isCrossRepository == false and (.headRefName | startswith("'"$RELEASE_BRANCH_PREFIX"'"))) | "#\(.number) \(.headRefName) \(.url)"')" \
  || { echo "release-guard.sh: cannot list the open pull requests" >&2; exit 1; }
if [ -n "$prs" ]; then
  echo "A release pull request is still open. Merge or close it, then run the release again:"
  printf '%s\n' "$prs" | sed 's/^/  /'
  exit 1
fi
