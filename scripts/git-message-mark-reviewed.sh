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
# Refuses to mark a message carrying AI/agent/LLM attribution the human has not
# allowed (rules.md §12.3). The default is no attribution at all. Only an
# explicit yes from the human, recorded for this repository, lets through the
# two co-authorship lines the harness supplies, and nothing else.
# coauthor-decision.sh owns both the patterns and the decision, and
# pre-commit-message-check.sh sources the same file, so a message cannot be
# marked here under a rule the commit-time hook does not also enforce.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The marker directory's one owner (WD-0027) — the same path, trust check and
# safe write pre-commit-message-check.sh reads from. See marker-dir.sh's header.
# shellcheck source=marker-dir.sh
source "$HERE/marker-dir.sh"
# shellcheck source=coauthor-decision.sh
source "$HERE/coauthor-decision.sh"
# Without the rule nothing can be checked, so nothing is marked.
if ! declare -F has_ai_attribution >/dev/null; then
  echo "Refusing to mark: scripts/coauthor-decision.sh is missing or failed to load, so the AI/agent attribution rule cannot be checked. Reinstall or update the plugin." >&2
  exit 1
fi

# Usage: printf '%s' "<final message text>" | git-message-mark-reviewed.sh

MESSAGE=$(cat)
if [[ -z "$MESSAGE" ]]; then
  echo "No message text on stdin — nothing to mark." >&2
  exit 1
fi

# The hash below is still taken over the whole message, allowed lines included:
# it must match the text the commit-time hook extracts from the command.
COAUTHOR="$(coauthor_decision)"
if has_ai_attribution "$MESSAGE" "$COAUTHOR"; then
  if [[ "$COAUTHOR" == "yes" ]]; then
    echo "Refusing to mark: this text credits an AI/agent beyond the two co-authorship lines the human allowed (rules.md §12.3). Keep only the harness's Co-Authored-By trailer and PR line, each on a line of its own, and mark the rewritten text instead." >&2
  else
    echo "Refusing to mark: this text contains AI/agent/LLM attribution or co-authorship, and the human's co-authorship decision for this repository is no (the default) or could not be read (rules.md §12.3). Remove it and mark the rewritten text instead." >&2
  fi
  exit 1
fi

MARKER_DIR="$(marker_subdir)"
# Mode 700 when created; a refusal, with the reason, rather than a write into a
# directory that is a symlink, someone else's, or group/world-writable.
marker_ensure_dir "$MARKER_DIR" || exit 1
MESSAGE_HASH=$(printf '%s' "$MESSAGE" | shasum | cut -d' ' -f1)
printf '{"reviewedAt":"%s"}' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  | marker_write "$MARKER_DIR/$MESSAGE_HASH.json" || {
  echo "Could not write the reviewed marker to $MARKER_DIR safely — nothing marked." >&2
  exit 1
}

echo "Marked commit/PR message as reviewed (hash ${MESSAGE_HASH:0:12}…) — pre-commit-message-check.sh will recognize this exact text and won't ask again. Any edit to it after this point needs re-marking."
