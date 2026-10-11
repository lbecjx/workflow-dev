#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Tests that towncrier, with this repo's config and template, writes release
# notes in the CHANGELOG.md style: `## X.Y.Z`, flat bullets, no type headings,
# no story ids, prior history untouched.
# Run directly: bash .github/scripts/towncrier-format.test.sh

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
TOWNCRIER="${TOWNCRIER:-towncrier}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok() { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }
assert_contains() { case "$2" in *"$1"*) ok "$3" ;; *) no "$3 (missing: $1)" ;; esac; }
assert_absent()   { case "$2" in *"$1"*) no "$3 (unexpected: $1)" ;; *) ok "$3" ;; esac; }

if ! command -v "$TOWNCRIER" >/dev/null 2>&1; then
  echo "  SKIP towncrier is not installed (pip install towncrier)"
  exit 0
fi

mkdir -p "$TMP/.github" "$TMP/changes"
cp "$ROOT/.github/towncrier.toml" "$ROOT/.github/towncrier-template.md.jinja" "$TMP/.github/"
cp "$ROOT/CHANGELOG.md" "$TMP/CHANGELOG.md"
touch "$TMP/changes/.gitkeep"
printf 'Added a thing that\nwraps onto a second line.\n' > "$TMP/changes/WD-9001.feat.md"
printf 'Fixed the other thing.\n' > "$TMP/changes/WD-9002.fix.md"
printf 'Tidied the docs.\n' > "$TMP/changes/WD-9003.misc.md"
printf 'Dropped an old option.\n' > "$TMP/changes/WD-9004.breaking.md"
git -C "$TMP" init -q
git -C "$TMP" add -A

build() { (cd "$TMP" && "$TOWNCRIER" build --config .github/towncrier.toml --dir . "$@" 2>&1); }

echo "draft"
DRAFT="$(build --draft --version 9.9.9)"
assert_contains "## 9.9.9" "$DRAFT" "title is '## X.Y.Z'"
assert_contains "- Added a thing that
  wraps onto a second line." "$DRAFT" "a wrapped note keeps a two-space continuation"
assert_absent "###" "$DRAFT" "no per-type subheadings"
assert_absent "WD-9" "$DRAFT" "no story id in the notes"
assert_absent "====" "$DRAFT" "no title underline"
first="$(printf '%s\n' "$DRAFT" | grep '^- ' | head -1)"
last="$(printf '%s\n' "$DRAFT" | grep '^- ' | tail -1)"
[ "$first" = "- Dropped an old option." ] && ok "breaking comes first" || no "breaking comes first (got: $first)"
[ "$last" = "- Tidied the docs." ] && ok "misc comes last" || no "misc comes last (got: $last)"

echo "build"
build --yes --version 9.9.9 >/dev/null
OUT="$(cat "$TMP/CHANGELOG.md")"
marker_line="$(grep -n 'towncrier release notes start' "$TMP/CHANGELOG.md" | cut -d: -f1)"
new_line="$(grep -n '^## 9.9.9$' "$TMP/CHANGELOG.md" | cut -d: -f1)"
old_line="$(grep -n '^## 1.49.1$' "$TMP/CHANGELOG.md" | cut -d: -f1)"
[ -n "$marker_line" ] && [ -n "$new_line" ] && [ -n "$old_line" ] \
  && [ "$marker_line" -lt "$new_line" ] && [ "$new_line" -lt "$old_line" ] \
  && ok "new section sits between the marker and the previous release" \
  || no "new section sits between the marker and the previous release"
assert_contains "
## 9.9.9

" "$OUT" "blank lines around the new heading"
assert_contains "
## 1.49.1
" "$OUT" "the previous release heading keeps a blank line before it"
sed -n "${old_line},\$p" "$TMP/CHANGELOG.md" > "$TMP/after.md"
sed -n '/^## 1.49.1$/,$p' "$ROOT/CHANGELOG.md" > "$TMP/before.md"
cmp -s "$TMP/before.md" "$TMP/after.md" && ok "history from 1.49.1 down is unchanged" || no "history from 1.49.1 down is unchanged"
[ ! -e "$TMP/changes/WD-9001.feat.md" ] && ok "consumed fragments are removed" || no "consumed fragments are removed"
[ -e "$TMP/changes/.gitkeep" ] && ok ".gitkeep stays" || no ".gitkeep stays"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
