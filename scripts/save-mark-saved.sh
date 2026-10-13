#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
# Invoked by the save skill's Step 6, only after Step 5 has actually written
# the story file. Advances each of the story's save points to exactly what
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
# Usage: save-mark-saved.sh <STORY-ID> [<READ-ID>] [--discard]
# <READ-ID> is the id save-read-unsaved.sh printed. Without it, the one read
# waiting for this story is marked, and nothing when there are several.
# --discard drops that read without marking anything (the human declined the
# save): its lines stay unsaved for the next read.

DISCARD=0
ARGS=()
for A in "$@"; do
  if [[ "$A" == "--discard" ]]; then DISCARD=1; else ARGS+=("$A"); fi
done
STORY_ID="${ARGS[0]:-}"
READ_ID="${ARGS[1]:-}"
if [[ -z "$STORY_ID" ]]; then
  echo "Usage: save-mark-saved.sh <STORY-ID> [<READ-ID>] [--discard]" >&2
  exit 1
fi

STATE_DIR=".workflow-dev/context/.compaction-state"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=compaction-state.sh
source "$HERE/compaction-state.sh"

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

if ! valid_story_id "$STORY_ID" || [[ -n "$READ_ID" && ! "$READ_ID" =~ ^[A-Za-z0-9-]+$ ]]; then
  echo "Not a story id or read id: $STORY_ID $READ_ID" >&2
  exit 1
fi

# Without a read id, the reads waiting for this story decide: exactly one (an
# id, or the id-less pending of an older version) is marked; several are two
# saves in flight, and guessing which one was confirmed could mark lines nobody
# saved.
if [[ -z "$READ_ID" ]]; then
  IDS="$(while IFS= read -r STATE_FILE; do
    BASE="$(pending_path "$STATE_FILE" "")"
    while IFS= read -r PF; do
      [[ "$PF" == "$BASE" ]] && printf '%s\n' "-" || printf '%s\n' "${PF#"$BASE"-}"
    done < <(pending_files "$STATE_FILE")
  done < <(state_files "$STORY_ID") | sort -u)"
  if [[ -z "$IDS" ]]; then
    echo "No pending unsaved-read for $STORY_ID to mark — nothing to do."
    exit 0
  fi
  if [[ "$(printf '%s\n' "$IDS" | wc -l | tr -d ' ')" -gt 1 ]]; then
    echo "Several reads of $STORY_ID are waiting (another session may be saving it too); pass the read id save-read-unsaved.sh printed. Nothing marked." >&2
    exit 0
  fi
  [[ "$IDS" == "-" ]] || READ_ID="$IDS"
fi

# Each save point this read left a pending position for, one per session
# transcript: advance each to its own position, never to another's, and never
# backwards (a later save may already have gone further).
MARKED=0
while IFS= read -r STATE_FILE; do
  PENDING_FILE="$(pending_path "$STATE_FILE" "$READ_ID")"
  [[ -f "$PENDING_FILE" && ! -L "$PENDING_FILE" ]] || continue
  if [[ "$DISCARD" == 1 ]]; then
    rm -f "$PENDING_FILE"
    MARKED=1
    continue
  fi
  state_writable "$STATE_FILE" || continue
  MARKED=1
  # Keep the transcript path, reading the old shape if that's what the
  # existing state is.
  SJ=$(cat "$STATE_FILE")
  CPATH=$(json_get_string "$SJ" claudePath); [[ -n "$CPATH" ]] || CPATH=$(json_get_string "$SJ" transcriptPath)
  OLD=$(json_get_number "$SJ" claudeLength); [[ -n "$OLD" ]] || OLD=$(json_get_number "$SJ" length); [[ -n "$OLD" ]] || OLD=0
  # The position save-read-unsaved.sh extracted. A pending marker with no
  # `length` was left by an older version for a source this plugin no longer
  # reads — there is no Claude Code position in it to advance to.
  CLEN=$(json_get_number "$(cat "$PENDING_FILE")" length)
  if [[ -z "$CLEN" ]]; then
    echo "Pending marker for $STORY_ID carries no transcript position — nothing to mark." >&2
    continue
  fi
  [[ "$CLEN" -ge "$OLD" ]] || CLEN="$OLD"
  # A compaction that armed this save point after the read keeps its flag: the
  # lines it is about came after what this save covered, and its session still
  # needs the reminder.
  PENDING_SAVE=false
  SEEN_SUM=$(json_get_string "$(cat "$PENDING_FILE")" stateSum)
  if [[ "$(state_sum "$STATE_FILE")" != "$SEEN_SUM" ]] && grep -q '"pendingSave"[[:space:]]*:[[:space:]]*true' "$STATE_FILE"; then
    PENDING_SAVE=true
  fi
  printf '{"claudePath":"%s","claudeLength":%s,"dateTime":"%s","pendingSave":%s}' \
    "$CPATH" "$CLEN" "$NOW_UTC" "$PENDING_SAVE" > "$STATE_FILE"
  rm -f "$PENDING_FILE"
  echo "Marked $STORY_ID as saved through line $CLEN of $(shown_path "$CPATH") ($WHEN) — future reads will only include what comes after."
done < <(state_files "$STORY_ID")

if [[ "$MARKED" == 0 ]]; then
  echo "No pending unsaved-read for $STORY_ID to mark — nothing to do."
elif [[ "$DISCARD" == 1 ]]; then
  echo "Dropped the declined read of $STORY_ID — its lines stay unsaved for the next read."
fi
exit 0
