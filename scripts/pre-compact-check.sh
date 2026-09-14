#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
# PreCompact hook — warns before context gets compacted if there's an active
# workflow-dev story, since decisions/discoveries from the conversation (not
# just file changes) are exactly what a compaction summary can lose.
#
# Deliberately does NOT filter on git status: a clean working tree doesn't
# mean nothing worth saving happened — research findings and decisions can
# live purely in the conversation, with zero files touched.
#
# PreCompact does not surface systemMessage or additionalContext to anyone —
# per Claude Code's own docs, those only reach Claude/the human on
# UserPromptSubmit, UserPromptExpansion, SessionStart, and PostModelSwitch;
# on every other event, including PreCompact, they go to the debug log only.
# terminalSequence is the one field documented as "supported on all events",
# so it's the only way this hook can actually get a human's attention —
# it can't carry the reason text, just ring the terminal bell. The bell is
# emitted below as a JSON-escaped control character, not a raw byte, since
# a raw control byte inside a JSON string would make the output invalid.

CONTEXT_DIR=".workflow-dev/context"
[[ -d "$CONTEXT_DIR" ]] || exit 0

# Check every story file, not just one — a project can have several
# (done, won't-do, in-progress) and only the in-progress ones matter here.
while IFS= read -r STORY_FILE; do
  # Our own Implementation Status, not the section 1.1 Story `Status` (which
  # just mirrors the source ticket and is a separate, independent clock).
  IMPL_STATUS_LINE=$(grep -m1 '^### Implementation Status:' "$STORY_FILE")
  if [[ "$IMPL_STATUS_LINE" == *"In Progress"* ]]; then
    printf '{"systemMessage":"Session about to compact — %s is still In Progress. If anything from this conversation (decisions, discoveries) should persist, run /workflow-dev:save first.","terminalSequence":"\\u0007"}' "$STORY_FILE"
    exit 0
  fi
done < <(find "$CONTEXT_DIR" -maxdepth 1 -name "*.md" ! -name "REPO.md")

exit 0
