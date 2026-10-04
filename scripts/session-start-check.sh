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
# Two modes, one text:
#   session-start-check.sh
#       Claude Code `SessionStart` — emits the JSON envelope below.
#   session-start-check.sh --message [payload]
#       Prints the same reminder as plain text and nothing otherwise. This is
#       what OpenCode's plugin calls: that harness has no SessionStart event
#       (measured 2026-09-29 — `ctx.event.subscribe("session.created")`
#       registers but never fires), so the plugin drives this script from its
#       own per-model-call hook, and takes the payload as an argument because
#       there is no pipe to feed it through. The text stays here, in one copy,
#       so the two harnesses cannot drift apart.
#
# Note for that OpenCode caller: the `source == "startup"` gate below is this
# script's, not the harness's — the caller must pass `{"source":"startup"}`.
# OpenCode has no equivalent of Claude Code's resume/clear/compact/fork, so
# whoever calls this owns the "only once per session" half.

set -u

MODE="hook"
PAYLOAD_ARG=""
case "${1:-}" in
  --message) MODE="message"; PAYLOAD_ARG="${2:-}" ;;
esac

if [[ "$MODE" == "message" && -n "$PAYLOAD_ARG" ]]; then
  INPUT="$PAYLOAD_ARG"
else
  INPUT=$(cat)
fi

REASON=$(printf '%s' "$INPUT" | grep -o '"source"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4)
[[ "$REASON" == "startup" ]] || exit 0

CONTEXT_DIR=".workflow-dev/context"
[[ -d "$CONTEXT_DIR" ]] || exit 0

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

# $1 = the reminder text. One copy, two envelopes: `--message` prints it plain
# for OpenCode's plugin, everything else wraps it in the JSON Claude Code's
# SessionStart reads. Never build the text twice — a second copy is the bug
# this split exists to prevent. The text may span lines (the candidate table
# below does); JSON cannot carry a raw newline, so hook mode escapes each one to
# `\n`. Callers keep `"` and `\` out of the text, so nothing else needs escaping.
suggest() {
  if [[ "$MODE" == "message" ]]; then
    printf '%s' "$1"
    exit 0
  fi
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

# Does branch $1 carry story code $2 (WD-0021 in wd-0021-foo or feat/WD-0021)?
# Case-insensitive, bounded so WD-21 never matches WD-215. One definition, used
# for the active story and for the table's Branch column, so the two cannot
# disagree about what "carries the code" means.
has_code() {
  local CODE_RE
  CODE_RE=$(printf '%s' "$2" | sed 's/[][\.*^$+?(){}|/]/\\&/g')
  printf '%s' "$1" | grep -qiE "(^|[^A-Za-z0-9])${CODE_RE}([^0-9]|$)"
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

# Candidates: every story file still In Progress on our own clock. Done and
# Won't Do are closed on our side, and the section 1.1 Story `Status` only
# mirrors the source ticket — a different clock, not read here.
CANDIDATES=()
while IFS= read -r STORY_FILE; do
  is_in_progress "$STORY_FILE" && CANDIDATES+=("$STORY_FILE")
done < <(find "$CONTEXT_DIR" -maxdepth 1 -name "*.md" ! -name "REPO.md" | sort)

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
