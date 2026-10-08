#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Invoked by the save skill's Step 3. Reads the story's compaction-state file
# and prints everything past the last confirmed save — the raw material a
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
STATE_FILE="$STATE_DIR/${STORY_ID}.json"
PENDING_FILE="$STATE_DIR/.pending-save-${STORY_ID}"

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

# --- Read the existing state (with backward-compat for the old shape) --------
CPATH=""; CLEN=0
if [[ -f "$STATE_FILE" ]]; then
  SJ=$(cat "$STATE_FILE")
  CPATH=$(json_get_string "$SJ" claudePath); [[ -n "$CPATH" ]] || CPATH=$(json_get_string "$SJ" transcriptPath)
  CLEN=$(json_get_number "$SJ" claudeLength); [[ -n "$CLEN" ]] || CLEN=$(json_get_number "$SJ" length); [[ -n "$CLEN" ]] || CLEN=0
fi

# The transcript path comes from the state the Claude Code hooks wrote.
if [[ -z "$CPATH" ]]; then
  echo "No Claude Code transcript known for $STORY_ID — nothing to extract. (A save will record one once a Claude hook has run.)"
  exit 0
fi
if [[ ! -f "$CPATH" ]]; then
  echo "State for $STORY_ID points to a transcript that no longer exists ($CPATH) — nothing to extract."
  exit 0
fi
CURRENT_TOTAL=$(wc -l < "$CPATH" | tr -d '[:space:]')
if [[ "$CURRENT_TOTAL" -le "$CLEN" ]]; then
  echo "Nothing unsaved for $STORY_ID — transcript has $CURRENT_TOTAL lines, all already covered by the last save."
  exit 0
fi
mkdir -p "$STATE_DIR"; ensure_gitignored
printf '{"length":%s}' "$CURRENT_TOTAL" > "$PENDING_FILE"
if [[ "$DIGEST" == "1" ]] && have_jq; then
  tail -n "+$((CLEN + 1))" "$CPATH" | digest_text
else
  tail -n "+$((CLEN + 1))" "$CPATH"
fi
