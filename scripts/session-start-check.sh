#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
# SessionStart hook — suggests the right next workflow-dev skill based on the
# active story's real state, so returning to a project after time away
# doesn't require remembering where things were left off.
#
# Only acts on a genuinely new session (source == "startup") — not on
# resume/clear/compact/fork, which would repeat this mid-conversation (e.g.
# right after PreCompact already showed its own reminder). The field is
# "source", not "session_start_reason" — the previous name never matched
# Claude Code's actual SessionStart input, so this whole hook silently
# no-opped on every real session since it was written; manual tests missed
# this because they fed the script the wrong field name themselves.

INPUT=$(cat)
REASON=$(printf '%s' "$INPUT" | grep -o '"source"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4)
[[ "$REASON" == "startup" ]] || exit 0

CONTEXT_DIR=".workflow-dev/context"
[[ -d "$CONTEXT_DIR" ]] || exit 0

# Tolerant to how the Implementation Status section is actually worded — the
# template says "### Implementation Status: In Progress" on one line, but a
# real /workflow-dev:init run paraphrased it as a "## Implementation Status"
# heading with the value on its own "**Status:** In Progress" line below.
# Rather than trust the model to reproduce the template byte-for-byte every
# time, scan the whole section (heading to next heading) for "In Progress".
is_in_progress() {
  awk '
    /^#+[[:space:]].*[Ii]mplementation Status/ {
      in_section=1
      if ($0 ~ /In Progress/) { found=1; exit }
      next
    }
    in_section && /^#+[[:space:]]/ { exit }
    in_section && /In Progress/ { found=1; exit }
    END { exit !found }
  ' "$1"
}

suggest() {
  printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}' "$1"
}

# Check every story file, not just one — a project can have several (done,
# won't-do, in-progress) and only the in-progress ones matter here.
while IFS= read -r STORY_FILE; do
  # Cheap gate first: only our own Implementation Status matters here — the
  # section 1.1 Story `Status` just mirrors the source ticket and is a
  # different clock (it can say "In Review" while we're Done, or "Done" while
  # we still have task groups left). Done and Won't Do are both closed on our
  # side, nothing to resume.
  is_in_progress "$STORY_FILE" || continue

  if ! grep -qE "^## [0-9]+\. Plan" "$STORY_FILE"; then
    suggest "Active workflow-dev story with no Plan yet ($STORY_FILE). Suggest /workflow-dev:resume, then /workflow-dev:plan."
    exit 0
  fi

  # Scoped to the Plan Progress table specifically — the top-level Status field
  # always contains the literal words "In Progress" too, so grepping the whole
  # file here would never reach the "all Done" branch below.
  PLAN_PROGRESS=$(awk '/^### Plan Progress/{flag=1; next} /^## /{flag=0} flag' "$STORY_FILE")

  if printf '%s' "$PLAN_PROGRESS" | grep -q "Not Started\|In Progress"; then
    suggest "Active workflow-dev story with unfinished task groups ($STORY_FILE). Suggest /workflow-dev:resume to continue."
  else
    suggest "This workflow-dev story ($STORY_FILE) shows every task group as Done (already validated). Check for uncommitted changes — if any, review and commit; if not, it may be ready to close out."
  fi
  exit 0
done < <(find "$CONTEXT_DIR" -maxdepth 1 -name "*.md" ! -name "REPO.md")

exit 0
