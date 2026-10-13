#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
# PreCompact hook — a compaction summary can lose decisions/discoveries that
# only ever lived in the conversation, never in a file. This hook does NOT
# rely on telling anyone about it: per Claude Code's own docs, PreCompact
# discards systemMessage and additionalContext entirely (they go to the
# debug log only, never to Claude or the human) — no JSON field can carry
# text out of this event.
#
# Claude Code's transcript is append-only within a session (verified
# empirically: line-by-line and byte hashes of an actively-growing
# transcript stay identical while the file grows) and is never deleted —
# session .jsonl files sit under ~/.claude/projects/... indefinitely. That
# means there is nothing to back up: the original is always there to read
# later. This hook's only job is to keep the compaction-state JSON of each
# story this session worked current and, when there's content since the last
# save, flip its `pendingSave` flag so post-compaction-save-check.sh (registered on
# UserPromptSubmit and PostToolUse, which DO reliably get additionalContext
# to Claude) raises the reminder at the next opportunity. The actual
# extraction of what's unsaved happens later, live, in save-read-unsaved.sh
# — reading directly from the transcript path this state records, never a
# copy of it.
#
# Deliberately does NOT filter on git status: a clean working tree doesn't
# mean nothing worth saving happened — research findings and decisions can
# live purely in the conversation, with zero files touched.

CONTEXT_DIR=".workflow-dev/context"
[[ -d "$CONTEXT_DIR" ]] || exit 0

# Which stories this session worked, and whether each is still open, come from
# one shared owner (session-story.sh), so this hook and the reminder agree.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=session-story.sh
source "$HERE/session-story.sh"

STATE_DIR="$CONTEXT_DIR/.compaction-state"
# Where each story's save point for this session lives (one per transcript).
# shellcheck source=compaction-state.sh
source "$HERE/compaction-state.sh"

# The state's shape is the one save-mark-saved.sh writes —
# {"claudePath":…,"claudeLength":N,"dateTime":…,"pendingSave":…} — and the
# older `transcriptPath`/`length` names are read as the same two fields, so the
# hooks and the save never disagree about where the last save stopped.
#
# The state JSON's transcript path is a local absolute filesystem path —
# it encodes the OS username and directory structure. There's no way
# around storing it (a plain Bash tool call has no way to learn the
# session's transcript path on its own; only hooks receive it, verified
# against Claude Code's own docs and env-var reference), so instead this
# directory is never allowed to reach git, regardless of whether the
# project tracks .workflow-dev/ itself.
ensure_gitignored() {
  local pattern="$CONTEXT_DIR/.compaction-state/"
  local probe="$CONTEXT_DIR/.compaction-state/.probe"
  # Already covered by an ancestor pattern (e.g. `.workflow-dev/`)? Adding this
  # line adds nothing and would only dirty a tracked .gitignore on every run.
  if git check-ignore -q "$probe" 2>/dev/null; then return 0; fi
  [[ -f .gitignore ]] || touch .gitignore
  grep -qxF "$pattern" .gitignore || printf '%s\n' "$pattern" >> .gitignore
}

json_get_string() {
  # $1: json text, $2: field name
  printf '%s' "$1" | grep -o "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 | sed -E 's/.*: *"(.*)"/\1/'
}

json_get_number() {
  # $1: json text, $2: field name
  printf '%s' "$1" | grep -o "\"$2\"[[:space:]]*:[[:space:]]*[0-9]*" | head -1 | grep -o '[0-9]*$'
}

INPUT=$(cat)
TRANSCRIPT_PATH=$(printf '%s' "$INPUT" | grep -o '"transcript_path"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4)

[[ -n "$TRANSCRIPT_PATH" && -f "$TRANSCRIPT_PATH" ]] || exit 0

# Only the stories this session worked, each one marked: a compaction can drop
# what was said about any of them. Every other context file is left alone, an
# open story of another session included. Our own Implementation Status, not
# the section 1.1 Story `Status` (which mirrors the source ticket).
ARMED=0
# Unique per compaction: a save that read this save point before it was armed
# again must see that it changed (save-mark-saved.sh keeps the flag then).
ARMED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)-$$"
while IFS= read -r STORY_NAME; do
  mkdir -p "$STATE_DIR"
  ensure_gitignored
  adopt_legacy "$STORY_NAME" "$TRANSCRIPT_PATH"
  STATE_FILE="$(state_path "$STORY_NAME" "$TRANSCRIPT_PATH")"
  state_writable "$STATE_FILE" || continue
  mkdir -p "$(dirname "$STATE_FILE")"

  EXISTING_PATH=""
  EXISTING_JSON=""
  if [[ -f "$STATE_FILE" ]]; then
    EXISTING_JSON=$(cat "$STATE_FILE")
    EXISTING_PATH=$(json_get_string "$EXISTING_JSON" "claudePath")
    [[ -n "$EXISTING_PATH" ]] || EXISTING_PATH=$(json_get_string "$EXISTING_JSON" "transcriptPath")
  fi

  if [[ "$EXISTING_PATH" == "$TRANSCRIPT_PATH" ]]; then
    # Same file this story is already tracking — only worth a reminder
    # if there's actually new content past what was last saved.
    EXISTING_LENGTH=$(json_get_number "$EXISTING_JSON" "claudeLength")
    [[ -n "$EXISTING_LENGTH" ]] || EXISTING_LENGTH=$(json_get_number "$EXISTING_JSON" "length")
    [[ -n "$EXISTING_LENGTH" ]] || EXISTING_LENGTH=0
    CURRENT_TOTAL=$(wc -l < "$TRANSCRIPT_PATH" | tr -d '[:space:]')
    [[ "$CURRENT_TOTAL" -gt "$EXISTING_LENGTH" ]] || continue
    EXISTING_DATETIME=$(json_get_string "$EXISTING_JSON" "dateTime")
    DATETIME_JSON="null"
    [[ -n "$EXISTING_DATETIME" ]] && DATETIME_JSON="\"$EXISTING_DATETIME\""
    printf '{"claudePath":"%s","claudeLength":%s,"dateTime":%s,"pendingSave":true,"armedAt":"%s"}' \
      "$TRANSCRIPT_PATH" "$EXISTING_LENGTH" "$DATETIME_JSON" "$ARMED_AT" > "$STATE_FILE"
  else
    # No save point yet for this session — start tracking this transcript
    # from zero, with content already pending by definition (anything in a
    # freshly tracked transcript is, by construction, not yet saved). Other
    # sessions' save points for the story are separate files, left untouched.
    printf '{"claudePath":"%s","claudeLength":0,"dateTime":null,"pendingSave":true,"armedAt":"%s"}' "$TRANSCRIPT_PATH" "$ARMED_AT" > "$STATE_FILE"
  fi
  ARMED=1
done < <(session_stories "$TRANSCRIPT_PATH" "$CONTEXT_DIR")

# terminalSequence is the one field documented as "supported on all
# events" — it can't carry the reason text, just ring the terminal bell
# as a best-effort signal, emitted here as the JSON escape for the BEL
# control character rather than a raw byte, which would make the JSON
# output invalid. Once per compaction, however many stories were marked.
[[ "$ARMED" == 1 ]] && printf '{"terminalSequence":"\\u0007"}'

exit 0
