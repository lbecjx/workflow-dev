# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# What the release scripts share, defined once: where the version and the changelog
# live, how a release branch is named, what a version looks like, and where the notes
# of a version are. Source it (`. "$here/release-lib.sh"`); it runs nothing by itself.

MANIFEST=".claude-plugin/plugin.json"
CHANGELOG="CHANGELOG.md"
RELEASE_BRANCH_PREFIX="release/"
# No leading zeros ("1.08.0" would be read as octal by the arithmetic below).
SEMVER_RE='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'

# out <name=value>: a line for the workflow step outputs, when there are any.
out() { [ -n "${GITHUB_OUTPUT:-}" ] && printf '%s\n' "$1" >> "$GITHUB_OUTPUT"; return 0; }

# release_branch_of <X.Y.Z>: the branch of that release, release/vX.Y.Z.
release_branch_of() { printf '%sv%s' "$RELEASE_BRANCH_PREFIX" "$1"; }

# semver_number <X.Y.Z>: a number that orders versions (major, then minor, then
# patch); fails when the text is not X.Y.Z.
semver_number() {
  [[ "$1" =~ $SEMVER_RE ]] || return 1
  echo $(( ${BASH_REMATCH[1]} * 1000000000000 + ${BASH_REMATCH[2]} * 1000000 + ${BASH_REMATCH[3]} ))
}

# changelog_section <X.Y.Z> [file]: the notes under "## X.Y.Z" in the changelog,
# without the heading, up to the next "## ", with no blank line around them. The
# pull request description and the GitHub release both come from here, so they
# cannot differ.
changelog_section() {
  awk -v h="## $1" '$0 == h { found = 1; next } found && /^## / { exit } found { print }' "${2:-$CHANGELOG}" \
    | sed -e :a -e '/^[[:space:]]*$/{$d;N;ba' -e '}' | sed '/./,$!d'
}
