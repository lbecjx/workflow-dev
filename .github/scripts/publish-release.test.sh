#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Tests for publish-release.sh: the tag and the GitHub Release created after the
# release pull request is merged, recognized by the version change in the push.
# Run directly: bash .github/scripts/publish-release.test.sh

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/test-lib.sh"
PUBLISH="$HERE/publish-release.sh"

install_gh_stub

manifest() { # manifest <version>
  printf '{\n  "name": "workflow-dev",\n  "version": "%s"\n}' "$1"
}
changelog() { # changelog <with the 1.49.2 section? yes|no>
  printf '# Changelog\n\n<!-- towncrier release notes start -->\n\n'
  if [ "$1" = yes ]; then
    printf '## 1.49.2\n\n- Releases are cut by hand.\n  A second line of the note.\n- Another note.\n\n'
  fi
  printf '## 1.49.1\n\n- The older release.\n'
}

# mkrepo <name> <changelog has the new section? yes|no>: mkremote's origin and clone
# with main at 1.49.1 and then a commit that bumps to 1.49.2, plus the branch
# release/v1.49.2 on the remote. The 1.49.1 commit is HEAD~1 (before_of).
mkrepo() {
  local w
  w="$(mkremote "$1")"
  mkdir -p "$w/.claude-plugin"
  manifest 1.49.1 > "$w/.claude-plugin/plugin.json"
  changelog no > "$w/CHANGELOG.md"
  git -C "$w" add -A
  git -C "$w" commit -q -m "Older release"
  manifest 1.49.2 > "$w/.claude-plugin/plugin.json"
  changelog "$2" > "$w/CHANGELOG.md"
  git -C "$w" add -A
  git -C "$w" commit -q -m "Release 1.49.2"
  git -C "$w" push -q origin main 2>/dev/null
  git -C "$w" push -q origin main:refs/heads/release/v1.49.2 2>/dev/null
  echo "$w"
}
before_of() { git -C "$1" rev-parse HEAD~1; }
run() { # run <dir>: the script there, with BEFORE as set; output in <dir>/out.txt
  : > "$GH_LOG"
  rm -f "$TMP/notes-seen.txt"
  (cd "$1" && env BEFORE="${BEFORE:-}" GITHUB_OUTPUT="$1/gh-out.txt" "$PUBLISH" > out.txt 2>&1 </dev/null)
}
tag_on_remote() { [ -n "$(git -C "$1" ls-remote --tags origin refs/tags/v1.49.2)" ]; }
branch_on_remote() { [ -n "$(git -C "$1" ls-remote --heads origin refs/heads/release/v1.49.2)" ]; }
release_created() { grep -q '^release create' "$GH_LOG"; }

echo "a merged release"
W="$(mkrepo merged yes)"
BEFORE="$(before_of "$W")" run "$W"; rc=$?
check "exits 0" [ "$rc" -eq 0 ]
check "the annotated tag v1.49.2 is on the remote" tag_on_remote "$W"
check "the tag is annotated" [ "$(git -C "$W" cat-file -t v1.49.2)" = tag ]
check "the tag points at the merged commit" [ "$(git -C "$W" rev-parse 'v1.49.2^{commit}')" = "$(git -C "$W" rev-parse HEAD)" ]
check "the release is created for v1.49.2" grep -q '^release create v1.49.2 --verify-tag --title 1.49.2 --notes-file' "$GH_LOG"
check "the notes are exactly that section, without its heading" [ "$(cat "$TMP/notes-seen.txt")" = "$(printf -- '- Releases are cut by hand.\n  A second line of the note.\n- Another note.')" ]
check "the release branch is deleted from the remote" not branch_on_remote "$W"
check "output: published=true and the version" grep -qx 'published=true' "$W/gh-out.txt" && grep -qx 'version=1.49.2' "$W/gh-out.txt"

echo "running it again"
FIRST_BEFORE="$(before_of "$W")"
REMOTE_TAG_SHA="$(git -C "$W" ls-remote --tags origin refs/tags/v1.49.2)"
STUB_RELEASED=1 BEFORE="$FIRST_BEFORE" run "$W"; rc=$?
check "exits 0" [ "$rc" -eq 0 ]
check "no second release" not release_created
check "the remote tag is the same" [ "$(git -C "$W" ls-remote --tags origin refs/tags/v1.49.2)" = "$REMOTE_TAG_SHA" ]
check "output: published=false" grep -qx 'published=false' "$W/gh-out.txt"

echo "the tag is there but not the release"
W="$(mkrepo tagonly yes)"
git -C "$W" tag -a v1.49.2 -m "Release 1.49.2"
git -C "$W" push -q origin refs/tags/v1.49.2 2>/dev/null
BEFORE="$(before_of "$W")" run "$W"; rc=$?
check "exits 0 and creates only the release" [ "$rc" -eq 0 ] && release_created
check "the existing tag is untouched" tag_on_remote "$W"

echo "a push that does not change the version"
W="$(mkrepo same yes)"
BEFORE="$(git -C "$W" rev-parse HEAD)" run "$W"; rc=$?
check "exits 0" [ "$rc" -eq 0 ]
check "no tag and no release" not tag_on_remote "$W" && not release_created
check "says there is nothing to publish" grep -q 'nothing to publish' "$W/out.txt"
check "output: published=false" grep -qx 'published=false' "$W/gh-out.txt"

echo "the old version with no tags at all"
W="$(mkrepo oldnotags yes)"
git -C "$W" commit -q --allow-empty -m "An ordinary change after the release"
BEFORE="$(git -C "$W" rev-parse HEAD~1)" run "$W"; rc=$?
check "an ordinary push never tags the version it has" [ "$rc" -eq 0 ] && not tag_on_remote "$W" && not release_created

echo "no notes for the version"
W="$(mkrepo nonotes no)"
BEFORE="$(before_of "$W")" run "$W"; rc=$?
check "exits 1 and says the notes are missing" [ "$rc" -eq 1 ] && grep -q "no notes under '## 1.49.2'" "$W/out.txt"
check "nothing is created: no tag, no release, the branch stays" not tag_on_remote "$W" && not release_created && branch_on_remote "$W" && [ -z "$(git -C "$W" tag)" ]

echo "a blank section"
W="$(mkrepo blank no)"
B="$(before_of "$W")"
printf '# Changelog\n\n<!-- towncrier release notes start -->\n\n## 1.49.2\n\n\n## 1.49.1\n\n- The older release.\n' > "$W/CHANGELOG.md"
git -C "$W" commit -q -am "Blank section"
BEFORE="$B" run "$W"; rc=$?
check "exits 1 with no tag" [ "$rc" -eq 1 ] && not tag_on_remote "$W"

echo "BEFORE missing or unusable"
W="$(mkrepo nobefore yes)"
BEFORE="" run "$W"; rc=$?
check "unset: falls back to HEAD^ and says so" [ "$rc" -eq 0 ] && grep -q 'comparing with HEAD^' "$W/out.txt" && tag_on_remote "$W"
W="$(mkrepo zeros yes)"
BEFORE="0000000000000000000000000000000000000000" run "$W"; rc=$?
check "all zeros (a new branch): falls back to HEAD^" [ "$rc" -eq 0 ] && grep -q 'comparing with HEAD^' "$W/out.txt" && tag_on_remote "$W"
W="$(mkrepo unknownsha yes)"
BEFORE="1111111111111111111111111111111111111111" run "$W"; rc=$?
check "a sha the clone does not have: falls back to HEAD^" [ "$rc" -eq 0 ] && grep -q 'comparing with HEAD^' "$W/out.txt"

echo "a revert brings an older version back"
W="$(mkrepo reverted yes)"
git -C "$W" push -q origin main 2>/dev/null
manifest 1.49.1 > "$W/.claude-plugin/plugin.json"
git -C "$W" commit -q -am "Revert the release"
BEFORE="$(before_of "$W")" run "$W"; rc=$?
check "the version went down: exit 0, no tag, no release" [ "$rc" -eq 0 ] && grep -q 'went down' "$W/out.txt" && not release_created && [ -z "$(git -C "$W" ls-remote --tags origin)" ]
check "output: published=false" grep -qx 'published=false' "$W/gh-out.txt"

echo "a version that is not X.Y.Z"
W="$(mkrepo badversion yes)"
manifest 1.49 > "$W/.claude-plugin/plugin.json"
git -C "$W" commit -q -am "Odd version"
BEFORE="$(before_of "$W")" run "$W"; rc=$?
check "exits 1 and says so, with nothing created" [ "$rc" -eq 1 ] && grep -q 'is not X.Y.Z' "$W/out.txt" && not tag_on_remote "$W" && not release_created

echo "the tag is already there but on another commit"
W="$(mkrepo tagelsewhere yes)"
OLD="$(git -C "$W" rev-parse HEAD~1)"
git -C "$W" tag -a v1.49.2 -m "Release 1.49.2" "$OLD"
git -C "$W" push -q origin refs/tags/v1.49.2 2>/dev/null
BEFORE="$OLD" run "$W"; rc=$?
check "exits 0, leaves the tag where it is and warns" [ "$rc" -eq 0 ] && grep -q 'points at' "$W/out.txt" && [ "$(git -C "$W" ls-remote --tags origin 'refs/tags/v1.49.2^{}' | cut -f1)" = "$OLD" ]

echo "gh fails when creating the release"
W="$(mkrepo createfails yes)"
STUB_CREATE_FAIL=1 BEFORE="$(before_of "$W")" run "$W"; rc=$?
check "exits 1" [ "$rc" -eq 1 ]
check "the tag stays (a rerun only needs to create the release)" tag_on_remote "$W"

finish
