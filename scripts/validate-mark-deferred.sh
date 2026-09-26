#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Marks the current diff as "deliberately deferred" (WD-0003) instead of
# validated, so pre-commit-validate-check.sh recognizes at commit time that
# this task group's validation was skipped on purpose — batched for a
# story-end pass later — rather than simply forgotten. Writes to the same
# marker file `/workflow-dev:validate`'s Step 6 writes to (keyed by
# REPO_HASH, not a separate location), since this is that marker's other
# possible `status`, not a different mechanism.
#
# Same content-based hash formula as pre-commit-validate-check.sh and
# validate/SKILL.md's Step 6 — fingerprints each touched file's on-disk
# content directly, not `git diff` text, so a plain `git add` between
# calling this script and the actual commit doesn't invalidate the marker
# it just wrote. Keep this formula byte-identical to those two; it drifting
# out of sync is exactly the bug class documented in
# pre-commit-validate-check.sh's own comments.
#
# Usage: validate-mark-deferred.sh (no stdin, no arguments — reads the
# current git state directly, same as the hook it's paired with)

git rev-parse --show-toplevel >/dev/null 2>&1 || {
  echo "Not inside a git repository — nothing to mark." >&2
  exit 1
}

REPO_HASH=$(git rev-parse --show-toplevel | tr -d '\n' | shasum | cut -c1-12)
MARKER_DIR="${TMPDIR:-/tmp}/workflow-dev-validate"
mkdir -p "$MARKER_DIR"

DIFF_HASH=$(
  { git diff --name-only HEAD -- . ':!.workflow-dev';
    git ls-files --others --exclude-standard -- . ':!.workflow-dev';
  } | sort -u | while IFS= read -r f; do
    [[ -n "$f" ]] && printf '%s\n' "$f" && cat "$f" 2>/dev/null
  done | shasum | cut -d' ' -f1
)

printf '{"diffHash":"%s","status":"deferred","deferredAt":"%s"}' "$DIFF_HASH" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$MARKER_DIR/$REPO_HASH.json"

echo "Marked current diff as deferred (hash ${DIFF_HASH:0:12}…) — pre-commit-validate-check.sh will let the commit through with a visible note instead of asking. Runs once, batched, when the story finishes."
