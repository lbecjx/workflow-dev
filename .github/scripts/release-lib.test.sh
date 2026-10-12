#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Tests for release-lib.sh: what the release scripts share (release branch name,
# version order, the notes of a version in the changelog).
# Run directly: bash .github/scripts/release-lib.test.sh

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/test-lib.sh"
. "$HERE/release-lib.sh"

echo "release_branch_of"
check "release/v<version>" [ "$(release_branch_of 1.2.3)" = "release/v1.2.3" ]

echo "semver_number"
lt() { [ "$(semver_number "$1")" -lt "$(semver_number "$2")" ]; }
check "1.49.2 is before 1.50.0" lt 1.49.2 1.50.0
check "1.50.0 is before 2.0.0" lt 1.50.0 2.0.0
check "1.9.0 is before 1.10.0 (numbers, not text)" lt 1.9.0 1.10.0
check "9.9.9 is before 10.0.0" lt 9.9.9 10.0.0
check "1.49.9 is before 1.49.10" lt 1.49.9 1.49.10
check "0.0.0 and 10.20.30 are versions" semver_number 0.0.0 >/dev/null && semver_number 10.20.30 >/dev/null
check "the same version has the same number" [ "$(semver_number 1.2.3)" = "$(semver_number 1.2.3)" ]
for bad in "1.2" "v1.2.3" "1.2.3-rc1" "1.2.3.4" "" "a.b.c" "1.08.0" "01.2.3" "1.2.03"; do
  check "'$bad' is not a version" not semver_number "$bad" >/dev/null 2>&1
done

echo "changelog_section"
CL="$TMP/CHANGELOG.md"
cat > "$CL" <<'CLEOF'
# Changelog

Intro.

<!-- towncrier release notes start -->

## 1.50.0

- A feature.
  A second line of the same note.
- Another feature.

## 1.49.10

- Ten.

## 1.49.1

- One.

## 1.49.0

## 1.48.0

- Old.
  ## not a heading, it is indented text
- Oldest.
CLEOF
section() { changelog_section "$1" "$CL"; }
check "the newest section, without its heading" [ "$(section 1.50.0)" = "$(printf -- '- A feature.\n  A second line of the same note.\n- Another feature.')" ]
check "1.49.1 is not mixed up with 1.49.10" [ "$(section 1.49.1)" = "- One." ]
check "1.49.10 is not mixed up with 1.49.1" [ "$(section 1.49.10)" = "- Ten." ]
check "a section with no notes is empty" [ -z "$(section 1.49.0)" ]
check "the last section runs to the end of the file" [ "$(section 1.48.0)" = "$(printf -- '- Old.\n  ## not a heading, it is indented text\n- Oldest.')" ]
check "a version that is not there is empty" [ -z "$(section 9.9.9)" ]
check "no blank line around the notes" [ -n "$(section 1.50.0 | head -1)" ] && [ -n "$(section 1.50.0 | tail -n1)" ]
check "it reads CHANGELOG.md of the current folder by default" [ "$(cd "$TMP" && changelog_section 1.49.1)" = "- One." ]

finish
