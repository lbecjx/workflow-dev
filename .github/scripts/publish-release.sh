#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Publishes a release after its pull request was merged into main: the annotated
# tag vX.Y.Z on the merged commit and the GitHub Release, with the notes taken
# from that version's section of CHANGELOG.md.
#
# A release is recognized by the version in .claude-plugin/plugin.json having
# changed in this push (BEFORE is the push's previous commit), never by the
# commit subject (merge, squash and rebase write different ones) and never by "the
# tag is missing" (a repo with no tags at all would tag whatever version it has).
#
# Env: BEFORE (the previous sha of main; when unset or unusable it compares with
# HEAD^ and says so), REMOTE (default origin). Needs git, jq and gh (GH_TOKEN in
# CI). Run from the repo root. With $GITHUB_OUTPUT set it writes published= and
# version= there.
#
# Every step checks its own precondition, so running it again does nothing: the
# tag already on the remote, the release already published, the release branch
# already gone. Exit 1 when the notes section is missing or blank (nothing is
# created) or a step fails.

set -u

here="$(cd "$(dirname "$0")" && pwd)"
. "$here/release-lib.sh"

remote="${REMOTE:-origin}"
before="${BEFORE:-}"

die() { printf 'publish-release.sh: %s\n' "$1" >&2; exit 1; }

version_at() { git show "$1:$MANIFEST" 2>/dev/null | jq -r '.version // empty' 2>/dev/null; }

version="$(version_at HEAD)"
[ -n "$version" ] || die "cannot read the version from $MANIFEST at HEAD"
semver_number "$version" >/dev/null || die "the version '$version' in $MANIFEST is not X.Y.Z; nothing was created"

if [ -z "$before" ] || [[ "$before" =~ ^0+$ ]] || ! git cat-file -e "$before^{commit}" 2>/dev/null; then
  echo "No usable previous commit (BEFORE='${before}'); comparing with HEAD^."
  before="HEAD^"
fi
previous="$(version_at "$before")"

if [ "$version" = "$previous" ]; then
  echo "The version did not change ($version); nothing to publish."
  out "published=false"
  exit 0
fi

# Only a version that went up is a release: a revert that brings an older one back
# must not tag or publish it again.
if previous_number="$(semver_number "$previous")" && [ "$(semver_number "$version")" -lt "$previous_number" ]; then
  echo "The version went down ($previous to $version); that is not a release, nothing to publish."
  out "published=false"
  exit 0
fi

notes="$(mktemp)"
trap 'rm -f "$notes"' EXIT
changelog_section "$version" > "$notes"
[ -n "$(tr -d '[:space:]' < "$notes")" ] \
  || die "CHANGELOG.md has no notes under '## $version'; nothing was created"

published=false

if [ -z "$(git ls-remote --tags "$remote" "refs/tags/v$version")" ]; then
  git rev-parse -q --verify "refs/tags/v$version" >/dev/null \
    || git tag -a "v$version" -m "Release $version" HEAD \
    || die "git tag failed"
  git push -q "$remote" "refs/tags/v$version" || die "could not push the tag v$version"
  echo "Tagged v$version."
  published=true
else
  echo "The tag v$version is already on $remote."
  tagged="$(git ls-remote --tags "$remote" "refs/tags/v$version^{}" | cut -f1)"
  if [ -n "$tagged" ] && [ "$tagged" != "$(git rev-parse HEAD)" ]; then
    echo "publish-release.sh: warning: v$version points at $tagged, not at HEAD; it was left as it is" >&2
  fi
fi

if gh release view "v$version" >/dev/null 2>&1; then
  echo "The release v$version already exists."
else
  gh release create "v$version" --verify-tag --title "$version" --notes-file "$notes" \
    || die "could not create the release v$version"
  echo "Published the release v$version."
  published=true
fi

if [ -n "$(git ls-remote --heads "$remote" "refs/heads/$(release_branch_of "$version")")" ]; then
  git push -q "$remote" --delete "$(release_branch_of "$version")" \
    && echo "Deleted the branch $(release_branch_of "$version")." \
    || echo "publish-release.sh: could not delete $(release_branch_of "$version"); continuing" >&2
fi

out "published=$published"
out "version=$version"
