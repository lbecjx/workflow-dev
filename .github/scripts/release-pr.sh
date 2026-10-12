#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Opens the release pull request to main.
#
# Env: VERSION (X.Y.Z), BRANCH (the pushed release branch), NOTES_FILE (the
# changelog section, used as the description). Run from the repo root; needs gh
# (GH_TOKEN in CI). With $GITHUB_OUTPUT set it writes pr_url= there.
#
# The label no-changelog goes on the pull request because it adds no release
# note of its own (changelog-check would fail it). It is best effort: the pull
# request is opened first and the label added afterwards, so a label that cannot
# be created or added never stops the release (the pull request opened with
# GITHUB_TOKEN starts no checks by itself anyway).
#
# When GitHub refuses because Actions may not create pull requests, it says which
# repository setting to turn on. Whatever the reason for a refusal, the pushed
# release branch is deleted again, so that the next run is not stopped by it.

set -u

here="$(cd "$(dirname "$0")" && pwd)"
. "$here/release-lib.sh"

die() { printf 'release-pr.sh: %s\n' "$1" >&2; exit 1; }

[ -n "${VERSION:-}" ] || die "VERSION is not set"
[ -n "${BRANCH:-}" ] || die "BRANCH is not set"
[ -s "${NOTES_FILE:-}" ] || die "NOTES_FILE is missing or empty"

err="$(mktemp)"
trap 'rm -f "$err"' EXIT

gh label create no-changelog --force --color ededed \
  --description "Skip the release-note check for this pull request" >/dev/null 2>&1 \
  || echo "release-pr.sh: could not create the label no-changelog; continuing" >&2

if url="$(gh pr create --base main --head "$BRANCH" --title "Release $VERSION" \
    --body-file "$NOTES_FILE" 2>"$err")"; then
  echo "$url"
  gh pr edit "$url" --add-label no-changelog >/dev/null 2>&1 \
    || echo "release-pr.sh: could not add the label no-changelog to $url; continuing" >&2
  out "pr_url=$url"
  exit 0
fi

if grep -q 'not permitted to create or approve pull requests' "$err"; then
  echo "GitHub Actions is not allowed to create pull requests in this repository." >&2
  echo "Turn on 'Allow GitHub Actions to create and approve pull requests' under Settings > Actions > General > Workflow permissions (an organization can also disable it there), then run the release again." >&2
else
  cat "$err" >&2
fi
if gh pr view "$BRANCH" >/dev/null 2>&1; then
  echo "A pull request for $BRANCH exists already, so the branch was kept." >&2
  exit 1
fi
git push origin --delete "$BRANCH" >/dev/null 2>&1 \
  && echo "The release branch $BRANCH was deleted from the remote." >&2
exit 1
