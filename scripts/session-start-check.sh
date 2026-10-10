#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
# SessionStart hook — suggests the right next workflow-dev skill based on the
# active story's real state, so returning to a project after time away
# doesn't require remembering where things were left off.
#
# Only acts on a genuinely new session (source == "startup") — not on
# resume/clear/compact/fork, which would repeat this mid-conversation (e.g.
# right after PreCompact already showed its own reminder). The field is
# "source", not "session_start_reason" — the previous name never matched
# Claude Code's actual SessionStart input, so this whole hook silently
# no-opped on every real session since it was written; manual tests missed
# this because they fed the script the wrong field name themselves.
#
set -u

INPUT=$(cat)

REASON=$(printf '%s' "$INPUT" | grep -o '"source"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4)
[[ "$REASON" == "startup" ]] || exit 0

CONTEXT_DIR=".workflow-dev/context"
[[ -d "$CONTEXT_DIR" ]] || exit 0

# Story candidates, is_in_progress and has_code have one owner, shared with
# the commit/PR attribution decision.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=active-story.sh
source "$HERE/active-story.sh"

# $1 = the reminder text, wrapped in the JSON Claude Code's SessionStart reads.
# The text may span lines (the candidate table below does); JSON cannot carry a
# raw newline, so each one is escaped to `\n`. Callers keep `"` and `\` out of
# the text, so nothing else needs escaping.
suggest() {
  printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}' \
    "$(printf '%s' "$1" | awk 'NR > 1 { printf "\\n" } { printf "%s", $0 }')"
}

# --- Which story is the live one? ---------------------------------------------
# Every `init`'d story reads "In Progress" until it is closed (the template
# writes it at creation), so "In Progress" means "was init'd", not "is being
# worked on". Picking the first one by filename order — what this hook used to
# do — named a finished story, or one nobody touched, as the one to resume.
# The decision now goes through the branch, strongest signal first:
#   1. the branch name carries a story's code (wd-0021-… → WD-0021): that story;
#   2. else the branch name shares at least two words with exactly one story's
#      title (the first line of its context file), more than any other: that one;
#   3. else, exactly one init'd story: it is the active one (as before);
#   4. else nothing can be inferred: list every init'd story in a table and let
#      the person say which, rather than guess.
# Only `.workflow-dev/` and git are read — never another plugin's data.

# A story's title: its context file's first line, minus "# " and the code.
story_title() {
  head -1 "$1" | sed -E 's/^#+[[:space:]]*//; s/^[A-Za-z]+-[0-9]+:?[[:space:]]*//' | tr -d '"\\' | tr '|' '/'
}

# Lowercase words of 3+ letters, one per line, sorted, minus names that say
# nothing about a story (branch prefixes, trunk names, filler).
words() {
  printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -cs 'a-z0-9' '\n' \
    | awk 'length($0) >= 3 && $0 !~ /^(feat|fix|chore|wip|main|master|head|dev|develop|the|and|for|with)$/' | sort -u
}

# The reminder for a story that is the active one — the three wordings this
# hook always had, unchanged.
remind_for() {
  local STORY_FILE="$1"
  if ! grep -qE "^## [0-9]+\. Plan" "$STORY_FILE"; then
    suggest "Active workflow-dev story with no Plan yet ($STORY_FILE). Suggest /workflow-dev:resume, then /workflow-dev:plan."
    exit 0
  fi

  # Scoped to the Plan Progress table specifically — the top-level Status field
  # always contains the literal words "In Progress" too, so grepping the whole
  # file here would never reach the "all Done" branch below.
  PLAN_PROGRESS=$(awk '/^### Plan Progress/{flag=1; next} /^## /{flag=0} flag' "$STORY_FILE")

  if printf '%s' "$PLAN_PROGRESS" | grep -q "Not Started\|In Progress"; then
    suggest "Active workflow-dev story with unfinished task groups ($STORY_FILE). Suggest /workflow-dev:resume to continue."
  else
    suggest "This workflow-dev story ($STORY_FILE) shows every task group as Done (already validated). Check for uncommitted changes — if any, review and commit; if not, it may be ready to close out."
  fi
  exit 0
}

CANDIDATES=()
while IFS= read -r STORY_FILE; do
  CANDIDATES+=("$STORY_FILE")
done < <(story_candidates "$CONTEXT_DIR")

[[ ${#CANDIDATES[@]} -gt 0 ]] || exit 0

BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null | tr -d '"\\')

if [[ -n "$BRANCH" ]]; then
  # 1. The branch names a story's code. Two codes in one branch (a merge
  # branch) is not an answer — falling through to the table beats letting
  # filename order pick between them.
  MATCHED=()
  for STORY_FILE in "${CANDIDATES[@]}"; do
    has_code "$BRANCH" "$(basename "$STORY_FILE" .md)" && MATCHED+=("$STORY_FILE")
  done
  if [[ ${#MATCHED[@]} -eq 1 ]]; then
    remind_for "${MATCHED[0]}"
  fi
  # 2. The branch name is clearly closest to one story's title.
  BRANCH_WORDS=$(words "$BRANCH")
  BEST=0; SECOND=0; BEST_FILE=""
  for STORY_FILE in "${CANDIDATES[@]}"; do
    SHARED=$(comm -12 <(printf '%s\n' "$BRANCH_WORDS") <(words "$(story_title "$STORY_FILE")") | grep -c .)
    if (( SHARED > BEST )); then
      SECOND=$BEST; BEST=$SHARED; BEST_FILE="$STORY_FILE"
    elif (( SHARED > SECOND )); then
      SECOND=$SHARED
    fi
  done
  if [[ ${#MATCHED[@]} -eq 0 ]] && (( BEST >= 2 && BEST > SECOND )); then
    remind_for "$BEST_FILE"
  fi
fi

# 3. One init'd story and nothing contradicting it: it is the active one.
if [[ ${#CANDIDATES[@]} -eq 1 ]]; then
  remind_for "${CANDIDATES[0]}"
fi

# 4. Several, and the branch does not say which: list them all.
TABLE="| Story | Title | Branch |
|---|---|---|"
for STORY_FILE in "${CANDIDATES[@]}"; do
  CODE=$(basename "$STORY_FILE" .md)
  STORY_BRANCH=""
  while IFS= read -r REF; do
    if has_code "$REF" "$CODE"; then STORY_BRANCH=$(printf '%s' "$REF" | tr -d '"\\'); break; fi
  done < <(git for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null)
  TABLE="$TABLE
| $CODE | $(story_title "$STORY_FILE") | ${STORY_BRANCH:--} |"
done
suggest "Could not tell which workflow-dev story is active (branch: ${BRANCH:-none}). Stories started with init, none of them matching the branch:
$TABLE
Suggest /workflow-dev:resume to pick one."
exit 0
