#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
# PreCompact hook — a compaction summary can lose decisions/discoveries that
# only ever lived in the conversation, never in a file. This hook does NOT
# rely on telling anyone about it: per Claude Code's own docs, PreCompact
# discards systemMessage and additionalContext entirely (they go to the
# debug log only, never to Claude or the human) — no JSON field can carry
# text out of this event. So instead of notifying, it acts: it backs up the
# raw transcript itself, unconditionally, and leaves a marker for the
# UserPromptSubmit hook (which DOES reliably get additionalContext to
# Claude) to raise it at the very next prompt.
#
# Deliberately does NOT filter on git status: a clean working tree doesn't
# mean nothing worth saving happened — research findings and decisions can
# live purely in the conversation, with zero files touched.

CONTEXT_DIR=".workflow-dev/context"
[[ -d "$CONTEXT_DIR" ]] || exit 0

INPUT=$(cat)
TRANSCRIPT_PATH=$(printf '%s' "$INPUT" | grep -o '"transcript_path"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4)

BACKUP_DIR="$CONTEXT_DIR/.compaction-backups"

# The transcript can contain anything pasted into the conversation, tokens
# and credentials included — never let it end up tracked by git, regardless
# of whether this project keeps .workflow-dev/ itself tracked or ignored.
ensure_gitignored() {
  local pattern="$CONTEXT_DIR/.compaction-backups/"
  [[ -f .gitignore ]] || touch .gitignore
  grep -qxF "$pattern" .gitignore || printf '%s\n' "$pattern" >> .gitignore
}

# Check every story file, not just one — a project can have several
# (done, won't-do, in-progress) and only the in-progress ones matter here.
while IFS= read -r STORY_FILE; do
  # Our own Implementation Status, not the section 1.1 Story `Status` (which
  # just mirrors the source ticket and is a separate, independent clock).
  IMPL_STATUS_LINE=$(grep -m1 '^### Implementation Status:' "$STORY_FILE")
  if [[ "$IMPL_STATUS_LINE" == *"In Progress"* ]]; then
    if [[ -n "$TRANSCRIPT_PATH" && -f "$TRANSCRIPT_PATH" ]]; then
      mkdir -p "$BACKUP_DIR"
      ensure_gitignored
      TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)
      STORY_NAME=$(basename "$STORY_FILE" .md)
      BACKUP_FILE="$BACKUP_DIR/${STORY_NAME}-${TIMESTAMP}.jsonl"
      cp "$TRANSCRIPT_PATH" "$BACKUP_FILE"
      # Read by user-prompt-compaction-check.sh on the very next prompt —
      # overwritten (not appended) so only the most recent compaction is
      # flagged; a second one before the marker is consumed just replaces it.
      printf '%s\n%s\n' "$STORY_FILE" "$BACKUP_FILE" > "$BACKUP_DIR/.pending-save-notice"
    fi
    # terminalSequence is the one field documented as "supported on all
    # events" — it can't carry the reason text, just ring the terminal bell
    # as a best-effort signal, emitted here as the JSON escape for the BEL
    # control character rather than a raw byte, which would make the JSON
    # output invalid.
    printf '{"terminalSequence":"\\u0007"}'
    exit 0
  fi
done < <(find "$CONTEXT_DIR" -maxdepth 1 -name "*.md" ! -name "REPO.md")

exit 0
