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
# Usage: save-read-unsaved.sh [--digest|--raw] <STORY-ID>
# Prints the unsaved extract to stdout. `--digest` (what the save skill uses)
# prints a readable line per message — channel + text, tool-calls/reasoning
# stripped; `--raw` (the default) prints the harness's raw content.

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

# Resolve through symlinks (OpenCode installs skills as symlinks) so the shared
# harness detector, list-models.sh, is found from this script's own location.
HERE="$(cd -P "$(dirname "$0")" && pwd -P)"

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
have_jq() { command -v jq >/dev/null 2>&1; }
sqlq() { printf '%s' "${1//\'/\'\'}"; }

# A readable line per message — channel + text, with tool-call payloads and
# reasoning stripped. This is what the save step actually reviews; emitting it
# instead of raw JSON keeps a huge transcript dump out of the orchestrator's
# context (a measured main-thread cost driver). Best-effort: if jq can't parse
# the line, nothing is printed for it.
digest_text() { # stdin: one JSON message (either harness's shape)
  jq -r '
    def textof:
      if (.text? | type) == "string" and .text != "" then .text
      else ( (.message.content? // .content?) ) as $c
        | if ($c | type) == "array"
            then [ $c[]? | select(.type? == "text") | .text? // empty ] | join("\n")
          elif ($c | type) == "string" then $c
          else "" end
      end;
    (.message.role? // .type? // "?") as $r
    | (textof) as $t
    | select($t != "")
    | "[\($r)] \($t)"' 2>/dev/null
}

# The state dir holds absolute paths and session ids — machine state that must
# never reach git, whatever the project's choice for .workflow-dev/ itself.
ensure_gitignored() {
  local pattern=".workflow-dev/context/.compaction-state/"
  local probe=".workflow-dev/context/.compaction-state/.probe"
  # Already covered by an ancestor pattern (e.g. `.workflow-dev/`)? Then this
  # line adds nothing and would only dirty a tracked .gitignore on every save.
  if git check-ignore -q "$probe" 2>/dev/null; then return 0; fi
  [[ -f .gitignore ]] || touch .gitignore
  grep -qxF "$pattern" .gitignore || printf '%s\n' "$pattern" >> .gitignore
}

# Which harness is running this? The signal check lives in list-models.sh
# (`--print-harness`) — one definition, shared with the tiering reminder. Here
# we keep only the fallback list-models.sh doesn't need: when no harness signal
# is present (some contexts don't propagate it), prefer whichever source the
# state actually records.
detect_harness() {
  local h
  h="$("$HERE/list-models.sh" --print-harness 2>/dev/null)" || h=""
  [[ -n "$h" ]] && { echo "$h"; return; }
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
  if [[ "$DIGEST" == "1" ]] && have_jq; then
    while IFS=$'\t' read -r _seq _type _data; do
      printf '%s' "$_data" | digest_text
    done < <(sqlite3 -separator "$(printf '\t')" "$DB" \
      "SELECT seq, type, data FROM session_message WHERE session_id='$(sqlq "$SID")' AND seq > $OSEQ ORDER BY seq;")
  else
    sqlite3 -separator "$(printf '\t')" "$DB" \
      "SELECT seq, type, data FROM session_message WHERE session_id='$(sqlq "$SID")' AND seq > $OSEQ ORDER BY seq;"
  fi
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
if [[ "$DIGEST" == "1" ]] && have_jq; then
  tail -n "+$((CLEN + 1))" "$CPATH" | digest_text
else
  tail -n "+$((CLEN + 1))" "$CPATH"
fi
