#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Invoked by the save skill's Step 3. Reads the story's save points (one per
# session transcript) and prints everything past the last confirmed save — the raw material a
# compaction summary might have smoothed over or dropped.
#
# The save point is the Claude Code transcript the hooks recorded, and a line
# count into it:
#   {"claudePath":"…","claudeLength":N,"dateTime":"…","pendingSave":false}
# The older shape (`transcriptPath`/`length`) is read as the same two fields, so
# existing states keep working. Keys written by earlier versions for a second
# source are ignored.
#
# Usage: save-read-unsaved.sh [--digest|--raw] <STORY-ID>
# Prints the unsaved extract to stdout. `--digest` (what the save skill uses)
# prints a readable line per message — channel + text, tool-calls/reasoning
# stripped; `--raw` (the default) prints the transcript's raw lines.

STORY_ID=""
DIGEST=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --digest) DIGEST=1; shift ;;
    --raw)    DIGEST=0; shift ;;
    *) STORY_ID="$1"; shift ;;
  esac
done
if [[ -z "$STORY_ID" ]]; then
  echo "Usage: save-read-unsaved.sh [--digest|--raw] <STORY-ID>" >&2
  exit 1
fi

STATE_DIR=".workflow-dev/context/.compaction-state"

json_get_string() {
  printf '%s' "$1" | grep -o "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 | sed -E 's/.*: *"(.*)"/\1/'
}
json_get_number() {
  printf '%s' "$1" | grep -o "\"$2\"[[:space:]]*:[[:space:]]*[0-9]*" | head -1 | grep -o '[0-9]*$'
}
have_jq() { command -v jq >/dev/null 2>&1; }

# A readable line per message — channel + text, with tool-call payloads and
# reasoning stripped. This is what the save step actually reviews; emitting it
# instead of raw JSON keeps a huge transcript dump out of the orchestrator's
# context (a measured main-thread cost driver). Best-effort: if jq can't parse
# the line, nothing is printed for it.
digest_text() { # stdin: one transcript line (JSON)
  jq -r '
    def textof:
      ( (.message.content? // .content?) ) as $c
      | if ($c | type) == "array"
          then [ $c[]? | select(.type? == "text") | .text? // empty ] | join("\n")
        elif ($c | type) == "string" then $c
        else "" end;
    (.message.role? // .type? // "?") as $r
    | (textof) as $t
    | select($t != "")
    | "[\($r)] \($t)"' 2>/dev/null
}

# The state dir holds absolute paths — machine state that must never reach git,
# whatever the project's choice for .workflow-dev/ itself.
ensure_gitignored() {
  local pattern=".workflow-dev/context/.compaction-state/"
  local probe=".workflow-dev/context/.compaction-state/.probe"
  # Already covered by an ancestor pattern (e.g. `.workflow-dev/`)? Then this
  # line adds nothing and would only dirty a tracked .gitignore on every save.
  if git check-ignore -q "$probe" 2>/dev/null; then return 0; fi
  [[ -f .gitignore ]] || touch .gitignore
  grep -qxF "$pattern" .gitignore || printf '%s\n' "$pattern" >> .gitignore
}

# --- Read every save point of the story ---------------------------------------
# One per session transcript (compaction-state.sh). Each one's unsaved part is
# printed under its own header, and its position recorded in its own pending
# file, so save-mark-saved.sh advances each one to exactly what was read here.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=compaction-state.sh
source "$HERE/compaction-state.sh"

if ! valid_story_id "$STORY_ID"; then
  echo "Not a story id: $STORY_ID" >&2
  exit 1
fi

# This read's id: save-mark-saved.sh takes it back, so it marks exactly what
# this read showed, whatever another save of the story read in the meantime.
READ_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
KNOWN=0
PRINTED=0
SESSIONS=0
OTHER_READS=0
NOTES=""
while IFS= read -r STATE_FILE; do
  SJ=$(cat "$STATE_FILE")
  CPATH=$(json_get_string "$SJ" claudePath); [[ -n "$CPATH" ]] || CPATH=$(json_get_string "$SJ" transcriptPath)
  CLEN=$(json_get_number "$SJ" claudeLength); [[ -n "$CLEN" ]] || CLEN=$(json_get_number "$SJ" length); [[ -n "$CLEN" ]] || CLEN=0
  [[ -n "$CPATH" ]] || continue
  KNOWN=1
  if [[ ! -f "$CPATH" ]]; then
    NOTES="${NOTES}State for $STORY_ID points to a transcript that no longer exists ($(shown_path "$CPATH")) — nothing to extract from it."$'\n'
    continue
  fi
  if ! trusted_transcript "$CPATH"; then
    NOTES="${NOTES}State for $STORY_ID names a file that is not a Claude Code transcript of this project ($(shown_path "$CPATH")) — not read. A state file from a cloned repo can point anywhere."$'\n'
    continue
  fi
  # A read nobody confirmed or declined for a day belongs to a save that never
  # finished: drop it, or it would pass for another session saving right now.
  while IFS= read -r PF; do
    [[ -n "$(find "$PF" -mmin +1440 2>/dev/null)" ]] && rm -f "$PF"
  done < <(pending_files "$STATE_FILE")
  CURRENT_TOTAL=$(wc -l < "$CPATH" | tr -d '[:space:]')
  [[ "$CURRENT_TOTAL" -gt "$CLEN" ]] || continue
  [[ -n "$(pending_files "$STATE_FILE")" ]] && OTHER_READS=1
  ensure_gitignored
  PENDING="$(pending_path "$STATE_FILE" "$READ_ID")"
  [[ -L "$PENDING" ]] && continue
  printf '{"length":%s,"stateSum":"%s"}' "$CURRENT_TOTAL" "$(state_sum "$STATE_FILE")" > "$PENDING"
  SESSIONS=$((SESSIONS + 1))
  echo "=== Unsaved for $STORY_ID from session transcript $CPATH (lines $((CLEN + 1))-$CURRENT_TOTAL) ==="
  if [[ "$DIGEST" == "1" ]] && have_jq; then
    tail -n "+$((CLEN + 1))" "$CPATH" | head -n "$((CURRENT_TOTAL - CLEN))" | digest_text
  else
    tail -n "+$((CLEN + 1))" "$CPATH" | head -n "$((CURRENT_TOTAL - CLEN))"
  fi
  PRINTED=1
done < <(state_files "$STORY_ID")

[[ -n "$NOTES" ]] && printf '%s' "$NOTES"
if [[ "$KNOWN" == 0 ]]; then
  echo "No Claude Code transcript known for $STORY_ID — nothing to extract. (A save will record one once a Claude hook has run.)"
elif [[ "$PRINTED" == 0 ]]; then
  echo "Nothing unsaved for $STORY_ID — every session's transcript is already covered by the last save."
else
  if [[ "$SESSIONS" -gt 1 ]]; then
    echo "=== $SESSIONS sessions worked $STORY_ID without saving. Compare them with each other and with the story file before saving: they may disagree. ==="
  fi
  if [[ "$OTHER_READS" == 1 ]]; then
    echo "=== Another save of $STORY_ID read part of this and has not been confirmed or declined: another session may be saving the same story right now. ==="
  fi
  echo "Read id: $READ_ID — pass it to save-mark-saved.sh (with --discard when the save is declined)."
fi
exit 0
