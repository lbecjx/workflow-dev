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

set -u

CONTEXT_DIR=".workflow-dev/context"
STATE_DIR="$CONTEXT_DIR/.compaction-state"

[[ -d "$STATE_DIR" ]] || exit 0

INPUT=$(cat)
EVENT_NAME=$(printf '%s' "$INPUT" | grep -o '"hook_event_name"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4)
[[ -n "$EVENT_NAME" ]] || exit 0
# The session is its transcript: pre-compact-check.sh records it in each state
# it arms. Without one, no flag can be told apart from another session's.
TRANSCRIPT_PATH=$(printf '%s' "$INPUT" | grep -o '"transcript_path"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4)
[[ -n "$TRANSCRIPT_PATH" ]] || exit 0

# The same status reader the PreCompact hook marks with, so a story it would
# not mark is never announced either. This hook runs on every tool call, so it
# reads the state files and the story file, never the transcript.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=session-story.sh
source "$HERE/session-story.sh"
# shellcheck source=compaction-state.sh
source "$HERE/compaction-state.sh"

json_get_string() {
  printf '%s' "$1" | grep -o "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 | sed -E 's/.*: *"(.*)"/\1/'
}

json_get_number() {
  printf '%s' "$1" | grep -o "\"$2\"[[:space:]]*:[[:space:]]*[0-9]*" | head -1 | grep -o '[0-9]*$'
}

json_get_bool() {
  printf '%s' "$1" | grep -o "\"$2\"[[:space:]]*:[[:space:]]*\(true\|false\)" | head -1 | grep -o 'true\|false'
}

# Only this session's save points: every other session's stay on disk for good
# (each holds what that session may not have saved), so walking all of them on
# every tool call would slow each call a little more with every session ever.
while IFS= read -r STATE_FILE; do
  STATE_JSON=$(cat "$STATE_FILE")
  PENDING=$(json_get_bool "$STATE_JSON" "pendingSave")
  [[ "$PENDING" == "true" ]] || continue

  STORY_ID=$(state_story "$STATE_FILE")
  STORY_FILE="$CONTEXT_DIR/${STORY_ID}.md"

  TRANSCRIPT_PATH_STATE=$(json_get_string "$STATE_JSON" "claudePath")
  [[ -n "$TRANSCRIPT_PATH_STATE" ]] || TRANSCRIPT_PATH_STATE=$(json_get_string "$STATE_JSON" "transcriptPath")
  # Only this session's flag, for a story still open. Any other pending flag
  # is left exactly as it is: it may be owed to another session working in
  # this repo right now, and flipping it here would eat that reminder. A flag
  # left over from an older version, or for a story since closed, then stays
  # on disk and is never announced (WD-0081: one for WD-0052, Done for weeks,
  # was announced twice while WD-0080 was being worked). Nothing is lost by
  # not announcing it here: every save of the story reads the unsaved part of
  # every session's save point (save-read-unsaved.sh).
  [[ "$TRANSCRIPT_PATH_STATE" == "$TRANSCRIPT_PATH" ]] || continue
  [[ -f "$STORY_FILE" ]] && is_in_progress "$STORY_FILE" || continue

  # Flip it off now, not after a successful print — a flag stuck on
  # forever, nagging on every future prompt/tool call, is worse than
  # missing one notice. Preserve the save point exactly as it was — in the
  # shape save-mark-saved.sh writes, reading the older `transcriptPath`/`length`
  # names too; only the position and dateTime ever advance, and only via
  # save-mark-saved.sh.
  LENGTH=$(json_get_number "$STATE_JSON" "claudeLength")
  [[ -n "$LENGTH" ]] || LENGTH=$(json_get_number "$STATE_JSON" "length")
  [[ -n "$LENGTH" ]] || LENGTH=0
  DATETIME=$(json_get_string "$STATE_JSON" "dateTime")
  DATETIME_JSON="null"
  [[ -n "$DATETIME" ]] && DATETIME_JSON="\"$DATETIME\""
  printf '{"claudePath":"%s","claudeLength":%s,"dateTime":%s,"pendingSave":false}' \
    "$TRANSCRIPT_PATH_STATE" "$LENGTH" "$DATETIME_JSON" > "$STATE_FILE"

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

  REMINDER="A context compaction happened while $STORY_FILE was In Progress — there may be unsaved conversation history for it. $PRIORITY_CLAUSE: do both of these, without asking permission first: (1) Invoke /workflow-dev:save; its own 'save all this?' step is the only confirmation this needs. (2) In that same confirmation, add this line verbatim: 'Declining deletes nothing, but leaves this out of the story file until a future save reads it.' Only once save is done, proceed with what you were about to do."
  printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":"%s"}}' "$EVENT_NAME" "$REMINDER"
  exit 0
done < <(session_state_files "$TRANSCRIPT_PATH")

exit 0
