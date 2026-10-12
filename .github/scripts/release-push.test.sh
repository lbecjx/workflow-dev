#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Tests for release-push.sh: the branch it creates at the base, the request it
# sends to createCommitOnBranch, the refusals, and the clean-up of the branch when
# GitHub does not commit. The stand-in gh keeps the request instead of committing.
# Run directly: bash .github/scripts/release-push.test.sh

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/test-lib.sh"

install_gh_stub

PUSH="$HERE/release-push.sh"
BODY="$TMP/graphql-body.json"
OK_ANSWER='{"data":{"createCommitOnBranch":{"commit":{"oid":"abc123"}}}}'

# prepare <name>: main holds a changelog, the manifest and two release notes (one
# with a space in its name); HEAD is a release commit on top of it that rewrites
# the first two, removes the notes and adds an empty changes/.gitkeep.
prepare() {
  local w
  w="$(mkremote "$1")"
  mkdir -p "$w/.claude-plugin" "$w/changes"
  printf '# Changelog\n' > "$w/CHANGELOG.md"
  printf '{"version": "1.49.1"}' > "$w/.claude-plugin/plugin.json"
  echo "A feature." > "$w/changes/WD-1.feat.md"
  echo "A fix." > "$w/changes/WD 2.fix.md"
  git -C "$w" add -A
  git -C "$w" commit -q -m notes
  git -C "$w" push -q origin main 2>/dev/null
  printf '# Changelog\n\n## 1.50.0\n\n- A feature.\n- A fix.\n' > "$w/CHANGELOG.md"
  printf '{"version": "1.50.0"}' > "$w/.claude-plugin/plugin.json"
  git -C "$w" rm -q "changes/WD-1.feat.md" "changes/WD 2.fix.md"
  mkdir -p "$w/changes" && : > "$w/changes/.gitkeep"
  git -C "$w" add -A
  git -C "$w" commit -q -m "Release 1.50.0"
  echo "$w"
}
run() { # run <dir> [env assignments ...]: the script from that directory; output in <dir>/out.txt
  local d="$1"
  shift
  : > "$GH_LOG"
  rm -f "$BODY"
  (cd "$d" && env BRANCH=release/v1.50.0 GITHUB_REPOSITORY=lbecjx/workflow-dev \
    GITHUB_OUTPUT="$d/gh-out.txt" STUB_API_GRAPHQL="$OK_ANSWER" "$@" "$PUSH" > out.txt 2>&1 </dev/null)
}
remote_sha() { git -C "$1" ls-remote --heads origin "$2" | cut -f1; }
branch_on_remote() { [ -n "$(remote_sha "$1" release/v1.50.0)" ]; }
input() { jq -r ".variables.input$1" "$BODY"; }

echo "a release commit"
W="$(prepare ok)"
BASE="$(git -C "$W" rev-parse HEAD^)"
run "$W"; rc=$?
check "exit 0" [ "$rc" -eq 0 ]
check "the branch is created on the remote at the base, not at the local commit" [ "$(remote_sha "$W" release/v1.50.0)" = "$BASE" ]
check "the local commit is not pushed" not git -C "$W.git" cat-file -e "$(git -C "$W" rev-parse HEAD)"
check "the request is createCommitOnBranch" grep -q 'createCommitOnBranch' "$BODY"
check "repository and branch" [ "$(input .branch.repositoryNameWithOwner)" = lbecjx/workflow-dev ] && [ "$(input .branch.branchName)" = release/v1.50.0 ]
check "it expects the branch to be at the base" [ "$(input .expectedHeadOid)" = "$BASE" ]
check "the headline is the local commit's subject" [ "$(input .message.headline)" = "Release 1.50.0" ]
check "three files written" [ "$(input '.fileChanges.additions | map(.path) | sort | join(",")')" = ".claude-plugin/plugin.json,CHANGELOG.md,changes/.gitkeep" ]
check "both notes removed, a space in a name kept" [ "$(input '.fileChanges.deletions | map(.path) | sort | join(",")')" = "changes/WD 2.fix.md,changes/WD-1.feat.md" ]
check "the changelog is sent byte for byte" [ "$(input '.fileChanges.additions[] | select(.path == "CHANGELOG.md") | .contents' | base64 -d)" = "$(cat "$W/CHANGELOG.md")" ]
check "the base64 has no line break" not grep -q '\\n' "$BODY"
check "the empty .gitkeep is sent empty" [ "$(input '.fileChanges.additions[] | select(.path == "changes/.gitkeep") | .contents | length')" = 0 ]
check "writes commit= to the output" grep -qx 'commit=abc123' "$W/gh-out.txt"
check "says the commit is signed by GitHub" grep -q 'signed by GitHub' "$W/out.txt"

echo "GitHub does not commit"
W="$(prepare apifail)"
run "$W" STUB_API_FAIL=1; rc=$?
check "the API fails: exit 1 and says so" [ "$rc" -eq 1 ] && grep -q 'GitHub refused the release commit' "$W/out.txt"
check "the API fails: the branch is deleted again" not branch_on_remote "$W"
W="$(prepare nooid)"
run "$W" STUB_API_GRAPHQL='{"data":{"createCommitOnBranch":null}}'; rc=$?
check "an answer without a commit: exit 1" [ "$rc" -eq 1 ] && grep -q 'answered without a commit' "$W/out.txt"
check "an answer without a commit: the branch is deleted again" not branch_on_remote "$W"

echo "refusals"
W="$(prepare exists)"
git -C "$W" push -q origin main:refs/heads/release/v1.50.0 2>/dev/null
BEFORE="$(remote_sha "$W" release/v1.50.0)"
run "$W"; rc=$?
check "the branch exists: exit 1, says so" [ "$rc" -eq 1 ] && grep -q 'already on origin' "$W/out.txt"
check "the branch exists: it is left as it was" [ "$(remote_sha "$W" release/v1.50.0)" = "$BEFORE" ]
check "the branch exists: GitHub is not called" [ ! -s "$GH_LOG" ]

W="$(prepare empty)"
git -C "$W" reset -q --hard HEAD^
git -C "$W" commit -q --allow-empty -m "Release 1.50.0"
run "$W"; rc=$?
check "nothing to commit: exit 1, no branch, no call" [ "$rc" -eq 1 ] && grep -q 'changes nothing' "$W/out.txt" && not branch_on_remote "$W" && [ ! -s "$GH_LOG" ]

W="$(mkremote noparent)"
run "$W"; rc=$?
check "HEAD without a parent: exit 1, no branch" [ "$rc" -eq 1 ] && grep -q 'has no parent' "$W/out.txt" && not branch_on_remote "$W"

W="$(prepare exec)"
chmod +x "$W/CHANGELOG.md"
git -C "$W" -c core.fileMode=true commit -q -a --amend --no-edit
run "$W"; rc=$?
check "an executable file: exit 1, named, no branch" [ "$rc" -eq 1 ] && grep -q 'CHANGELOG.md has mode 100755' "$W/out.txt" && not branch_on_remote "$W"

W="$(prepare novars)"
(cd "$W" && env -u BRANCH GITHUB_REPOSITORY=x/y "$PUSH" > out.txt 2>&1 </dev/null); rc=$?
check "no BRANCH: exit 1 and says so" [ "$rc" -eq 1 ] && grep -q 'BRANCH is not set' "$W/out.txt"
(cd "$W" && env -u GITHUB_REPOSITORY BRANCH=release/v1.50.0 "$PUSH" > out.txt 2>&1 </dev/null); rc=$?
check "no GITHUB_REPOSITORY: exit 1 and says so" [ "$rc" -eq 1 ] && grep -q 'GITHUB_REPOSITORY is not set' "$W/out.txt"

W="$(prepare noremote)"
run "$W" REMOTE=nowhere; rc=$?
check "the remote cannot be listed: exit 1, says so, no call" [ "$rc" -eq 1 ] && grep -q 'cannot list the branches of nowhere' "$W/out.txt" && [ ! -s "$GH_LOG" ]

W="$(prepare pushrefused)"
printf '#!/bin/sh\nexit 1\n' > "$W.git/hooks/pre-receive"
chmod +x "$W.git/hooks/pre-receive"
run "$W"; rc=$?
check "the remote refuses the branch: exit 1, says so, no call" [ "$rc" -eq 1 ] && grep -q 'could not create the branch' "$W/out.txt" && [ ! -s "$GH_LOG" ] && not branch_on_remote "$W"

W="$(prepare notrelease)"
MAIN="$(remote_sha "$W" main)"
run "$W" BRANCH=main STUB_API_FAIL=1; rc=$?
check "a branch that is not a release branch: exit 1, main untouched" [ "$rc" -eq 1 ] && grep -q 'is not a release branch' "$W/out.txt" && [ "$(remote_sha "$W" main)" = "$MAIN" ]

finish
