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
# The save point is **source-aware** (WD-0007 AC 13): one story can be worked
# across harnesses and sessions (start costly in Claude Code, finish in
# OpenCode, or continue in a fresh session of either), so the state keeps a
# position **per source** and a `current` marker. Switching source starts the
# new one at 0 (read it all once) without discarding the other's position, so
# switching back resumes cheaply instead of re-reading everything.
#
# Flat state (grep/sed-parseable, no jq needed):
#   {"current":"opencode","claudePath":"…","claudeLength":N,
#    "opencodeSession":"…","opencodeSeq":N,"dateTime":"…","pendingSave":false}
# The old Claude-only shape (`transcriptPath`/`length`) is read as the Claude
# fields, so existing states keep working.
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
PENDING_FILE="$STATE_DIR/.pending-save-${STORY_ID}"
DB="${OPENCODE_DB:-$HOME/.local/share/opencode/opencode.db}"

json_get_string() {
  printf '%s' "$1" | grep -o "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 | sed -E 's/.*: *"(.*)"/\1/'
}
json_get_number() {
  printf '%s' "$1" | grep -o "\"$2\"[[:space:]]*:[[:space:]]*[0-9]*" | head -1 | grep -o '[0-9]*$'
}
have_sqlite3() { command -v sqlite3 >/dev/null 2>&1; }
sqlq() { printf '%s' "${1//\'/\'\'}"; }

# The state dir holds absolute paths and session ids — machine state that must
# never reach git, whatever the project's choice for .workflow-dev/ itself.
ensure_gitignored() {
  local pattern=".workflow-dev/context/.compaction-state/"
  [[ -f .gitignore ]] || touch .gitignore
  grep -qxF "$pattern" .gitignore || printf '%s\n' "$pattern" >> .gitignore
}

# Which harness is running this? OpenCode sets OPENCODE_TERMINAL; Claude Code
# sets CLAUDECODE/CLAUDE_CODE_ENTRYPOINT. Only fall back to a guess when
# neither is present (and then prefer whichever source is resolvable).
detect_harness() {
  if [[ -n "${OPENCODE_TERMINAL:-}${OPENCODE:-}" ]]; then echo opencode; return; fi
  if [[ -n "${CLAUDECODE:-}${CLAUDE_CODE_ENTRYPOINT:-}" ]]; then echo claude; return; fi
  if [[ -f "$STATE_FILE" ]]; then
    local c; c=$(json_get_string "$(cat "$STATE_FILE")" current)
    [[ -n "$c" ]] && { echo "$c"; return; }
  fi
  echo ""
}
resolve_opencode_session() { # $1 = session id to keep if still valid
  have_sqlite3 || return
  [[ -f "$DB" ]] || return
  local keep="$1"
  if [[ -n "$keep" ]]; then printf '%s' "$keep"; return; fi
  local sid
  # Top-level only: sub-agents are child sessions in the same directory and can
  # have a newer time_updated, so without `parent_id IS NULL` a just-finished
  # sub-agent gets picked as "the session".
  sid=$(sqlite3 "$DB" "SELECT id FROM session_v2 WHERE lower(directory)=lower('$(sqlq "$PWD")') AND parent_id IS NULL ORDER BY time_updated DESC LIMIT 1;")
  if [[ -z "$sid" ]]; then
    sid=$(sqlite3 "$DB" "SELECT id FROM session_v2 WHERE lower(directory)=lower('$(sqlq "$(pwd -P)")') AND parent_id IS NULL ORDER BY time_updated DESC LIMIT 1;")
  fi
  printf '%s' "$sid"
}

# --- Read the existing state (with backward-compat for the old shape) --------
CUR=""; CPATH=""; CLEN=0; OSID=""; OSEQ=0
if [[ -f "$STATE_FILE" ]]; then
  SJ=$(cat "$STATE_FILE")
  CUR=$(json_get_string "$SJ" current)
  CPATH=$(json_get_string "$SJ" claudePath); [[ -n "$CPATH" ]] || CPATH=$(json_get_string "$SJ" transcriptPath)
  CLEN=$(json_get_number "$SJ" claudeLength); [[ -n "$CLEN" ]] || CLEN=$(json_get_number "$SJ" length); [[ -n "$CLEN" ]] || CLEN=0
  OSID=$(json_get_string "$SJ" opencodeSession)
  OSEQ=$(json_get_number "$SJ" opencodeSeq); [[ -n "$OSEQ" ]] || OSEQ=0
fi

H=$(detect_harness)
if [[ -z "$H" ]]; then
  if [[ -n "$(resolve_opencode_session "")" ]]; then H=opencode; elif [[ -n "$CPATH" ]]; then H=claude; fi
fi

if [[ "$H" == "opencode" ]]; then
  SID=$(resolve_opencode_session "$OSID")
  if [[ -z "$SID" ]]; then
    echo "No compaction state for $STORY_ID — nothing to extract."
    exit 0
  fi
  # A different session than the one stored is a new source → start at 0.
  [[ -n "$OSID" && "$OSID" != "$SID" ]] && OSEQ=0
  MAX_SEQ=$(sqlite3 "$DB" "SELECT COALESCE(MAX(seq),0) FROM session_message WHERE session_id='$(sqlq "$SID")';")
  if [[ "${MAX_SEQ:-0}" -le "$OSEQ" ]]; then
    echo "Nothing unsaved for $STORY_ID — OpenCode session $SID has $MAX_SEQ messages, all already covered by the last save."
    exit 0
  fi
  mkdir -p "$STATE_DIR"; ensure_gitignored
  printf '{"harness":"opencode","sessionId":"%s","seq":%s}' "$SID" "$MAX_SEQ" > "$PENDING_FILE"
  echo "--- OpenCode session $SID — messages seq $((OSEQ + 1))..$MAX_SEQ ---"
  sqlite3 -separator "$(printf '\t')" "$DB" \
    "SELECT seq, type, data FROM session_message WHERE session_id='$(sqlq "$SID")' AND seq > $OSEQ ORDER BY seq;"
  exit 0
fi

# Claude Code: the transcript path comes from the state the Claude hooks wrote.
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
printf '{"harness":"claude","length":%s}' "$CURRENT_TOTAL" > "$PENDING_FILE"
tail -n "+$((CLEN + 1))" "$CPATH"
