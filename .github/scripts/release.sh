#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Cuts one release of this repo from the fragments waiting in changes/.
# Local only: it commits and tags but never pushes, so release.yml owns the push.
#
# Run from the repo root. Does nothing (exit 0) when no fragment is waiting.
# Bump: any breaking fragment is a major, else any feat is a minor, else a patch.
# The base version is the one in .claude-plugin/plugin.json.
#
# When $GITHUB_OUTPUT is set it writes released=true|false, version= and
# notes_file= there. Set TOWNCRIER to use another towncrier executable.
#
# Exit codes: 0 released or nothing to release; 1 refused (the version is already
# tagged or already in CHANGELOG.md) or a step failed. A refusal changes nothing;
# a step that fails after the notes are built puts changes/, CHANGELOG.md and
# plugin.json back as they were at HEAD.

set -u

TOWNCRIER="${TOWNCRIER:-towncrier}"
CONFIG=".github/towncrier.toml"
MANIFEST=".claude-plugin/plugin.json"
CHANGELOG="CHANGELOG.md"

rewritten=0

out() { [ -n "${GITHUB_OUTPUT:-}" ] && printf '%s\n' "$1" >> "$GITHUB_OUTPUT"; return 0; }
die() {
  printf 'release.sh: %s\n' "$1" >&2
  if [ "$rewritten" -eq 1 ]; then
    git reset -q HEAD -- changes "$CHANGELOG" "$MANIFEST" 2>/dev/null
    git checkout -q HEAD -- changes "$CHANGELOG" "$MANIFEST" 2>/dev/null
  fi
  exit 1
}

has_fragment() { # $1 = type
  local f
  for f in changes/*."$1".md changes/*."$1".[0-9]*.md; do
    [ -f "$f" ] && return 0
  done
  return 1
}

# Whatever sits in changes/ must pass the same check a pull request does (name,
# type, a note that is not blank): towncrier stops with an error on a name it
# does not know, and a blank note would be released as an empty bullet. A file
# that fails is refused here by name, before anything is touched, so a human
# renames or removes it. Hidden files count, except .gitkeep.
here="$(cd "$(dirname "$0")" && pwd)"
waiting=""
any_fragment=0
for f in changes/* changes/.[!.]*; do
  [ -e "$f" ] || continue
  [ "$f" = "changes/.gitkeep" ] && continue
  waiting="$waiting$f
"
  any_fragment=1
done
if [ "$any_fragment" -eq 1 ]; then
  problems="$(printf '%s' "$waiting" | "$here/check-changes.sh")" \
    || die "changes/ holds something that is not a valid release note; fix or remove it:
$problems"
fi
if [ "$any_fragment" -eq 0 ]; then
  echo "No release notes waiting in changes/; nothing to release."
  out "released=false"
  exit 0
fi

current="$(jq -r '.version' "$MANIFEST")" || die "cannot read the version from $MANIFEST"
[[ "$current" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || die "the version '$current' is not X.Y.Z"
major="${BASH_REMATCH[1]}"
minor="${BASH_REMATCH[2]}"
patch="${BASH_REMATCH[3]}"

if has_fragment breaking; then
  next="$((major + 1)).0.0"
elif has_fragment feat; then
  next="$major.$((minor + 1)).0"
else
  next="$major.$minor.$((patch + 1))"
fi

if git rev-parse -q --verify "refs/tags/v$next" >/dev/null; then
  die "tag v$next already exists"
fi
if grep -qx "## $next" "$CHANGELOG"; then
  die "CHANGELOG.md already has a section for $next"
fi

notes="$(mktemp)"
manifest_tmp="$(mktemp)"
trap 'rm -f "$notes" "$manifest_tmp"' EXIT

"$TOWNCRIER" build --draft --version "$next" --config "$CONFIG" --dir . > "$notes.all" 2>&1 \
  || { cat "$notes.all" >&2; rm -f "$notes.all"; die "towncrier could not render the notes"; }
# The draft starts with a few status lines; the notes begin at the heading.
sed -n "/^## $next\$/,\$p" "$notes.all" | sed '1,2d' > "$notes"
rm -f "$notes.all"

# The file keeps whether it ended with a newline: jq always adds one.
new_manifest="$(jq -a --arg v "$next" '.version = $v' "$MANIFEST")" \
  || die "could not compute the new version for $MANIFEST"
if [ -n "$(tail -c1 "$MANIFEST")" ]; then
  printf '%s' "$new_manifest" > "$manifest_tmp"
else
  printf '%s\n' "$new_manifest" > "$manifest_tmp"
fi

# From here on the working tree is rewritten; die() puts it back on failure.
rewritten=1
"$TOWNCRIER" build --yes --version "$next" --config "$CONFIG" --dir . >/dev/null \
  || die "towncrier build failed"

cp "$manifest_tmp" "$MANIFEST" || die "could not write the version to $MANIFEST"

keep="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/release-notes-$next.md"
[ -s "$notes" ] || die "the release notes came out empty"
cp "$notes" "$keep" || die "could not keep the release notes"

# towncrier removes the last fragment and, with it, the folder; keep the folder.
mkdir -p changes && : > changes/.gitkeep
git add -A -- changes "$CHANGELOG" "$MANIFEST" || die "git add failed"
git commit -q -m "Release $next" || die "git commit failed"
# Annotated, so that git push --follow-tags sends it.
git tag -a "v$next" -m "Release $next" || die "git tag failed"
rewritten=0

echo "Released $next."
out "released=true"
out "version=$next"
# The notes file lives outside the trap's reach so the publish step can read it.
out "notes_file=$keep"
