#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  Luis Becerra
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
# SessionStart hook — suggests the right next workflow-dev skill based on the
# active story's real state, so returning to a project after time away
# doesn't require remembering where things were left off.
#
# Only acts on a genuinely new session (session_start_reason == "startup") —
# not on resume/clear/compact/fork, which would repeat this mid-conversation
# (e.g. right after PreCompact already showed its own reminder).

INPUT=$(cat)
REASON=$(printf '%s' "$INPUT" | grep -o '"session_start_reason"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4)
[[ "$REASON" == "startup" ]] || exit 0

CONTEXT_DIR=".workflow-dev/context"
[[ -d "$CONTEXT_DIR" ]] || exit 0

STORY_FILE=$(find "$CONTEXT_DIR" -maxdepth 1 -name "*.md" ! -name "REPO.md" | head -1)
[[ -n "$STORY_FILE" ]] || exit 0

# Cheap gate first: only our own Implementation Status matters here — the
# section 1.1 Story `Status` just mirrors the source ticket and is a
# different clock (it can say "In Review" while we're Done, or "Done" while
# we still have task groups left). Done and Won't Do are both closed on our
# side, nothing to resume.
IMPL_STATUS_LINE=$(grep -m1 '^### Implementation Status:' "$STORY_FILE")
[[ "$IMPL_STATUS_LINE" == *"In Progress"* ]] || exit 0

suggest() {
  printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}' "$1"
}

if ! grep -q "^## 5. Plan" "$STORY_FILE"; then
  suggest "Active workflow-dev story with no Plan yet ($STORY_FILE). Suggest /workflow-dev:resume, then /workflow-dev:plan."
  exit 0
fi

# Scoped to the Plan Progress table specifically — the top-level Status field
# always contains the literal words "In Progress" too, so grepping the whole
# file here would never reach the "all Done" branch below.
PLAN_PROGRESS=$(awk '/^### Plan Progress/{flag=1; next} /^## /{flag=0} flag' "$STORY_FILE")

if printf '%s' "$PLAN_PROGRESS" | grep -q "Not Started\|In Progress"; then
  suggest "Active workflow-dev story with unfinished task groups. Suggest /workflow-dev:resume to continue."
else
  suggest "This workflow-dev story shows every task group as Done (already validated). Check for uncommitted changes — if any, review and commit; if not, it may be ready to close out."
fi
exit 0
