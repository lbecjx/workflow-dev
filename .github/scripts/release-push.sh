#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Puts the release commit on the remote release branch, signed by GitHub.
#
# main only accepts commits with a verified signature, and a `git commit` made
# with the token of the run cannot be signed. A commit that GitHub's API creates
# with that same token is signed by GitHub itself. So the local commit release.sh
# made (HEAD, one commit on top of main) is never pushed: the branch is created on
# the remote at HEAD's parent, and the same changes are committed on it through
# the GraphQL mutation createCommitOnBranch. The local commit is only what the
# tests ran against; its sha is thrown away.
#
# Env: BRANCH (release/vX.Y.Z), GITHUB_REPOSITORY (owner/name), REMOTE (default
# origin). Run from the repo root on the release commit; needs git, jq and gh
# (GH_TOKEN in CI). With $GITHUB_OUTPUT set it writes commit=<sha> there.
#
# Exit 0: the branch holds the signed commit. Exit 1: refused before touching the
# remote (the branch is there already, nothing to commit, a file the API cannot
# write), or a step failed; a branch this script created is deleted again, so
# that release-guard.sh does not stop the next run.

set -u
# A blob that cannot be read must stop the run, not reach GitHub as an empty file.
set -o pipefail

here="$(cd "$(dirname "$0")" && pwd)"
. "$here/release-lib.sh"

remote="${REMOTE:-origin}"
created=0

die() {
  printf 'release-push.sh: %s\n' "$1" >&2
  if [ "$created" -eq 1 ]; then
    git push -q "$remote" --delete "$BRANCH" >/dev/null 2>&1 \
      && echo "The release branch $BRANCH was deleted from the remote." >&2
  fi
  exit 1
}

[ -n "${BRANCH:-}" ] || die "BRANCH is not set"
[ -n "${GITHUB_REPOSITORY:-}" ] || die "GITHUB_REPOSITORY is not set"
# The clean-up deletes $BRANCH on the remote, so it must be a release branch.
case "$BRANCH" in
  "$RELEASE_BRANCH_PREFIX"v*) ;;
  *) die "'$BRANCH' is not a release branch (${RELEASE_BRANCH_PREFIX}vX.Y.Z)" ;;
esac

base="$(git rev-parse -q --verify HEAD^)" || die "HEAD has no parent: run it on the commit release.sh made"
headline="$(git log -1 --format=%s HEAD)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# --no-renames: a removed release note and an added file must stay a deletion and
# an addition, the only two kinds of change the mutation takes. -z keeps any path
# intact.
git diff --raw -z --no-renames "$base" HEAD > "$work/diff" || die "git diff failed"
[ -s "$work/diff" ] || die "the release commit changes nothing"

: > "$work/additions"
: > "$work/deletions"
while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
  status="${meta##* }"
  new_mode="$(printf '%s' "$meta" | cut -d' ' -f2)"
  case "$status" in
    A|M)
      # The mutation writes plain files only: an executable bit or a link would
      # be lost without a word.
      [ "$new_mode" = 100644 ] || die "$path has mode $new_mode; only plain files can be committed through the API"
      # No line breaks in the base64: GNU base64 wraps its output, macOS does not.
      git cat-file blob "HEAD:$path" | base64 | tr -d '\n' \
        | jq -R -s -c --arg p "$path" '{path: $p, contents: .}' >> "$work/additions" \
        || die "could not read $path from the release commit"
      ;;
    D)
      jq -n -c --arg p "$path" '{path: $p}' >> "$work/deletions" || die "jq failed"
      ;;
    *) die "unexpected change '$status' to $path" ;;
  esac
done < "$work/diff"

jq -n -c \
  --arg repo "$GITHUB_REPOSITORY" --arg branch "$BRANCH" \
  --arg base "$base" --arg headline "$headline" \
  --slurpfile additions "$work/additions" --slurpfile deletions "$work/deletions" \
  '{
    query: "mutation($input: CreateCommitOnBranchInput!) { createCommitOnBranch(input: $input) { commit { oid } } }",
    variables: { input: {
      branch: { repositoryNameWithOwner: $repo, branchName: $branch },
      message: { headline: $headline },
      expectedHeadOid: $base,
      fileChanges: { additions: $additions, deletions: $deletions }
    } }
  }' > "$work/request.json" || die "could not build the request"

existing="$(git ls-remote --heads "$remote" "refs/heads/$BRANCH")" \
  || die "cannot list the branches of $remote"
[ -z "$existing" ] || die "the branch $BRANCH is already on $remote"
git push -q "$remote" "$base:refs/heads/$BRANCH" || die "could not create the branch $BRANCH on $remote"
created=1

response="$(gh api graphql --input "$work/request.json")" || die "GitHub refused the release commit"
oid="$(printf '%s' "$response" | jq -r '.data.createCommitOnBranch.commit.oid // empty')"
[ -n "$oid" ] || die "GitHub answered without a commit: $response"

echo "Committed $headline on $BRANCH as $oid, signed by GitHub."
out "commit=$oid"
