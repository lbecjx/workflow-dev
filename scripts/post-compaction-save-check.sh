#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
# The actual delivery mechanism for the compaction warning. PreCompact
# can't hand Claude any text (see pre-compact-check.sh), but this hook's
# additionalContext is reliably delivered per Claude Code's own docs.
#
# Registered under BOTH UserPromptSubmit and PostToolUse (no matcher, so
# any tool) in hooks.json — whichever fires first after a compaction picks
# up the pending story. UserPromptSubmit alone assumes the human types
# something soon after compacting; during a long autonomous run (e.g.
# /workflow-dev:implement chaining tool calls with no human input in
# between), that assumption is false and the reminder could sit unseen for
# a long time. PostToolUse fires on every one of those tool calls, so it
# catches the case UserPromptSubmit misses.
#
# Since the same script serves two different events, hookEventName in the
# response is read from the hook's own input rather than hardcoded — the
# docs require it to match the event that actually fired.

CONTEXT_DIR=".workflow-dev/context"
STATE_DIR="$CONTEXT_DIR/.compaction-state"

[[ -d "$STATE_DIR" ]] || exit 0

INPUT=$(cat)
EVENT_NAME=$(printf '%s' "$INPUT" | grep -o '"hook_event_name"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4)
[[ -n "$EVENT_NAME" ]] || exit 0

json_get_string() {
  printf '%s' "$1" | grep -o "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 | sed -E 's/.*: *"(.*)"/\1/'
}

json_get_number() {
  printf '%s' "$1" | grep -o "\"$2\"[[:space:]]*:[[:space:]]*[0-9]*" | head -1 | grep -o '[0-9]*$'
}

json_get_bool() {
  printf '%s' "$1" | grep -o "\"$2\"[[:space:]]*:[[:space:]]*\(true\|false\)" | head -1 | grep -o 'true\|false'
}

shopt -s nullglob
for STATE_FILE in "$STATE_DIR"/*.json; do
  STATE_JSON=$(cat "$STATE_FILE")
  PENDING=$(json_get_bool "$STATE_JSON" "pendingSave")
  [[ "$PENDING" == "true" ]] || continue

  STORY_ID=$(basename "$STATE_FILE" .json)
  STORY_FILE="$CONTEXT_DIR/${STORY_ID}.md"

  # Flip it off now, not after a successful print — a flag stuck on
  # forever, nagging on every future prompt/tool call, is worse than
  # missing one notice. Preserve the other fields exactly as they were;
  # only length/dateTime ever advance, and only via save-mark-saved.sh.
  TRANSCRIPT_PATH=$(json_get_string "$STATE_JSON" "transcriptPath")
  LENGTH=$(json_get_number "$STATE_JSON" "length")
  [[ -n "$LENGTH" ]] || LENGTH=0
  DATETIME=$(json_get_string "$STATE_JSON" "dateTime")
  DATETIME_JSON="null"
  [[ -n "$DATETIME" ]] && DATETIME_JSON="\"$DATETIME\""
  printf '{"transcriptPath":"%s","length":%s,"dateTime":%s,"pendingSave":false}' \
    "$TRANSCRIPT_PATH" "$LENGTH" "$DATETIME_JSON" > "$STATE_FILE"

  # Worded per triggering event: UserPromptSubmit fires alongside a real
  # human question competing for priority; PostToolUse fires mid-sequence
  # during an autonomous run (e.g. /workflow-dev:implement), where the
  # competing pull is "keep going with the current task/next tool call"
  # instead. Both have been observed losing to a generic "before doing
  # anything else" phrasing that didn't name the specific thing it needed
  # to outrank.
  if [[ "$EVENT_NAME" == "PostToolUse" ]]; then
    PRIORITY_CLAUSE="Before running the next tool call or continuing whatever task is in progress — do not finish the current step or task first and get to this after"
  else
    PRIORITY_CLAUSE="Before answering the question below, or doing anything else this turn"
  fi

  printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":"A context compaction happened while %s was In Progress — there may be unsaved conversation history for it. %s: do both of these, without asking permission first: (1) Invoke /workflow-dev:save; its own '\''save all this?'\'' step is the only confirmation this needs. (2) In that same confirmation, add this line verbatim: '\''Declining deletes nothing, but leaves this out of the story file until a future save reads it.'\'' Only once save is done, proceed with what you were about to do."}}' "$EVENT_NAME" "$STORY_FILE" "$PRIORITY_CLAUSE"
  exit 0
done

exit 0
