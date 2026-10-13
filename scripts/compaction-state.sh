#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Sourced, never run: where a story's save points live, and the one place that
# knows it. The caller sets STATE_DIR (.workflow-dev/context/.compaction-state).
#
# One save point per story and session transcript:
# $STATE_DIR/<STORY>/<key>.json, where <key> is a hash of the transcript path.
# A story used to have a single $STATE_DIR/<STORY>.json, so two sessions on the
# same story shared it: the later compaction replaced the earlier session's
# position, and what that session never saved stopped being tracked anywhere
# (WD-0081). Unsaved conversation is never closed: each session keeps its own
# position until a save of the story reads past it, from that session or any
# later one. A single-file state written before this layout is still read and
# saved as one more save point; a compaction in its own transcript moves it.
#
# A save reads (save-read-unsaved.sh) and later, once the human confirmed,
# marks (save-mark-saved.sh). Each read gets its own id, and leaves one pending
# file per save point it read, named after that id: <state>.pending-<id>. The
# mark advances only what its own read covered, so a second save of the same
# story, from another session, running between the two, can neither be marked
# for nor eat the first one's read.
#
# Files that are symlinks are never read or written: these files hold absolute
# paths and are rewritten in place, and a symlink planted in a cloned repo would
# turn that rewrite into a write somewhere else.

# A story id as the context files name it. Anything else (`..`, a slash) never
# reaches a path.
valid_story_id() { # valid_story_id <id>
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "$1" != *..* ]]
}

# The file name a transcript's save point gets. Only a hash of the path: the
# path itself never becomes a file name.
state_key() { # state_key <transcript>
  printf '%s' "$1" | shasum | cut -c1-16
}

state_path() { # state_path <story> <transcript>
  printf '%s/%s/%s.json' "$STATE_DIR" "$1" "$(state_key "$2")"
}

# The transcript a save point tracks: `claudePath`, or the older `transcriptPath`.
state_transcript() { # state_transcript <state file>
  local json path
  json="$(cat "$1" 2>/dev/null)"
  path="$(printf '%s' "$json" | grep -o '"claudePath"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*: *"(.*)"/\1/')"
  [[ -n "$path" ]] || path="$(printf '%s' "$json" | grep -o '"transcriptPath"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*: *"(.*)"/\1/')"
  printf '%s' "$path"
}

# Whether a save may print this transcript: a .jsonl file inside Claude Code's
# own projects folder (CLAUDE_CONFIG_DIR, or ~/.claude), resolved on disk so a
# symlinked folder cannot point out of it, and a session that ran in this
# project. A state file is repo content: a cloned repo can carry one that names
# any readable file, or another project's conversation, and the save would print
# it as if it were this story's.
#
# The project check reads the `cwd` Claude Code writes on each transcript line,
# and runs from the project folder, as every caller does. Any line counts, not
# only the first: a session that started in the main checkout and moved into a
# worktree records the worktree only from that point on. That `cwd` follows the
# shell, so a session elsewhere that once ran a command in this folder passes
# too; naming it still takes its transcript's file name, a random id no repo
# can know.
trusted_transcript() { # trusted_transcript <path>
  local root dir here
  [[ "$1" == /*.jsonl && "$1" != *..* && -f "$1" && ! -L "$1" ]] || return 1
  root="$(CDPATH='' cd -- "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects" 2>/dev/null && pwd -P)" || return 1
  dir="$(CDPATH='' cd -- "$(dirname -- "$1")" 2>/dev/null && pwd -P)" || return 1
  [[ "$dir/" == "$root/"* ]] || return 1
  here="$(pwd -P)"
  grep -qE -e "\"cwd\"[[:space:]]*:[[:space:]]*\"$(ere_quote "$here")\"" \
    -e "\"cwd\"[[:space:]]*:[[:space:]]*\"$(ere_quote "$PWD")\"" "$1" 2>/dev/null
}

# A literal string as an extended regular expression.
ere_quote() { # ere_quote <text>
  printf '%s' "$1" | sed 's/[][\.*^$+?(){}|/]/\\&/g'
}

# A path from a state file, safe to show: only path characters, at most 200.
# The value is repo content, so shown as is it could carry a sentence aimed at
# the agent that reads the save's output.
shown_path() { # shown_path <path>
  printf '%s' "$1" | LC_ALL=C tr -cd 'A-Za-z0-9._/~+-' | cut -c1-200
}

# Every save point of a story, one path per line. A single-file state of the
# older layout comes first, unless the same transcript already has its own save
# point (then it would only read the same lines twice).
state_files() { # state_files <story>
  local f legacy="$STATE_DIR/$1.json" path
  valid_story_id "$1" || return 0
  [[ -L "$STATE_DIR" ]] && return 0
  if [[ -f "$legacy" && ! -L "$legacy" ]]; then
    path="$(state_transcript "$legacy")"
    if [[ -z "$path" || ! -f "$(state_path "$1" "$path")" ]]; then printf '%s\n' "$legacy"; fi
  fi
  [[ -L "$STATE_DIR/$1" ]] && return 0
  for f in "$STATE_DIR/$1"/*.json; do
    [[ -f "$f" && ! -L "$f" ]] && printf '%s\n' "$f"
  done
  return 0
}

# This transcript's save points, for every story: the single-file states of
# the older layout that track it, and its own file in each story's folder. Cost
# grows with the stories, never with how many sessions ever compacted.
session_state_files() { # session_state_files <transcript>
  local f key
  [[ -L "$STATE_DIR" ]] && return 0
  key="$(state_key "$1")"
  for f in "$STATE_DIR"/*.json; do
    [[ -f "$f" && ! -L "$f" ]] || continue
    grep -qF "\"$1\"" "$f" 2>/dev/null && printf '%s\n' "$f"
  done
  for f in "$STATE_DIR"/*/"$key".json; do
    [[ -f "$f" && ! -L "$f" && ! -L "$(dirname "$f")" ]] && printf '%s\n' "$f"
  done
  return 0
}

# Every save point in the tree, newest first (session-usage.sh's fallback).
all_state_files_newest() {
  ls -1t "$STATE_DIR"/*.json "$STATE_DIR"/*/*.json 2>/dev/null
}

# The story a save point belongs to, from its place in the tree.
state_story() { # state_story <state file>
  local dir
  dir="$(dirname "$1")"
  if [[ "$dir" == "$STATE_DIR" ]]; then basename "$1" .json; else basename "$dir"; fi
}

# Where a read waits for its save to be confirmed: one file per save point and
# read id. The single-file layout kept `.pending-save-<STORY>`, with no id. A
# read the human declined is dropped by save-mark-saved.sh --discard; one left
# behind by a save that never finished is dropped by the next read after a day.
pending_path() { # pending_path <state file> <read id>
  local dir
  dir="$(dirname "$1")"
  if [[ "$dir" == "$STATE_DIR" ]]; then
    printf '%s/.pending-save-%s%s' "$STATE_DIR" "$(basename "$1" .json)" "${2:+-$2}"
  else
    printf '%s.pending%s' "${1%.json}" "${2:+-$2}"
  fi
}

# The pending files of a save point, of every read, one per line.
pending_files() { # pending_files <state file>
  local base f
  base="$(pending_path "$1" "")"
  # Only read ids (save-read-unsaved.sh's <UTC stamp>-<pid>): a bare `-*`
  # would take another story's older pending file whose id starts the same way
  # (.pending-save-PROJ-12-b for PROJ-12).
  for f in "$base" "$base"-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z-[0-9]*; do
    [[ -f "$f" && ! -L "$f" ]] && printf '%s\n' "$f"
  done
  return 0
}

# A single-file state that tracks this very transcript becomes its save point
# in the new layout, position and pending read included, so nothing is read
# twice or skipped. A single-file state of another transcript stays where it
# is: it is that session's unsaved conversation.
adopt_legacy() { # adopt_legacy <story> <transcript>
  local old="$STATE_DIR/$1.json" new f
  valid_story_id "$1" || return 0
  [[ -f "$old" && ! -L "$old" ]] || return 0
  [[ "$(state_transcript "$old")" == "$2" ]] || return 0
  new="$(state_path "$1" "$2")"
  [[ -f "$new" ]] && return 0
  state_writable "$new" || return 0
  mkdir -p "$(dirname "$new")" || return 0
  while IFS= read -r f; do
    mv "$f" "$(pending_path "$new" "")${f#"$(pending_path "$old" "")"}"
  done < <(pending_files "$old")
  mv "$old" "$new"
  return 0
}

# A fingerprint of a save point's content: the mark compares it with the one the
# read saw, to tell whether a compaction re-armed the save point in between.
# Content, not mtime: the shell compares mtimes in whole seconds. Each arm
# writes a fresh `armedAt` (pre-compact-check.sh), so arming an already armed
# save point still changes it.
state_sum() { # state_sum <state file>
  shasum < "$1" 2>/dev/null | cut -c1-16
}

# The safe place for a save point to be written: not through a symlink, neither
# the file nor its story folder nor the state directory.
state_writable() { # state_writable <state file>
  [[ ! -L "$STATE_DIR" && ! -L "$(dirname "$1")" && ! -L "$1" ]]
}
