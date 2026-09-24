#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Marks a commit message or PR title/description as having passed the Git
# History Disclosure review (validate/references/rules.md Part 12), so the
# pre-commit-message-check.sh PreToolUse hook recognizes this exact text was
# already checked and doesn't ask again at actual commit/PR-creation time.
#
# Keyed by content hash, not by "a review happened at some point" — editing
# the text by even one character after marking it invalidates the marker,
# same as the diff-hash marker in pre-commit-validate-check.sh. This is
# deliberate: a marker that survived a later edit would let an unreviewed
# rewrite slip through silently.
#
# Usage: printf '%s' "<final message text>" | git-message-mark-reviewed.sh

MESSAGE=$(cat)
if [[ -z "$MESSAGE" ]]; then
  echo "No message text on stdin — nothing to mark." >&2
  exit 1
fi

MARKER_DIR="${TMPDIR:-/tmp}/workflow-dev-validate/messages"
mkdir -p "$MARKER_DIR"
MESSAGE_HASH=$(printf '%s' "$MESSAGE" | shasum | cut -d' ' -f1)
printf '{"reviewedAt":"%s"}' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$MARKER_DIR/$MESSAGE_HASH.json"

echo "Marked commit/PR message as reviewed (hash ${MESSAGE_HASH:0:12}…) — pre-commit-message-check.sh will recognize this exact text and won't ask again. Any edit to it after this point needs re-marking."
