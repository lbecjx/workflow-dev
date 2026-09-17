#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
# Invoked by the save skill's Step 6, only after Step 5 has actually
# written the story file. Advances the story's compaction-state to exactly
# the point save-read-unsaved.sh last extracted up to — never recomputed
# fresh, so a transcript that kept growing during the save's own execution
# can't cause drift. This is bookkeeping with correctness stakes (get the
# number wrong and a future read silently skips content nobody actually
# saved) — exactly the kind of exact, mechanical task that belongs in a
# script, not in prose a model re-derives by hand on every run.
#
# Usage: save-mark-saved.sh <STORY-ID>

STORY_ID="$1"
if [[ -z "$STORY_ID" ]]; then
  echo "Usage: save-mark-saved.sh <STORY-ID>" >&2
  exit 1
fi

STATE_DIR=".workflow-dev/context/.compaction-state"
STATE_FILE="$STATE_DIR/${STORY_ID}.json"
PENDING_LENGTH_FILE="$STATE_DIR/.pending-length-${STORY_ID}"

json_get_string() {
  printf '%s' "$1" | grep -o "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 | sed -E 's/.*: *"(.*)"/\1/'
}

if [[ ! -f "$PENDING_LENGTH_FILE" ]]; then
  echo "No pending unsaved-read for $STORY_ID to mark — nothing to do."
  exit 0
fi

NEW_LENGTH=$(cat "$PENDING_LENGTH_FILE")
NOW_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)

TRANSCRIPT_PATH=""
if [[ -f "$STATE_FILE" ]]; then
  TRANSCRIPT_PATH=$(json_get_string "$(cat "$STATE_FILE")" "transcriptPath")
fi

# pendingSave is always false here regardless of what it was before: a
# save just completed, and the reminder that would have set it true again
# only fires on the NEXT compaction, past this point.
printf '{"transcriptPath":"%s","length":%s,"dateTime":"%s","pendingSave":false}' "$TRANSCRIPT_PATH" "$NEW_LENGTH" "$NOW_UTC" > "$STATE_FILE"
rm -f "$PENDING_LENGTH_FILE"

# BSD date (macOS): -u on a -f parse also forces UTC on the OUTPUT side,
# not just the input — a single-step "-j -u -f ... +format" call silently
# prints the parsed value back out in UTC, never actually converting to
# local time (confirmed by reproducing it directly: with the real local
# clock reading 11:19 PM, this one-step form printed "4:19 AM" — the
# unconverted UTC value). The fix is the standard two-step form: parse to
# an epoch integer (the one step -u is legitimately needed for, since it
# tells date to interpret the input string itself as UTC), then format
# that epoch WITHOUT -u, which is what actually renders in local time.
EPOCH=$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$NOW_UTC" '+%s' 2>/dev/null)
if [[ -n "$EPOCH" ]]; then
  LOCAL_TIME=$(date -r "$EPOCH" '+%Y-%m-%d at %-I:%M %p' 2>/dev/null)
else
  # GNU date (Linux): -d correctly interprets a Z-suffixed ISO 8601
  # string as UTC and renders the output in local time by default, with
  # no equivalent one-step trap — no epoch round-trip needed here.
  LOCAL_TIME=$(date -d "$NOW_UTC" '+%Y-%m-%d at %-I:%M %p' 2>/dev/null)
fi
[[ -n "$LOCAL_TIME" ]] || LOCAL_TIME="$NOW_UTC (UTC)"

echo "Marked $STORY_ID as saved through line $NEW_LENGTH ($LOCAL_TIME) — future reads will only include what comes after."
