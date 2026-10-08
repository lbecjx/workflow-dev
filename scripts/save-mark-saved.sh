#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
# Invoked by the save skill's Step 6, only after Step 5 has actually written
# the story file. Advances the story's save point to exactly what
# save-read-unsaved.sh last extracted — never recomputed fresh, so a source
# that kept growing during the save can't cause drift. Bookkeeping with
# correctness stakes (get the position wrong and a future read silently skips
# content nobody saved), so it lives in a script, not prose.
#
# The position is a line count into the Claude Code transcript the hooks
# recorded (`claudePath`/`claudeLength`, the shape both compaction hooks write
# too). Keys an earlier version wrote for a second source are dropped on the
# next write.
#
# Usage: save-mark-saved.sh <STORY-ID>

STORY_ID="$1"
if [[ -z "$STORY_ID" ]]; then
  echo "Usage: save-mark-saved.sh <STORY-ID>" >&2
  exit 1
fi

STATE_DIR=".workflow-dev/context/.compaction-state"
STATE_FILE="$STATE_DIR/${STORY_ID}.json"
PENDING_FILE="$STATE_DIR/.pending-save-${STORY_ID}"

json_get_string() {
  printf '%s' "$1" | grep -o "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 | sed -E 's/.*: *"(.*)"/\1/'
}
json_get_number() {
  printf '%s' "$1" | grep -o "\"$2\"[[:space:]]*:[[:space:]]*[0-9]*" | head -1 | grep -o '[0-9]*$'
}

NOW_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# BSD date (macOS): -u on a -f parse also forces UTC on the OUTPUT side, so the
# one-step "-j -u -f ... +format" form prints the value back in UTC instead of
# local time (reproduced: local 11:19 PM printed as "4:19 AM"). Two steps:
# parse to an epoch with -u, then format that epoch WITHOUT -u.
local_time() {
  local epoch
  epoch=$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$NOW_UTC" '+%s' 2>/dev/null)
  if [[ -n "$epoch" ]]; then
    date -r "$epoch" '+%Y-%m-%d at %-I:%M %p' 2>/dev/null
  else
    date -d "$NOW_UTC" '+%Y-%m-%d at %-I:%M %p' 2>/dev/null
  fi
}
WHEN=$(local_time); [[ -n "$WHEN" ]] || WHEN="$NOW_UTC (UTC)"

if [[ ! -f "$PENDING_FILE" ]]; then
  echo "No pending unsaved-read for $STORY_ID to mark — nothing to do."
  exit 0
fi

# Keep the transcript path, reading the old shape if that's what the existing
# state is.
CPATH=""
if [[ -f "$STATE_FILE" ]]; then
  SJ=$(cat "$STATE_FILE")
  CPATH=$(json_get_string "$SJ" claudePath); [[ -n "$CPATH" ]] || CPATH=$(json_get_string "$SJ" transcriptPath)
fi

# The position save-read-unsaved.sh extracted. A pending marker with no
# `length` was left by an older version for a source this plugin no longer
# reads — there is no Claude Code position in it to advance to.
CLEN=$(json_get_number "$(cat "$PENDING_FILE")" length)
if [[ -z "$CLEN" ]]; then
  echo "Pending marker for $STORY_ID carries no transcript position — nothing to mark." >&2
  exit 0
fi

printf '{"claudePath":"%s","claudeLength":%s,"dateTime":"%s","pendingSave":false}' \
  "$CPATH" "$CLEN" "$NOW_UTC" > "$STATE_FILE"
rm -f "$PENDING_FILE"

echo "Marked $STORY_ID as saved through line $CLEN ($WHEN) — future reads will only include what comes after."
