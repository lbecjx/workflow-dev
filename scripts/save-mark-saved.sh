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
# Source-aware (WD-0007 AC 13): the state keeps a position **per source** —
# Claude Code's `claudePath`/`claudeLength`, OpenCode's `opencodeSession`/
# `opencodeSeq` — and marks which is `current`. This save advances only the
# current source and preserves the other, so a story that moved Claude→OpenCode
# (or into a new session) resumes correctly and switching back is cheap.
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

# Preserve the other source's position, and read the old shape if that's what
# the existing state is.
CUR=""; CPATH=""; CLEN=0; OSID=""; OSEQ=0
if [[ -f "$STATE_FILE" ]]; then
  SJ=$(cat "$STATE_FILE")
  CUR=$(json_get_string "$SJ" current)
  CPATH=$(json_get_string "$SJ" claudePath); [[ -n "$CPATH" ]] || CPATH=$(json_get_string "$SJ" transcriptPath)
  CLEN=$(json_get_number "$SJ" claudeLength); [[ -n "$CLEN" ]] || CLEN=$(json_get_number "$SJ" length); [[ -n "$CLEN" ]] || CLEN=0
  OSID=$(json_get_string "$SJ" opencodeSession)
  OSEQ=$(json_get_number "$SJ" opencodeSeq); [[ -n "$OSEQ" ]] || OSEQ=0
fi

PJ=$(cat "$PENDING_FILE")
H=$(json_get_string "$PJ" harness)

if [[ "$H" == "opencode" ]]; then
  OSID=$(json_get_string "$PJ" sessionId)
  OSEQ=$(json_get_number "$PJ" seq)
  CUR="opencode"
  OUT="message seq $OSEQ"
elif [[ "$H" == "claude" ]]; then
  CLEN=$(json_get_number "$PJ" length)
  CUR="claude"
  OUT="line $CLEN"
else
  echo "Pending marker for $STORY_ID names no known source — nothing to do." >&2
  exit 0
fi

printf '{"current":"%s","claudePath":"%s","claudeLength":%s,"opencodeSession":"%s","opencodeSeq":%s,"dateTime":"%s","pendingSave":false}' \
  "$CUR" "$CPATH" "$CLEN" "$OSID" "$OSEQ" "$NOW_UTC" > "$STATE_FILE"
rm -f "$PENDING_FILE"

echo "Marked $STORY_ID as saved through $OUT ($WHEN) — future reads will only include what comes after."
