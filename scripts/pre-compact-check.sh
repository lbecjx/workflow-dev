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
# later. This hook's only job is to keep the story's compaction-state JSON
# current and, when there's content since the last save, flip its
# `pendingSave` flag so post-compaction-save-check.sh (registered on
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

# Two modes:
#   pre-compact-check.sh
#       Claude Code `PreCompact` — arms the state from the hook's own
#       `transcript_path`, a field only a hook receives.
#   pre-compact-check.sh --arm
#       Arms the same state with no transcript at all, for a harness that has no
#       PreCompact event to fire from. Delivering anything is not this script's
#       job in either mode — see the header.
MODE="hook"
case "${1:-}" in
  --arm) MODE="arm" ;;
esac

# Tolerant to how the Implementation Status section is actually worded — the
# template says "### Implementation Status: In Progress" on one line, but a
# real /workflow-dev:init run paraphrased it as a "## Implementation Status"
# heading with the value on its own "**Status:** In Progress" line below.
# Rather than trust the model to reproduce the template byte-for-byte every
# time, scan the whole section (heading to next heading) for "In Progress".
is_in_progress() {
  awk '
    /^#+[[:space:]].*[Ii]mplementation Status/ {
      in_section=1
      if ($0 ~ /In Progress/) { found=1; exit }
      next
    }
    in_section && /^#+[[:space:]]/ { exit }
    in_section && /In Progress/ { found=1; exit }
    END { exit !found }
  ' "$1"
}

STATE_DIR="$CONTEXT_DIR/.compaction-state"

# The state JSON's transcriptPath is a local absolute filesystem path —
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

# --- --arm: the harness has no PreCompact to fire from ----------------------
# Deliberately the most conservative thing that can work, because the file it
# touches is shared: the OpenCode save flow keeps `opencodeSession` and
# `opencodeSeq` in this very JSON, and this script does not otherwise know those
# fields exist. So it flips `pendingSave` **in place** and reads nothing else —
# anything it does not parse cannot be lost by writing it back.
#
# It also never *creates* a state file. Arming a story that has no state would
# mean inventing the session fields the save flow depends on, and guessing at
# those is worse than not reminding: the honest gap is narrower than the bug.
# A story whose state file does not exist yet gets no compaction reminder on
# OpenCode — recorded as such rather than papered over.
#
# ⚠️ One deliberate divergence from the hook path above: this arms on the
# compaction event itself and never compares "has anything been written since
# the last save?" — the check the hook path makes from `transcript_path`, a
# field OpenCode does not hand a plugin. The reasoning is that the event is
# already the signal (a compaction is where unsaved conversation goes missing),
# so arming there is not a guess about content, it is the event's own meaning.
# The cost is a "run /workflow-dev:save" prompt for a story with nothing
# unsaved. Confirmed as a real divergence by the story's adversarial verify;
# left in place knowingly, and flagged for the live run — if the compaction
# events turn out to fire, this is the first thing to re-examine.
if [[ "$MODE" == "arm" ]]; then
  while IFS= read -r STORY_FILE; do
    is_in_progress "$STORY_FILE" || continue
    STORY_NAME=$(basename "$STORY_FILE" .md)
    STATE_FILE="$STATE_DIR/${STORY_NAME}.json"
    [[ -f "$STATE_FILE" ]] || continue
    # Same shape the substitution below rewrites. A bare `grep -q '"pendingSave"'`
    # would accept a key carrying something the regex cannot match, and then the
    # `sed` would no-op while this still exited 0 — a guard and a rewrite
    # disagreeing about what they are guarding.
    grep -qE '"pendingSave"[[:space:]]*:[[:space:]]*(true|false)' "$STATE_FILE" || continue
    mkdir -p "$STATE_DIR"
    ensure_gitignored
    # mktemp in the same directory, not a fixed "$STATE_FILE.tmp": a predictable
    # name written with `>` follows a symlink someone else could have planted
    # there, and two concurrent runs would race on the same path.
    TMP_STATE=$(mktemp "$STATE_DIR/.pendingSave.XXXXXX") || continue
    if sed -E 's/"pendingSave"[[:space:]]*:[[:space:]]*(true|false)/"pendingSave":true/' \
        "$STATE_FILE" > "$TMP_STATE"; then
      mv "$TMP_STATE" "$STATE_FILE"
    else
      rm -f "$TMP_STATE"
    fi
  done < <(find "$CONTEXT_DIR" -maxdepth 1 -name "*.md" ! -name "REPO.md")
  exit 0
fi

INPUT=$(cat)
TRANSCRIPT_PATH=$(printf '%s' "$INPUT" | grep -o '"transcript_path"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4)

# Check every story file, not just one — a project can have several
# (done, won't-do, in-progress) and only the in-progress ones matter here.
while IFS= read -r STORY_FILE; do
  # Our own Implementation Status, not the section 1.1 Story `Status` (which
  # just mirrors the source ticket and is a separate, independent clock).
  if is_in_progress "$STORY_FILE"; then
    if [[ -n "$TRANSCRIPT_PATH" && -f "$TRANSCRIPT_PATH" ]]; then
      mkdir -p "$STATE_DIR"
      ensure_gitignored
      STORY_NAME=$(basename "$STORY_FILE" .md)
      STATE_FILE="$STATE_DIR/${STORY_NAME}.json"

      EXISTING_PATH=""
      if [[ -f "$STATE_FILE" ]]; then
        EXISTING_JSON=$(cat "$STATE_FILE")
        EXISTING_PATH=$(json_get_string "$EXISTING_JSON" "transcriptPath")
      fi

      if [[ "$EXISTING_PATH" == "$TRANSCRIPT_PATH" ]]; then
        # Same file this story is already tracking — only worth a reminder
        # if there's actually new content past what was last saved.
        EXISTING_LENGTH=$(json_get_number "$EXISTING_JSON" "length")
        [[ -n "$EXISTING_LENGTH" ]] || EXISTING_LENGTH=0
        CURRENT_TOTAL=$(wc -l < "$TRANSCRIPT_PATH" | tr -d '[:space:]')
        if [[ "$CURRENT_TOTAL" -le "$EXISTING_LENGTH" ]]; then
          printf '{"terminalSequence":"\\u0007"}'
          exit 0
        fi
        EXISTING_DATETIME=$(json_get_string "$EXISTING_JSON" "dateTime")
        DATETIME_JSON="null"
        [[ -n "$EXISTING_DATETIME" ]] && DATETIME_JSON="\"$EXISTING_DATETIME\""
        printf '{"transcriptPath":"%s","length":%s,"dateTime":%s,"pendingSave":true}' \
          "$TRANSCRIPT_PATH" "$EXISTING_LENGTH" "$DATETIME_JSON" > "$STATE_FILE"
      else
        # No state yet, or it belongs to a different transcript file (a new
        # session) — (re)start tracking from zero for this file, with
        # content already pending by definition (anything in a freshly
        # tracked transcript is, by construction, not yet saved). A prior
        # save against the OLD transcript, if any, is untouched: the old
        # state file simply gets overwritten, but nothing on disk related
        # to it is destroyed — it's just no longer what this story tracks.
        printf '{"transcriptPath":"%s","length":0,"dateTime":null,"pendingSave":true}' "$TRANSCRIPT_PATH" > "$STATE_FILE"
      fi
    fi
    # terminalSequence is the one field documented as "supported on all
    # events" — it can't carry the reason text, just ring the terminal bell
    # as a best-effort signal, emitted here as the JSON escape for the BEL
    # control character rather than a raw byte, which would make the JSON
    # output invalid.
    printf '{"terminalSequence":"\\u0007"}'
    exit 0
  fi
done < <(find "$CONTEXT_DIR" -maxdepth 1 -name "*.md" ! -name "REPO.md")

exit 0
