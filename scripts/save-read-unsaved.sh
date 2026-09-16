#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
# Invoked by the save skill's Step 3. Reads the story's compaction-state
# file, goes straight to the live transcript file it names, and prints
# everything past the last confirmed save — the raw material a compaction
# summary might have smoothed over or dropped. No copy of the transcript is
# ever kept: Claude Code's own session .jsonl files are append-only and
# persist indefinitely on disk, so the original is always there to read
# directly, live, at whatever line it's needed from.
#
# Usage: save-read-unsaved.sh <STORY-ID>
# Prints the unsaved extract (or an explanatory message) to stdout.

STORY_ID="$1"
if [[ -z "$STORY_ID" ]]; then
  echo "Usage: save-read-unsaved.sh <STORY-ID>" >&2
  exit 1
fi

STATE_DIR=".workflow-dev/context/.compaction-state"
STATE_FILE="$STATE_DIR/${STORY_ID}.json"
PENDING_LENGTH_FILE="$STATE_DIR/.pending-length-${STORY_ID}"

json_get_string() {
  printf '%s' "$1" | grep -o "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 | sed -E 's/.*: *"(.*)"/\1/'
}

json_get_number() {
  printf '%s' "$1" | grep -o "\"$2\"[[:space:]]*:[[:space:]]*[0-9]*" | head -1 | grep -o '[0-9]*$'
}

if [[ ! -f "$STATE_FILE" ]]; then
  echo "No compaction state for $STORY_ID — nothing to extract."
  exit 0
fi

STATE_JSON=$(cat "$STATE_FILE")
TRANSCRIPT_PATH=$(json_get_string "$STATE_JSON" "transcriptPath")
LAST_LENGTH=$(json_get_number "$STATE_JSON" "length")
[[ -n "$LAST_LENGTH" ]] || LAST_LENGTH=0

if [[ -z "$TRANSCRIPT_PATH" || ! -f "$TRANSCRIPT_PATH" ]]; then
  echo "State for $STORY_ID points to a transcript that no longer exists ($TRANSCRIPT_PATH) — nothing to extract."
  exit 0
fi

CURRENT_TOTAL=$(wc -l < "$TRANSCRIPT_PATH" | tr -d '[:space:]')

if [[ "$CURRENT_TOTAL" -le "$LAST_LENGTH" ]]; then
  echo "Nothing unsaved for $STORY_ID — transcript has $CURRENT_TOTAL lines, all already covered by the last save."
  exit 0
fi

# Record exactly what this read covered, so save-mark-saved.sh advances the
# state to precisely this point — not a value recomputed later, which
# could silently drift if the transcript grew further in between.
printf '%s' "$CURRENT_TOTAL" > "$PENDING_LENGTH_FILE"

tail -n "+$((LAST_LENGTH + 1))" "$TRANSCRIPT_PATH"
