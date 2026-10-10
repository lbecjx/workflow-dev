#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Sourced, never run: the one owner of the AI/agent attribution rule
# (validate/references/rules.md §12.3) as both scripts that enforce it read it —
# git-message-mark-reviewed.sh (refuses to mark) and pre-commit-message-check.sh
# (denies the commit/PR). Both patterns and the human's co-authorship decision
# live here, so the two scripts cannot drift apart: they used to keep a copy of
# the pattern each, "byte-identical by hand", which only a comment enforced.
#
# The decision is a row in the active story's Decisions table, written by
# summarize-changes or init when the human answers:
#   | 2026-10-10 | Agent co-authorship: yes | Human |
# Only that exact shape means yes. Everything else means no, which keeps the
# deny exactly as it was: no story, two candidate stories, an unreadable file,
# no row, two rows, a row in a fenced example or outside the Decisions section,
# a value other than yes, or a row the agent inferred rather than the human
# decided. A yes the agent could produce on its own would be a bypass.
#
# Defines functions and patterns only — sourcing it has no side effects.

# shellcheck source=active-story.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/active-story.sh"

# Phrases that credit an AI with the work in prose. They are part of the
# attribution pattern below, and are also checked on their own against the two
# lines a yes allows, so a yes never lets one ride inside an allowed line.
AI_CREDIT_PHRASE_PATTERN='(ai-generated)|(ai-assisted)|(written (with|by) (an )?(ai|llm)\b)'

# Attribution in any form: what the deny and the refusal-to-mark look for.
AI_ATTRIBUTION_PATTERN='(co-authored-by:.*(claude|anthropic|openai|chatgpt|copilot|gemini|codex))|(generated (with|by)[^.]*(claude|copilot|chatgpt|anthropic))|🤖|(claude\.ai)|(claude\.com/claude-code)|(anthropic\.com)|'"$AI_CREDIT_PHRASE_PATTERN"

# The only two forms a yes allows, each as a whole line: the commit trailer
# (`Co-Authored-By: <name> <email>`) and the PR line (`🤖 Generated with
# [<tool>](<url>)`). Any name, email and URL the harness supplies, so the plugin
# never names a model — but only plain characters in each: letters, digits,
# spaces, `._-` (and `+@` in the email, `/:` in the URL). No quote, so a shell
# argument cannot be closed and reopened inside an allowed line. Trailing `"` /
# `'` are the quotes closing a `-m "..."` / `--body "..."` argument (two when it
# sits inside `bash -c '...'`), and quotes only. Anything else on the same line
# (a second flag, a sentence) makes it no longer a whole-line match, so it stays
# attribution and is denied — the safe side. Matched case-sensitively: the
# harness writes these exact forms.
AI_COAUTHOR_ALLOWED_LINE_PATTERN='^[[:space:]]*(Co-Authored-By: [A-Za-z0-9][A-Za-z0-9 ._-]* <[A-Za-z0-9._+-]+@[A-Za-z0-9.-]+>|🤖 Generated with \[[A-Za-z0-9][A-Za-z0-9 ._-]*\]\(https?://[A-Za-z0-9./_-]+\))[[:space:]]*["'"'"']*[[:space:]]*$'

# The active story's context file, for this decision only. Stricter than the
# session-start greeting on purpose: no guessing from the title, and a branch
# that names a story decides alone.
# - The branch carries the code of a story file here (any status): that file,
#   when it is the only one named and it is In Progress; else no answer. A
#   follow-up commit on a closed story's branch must not borrow another story's
#   yes.
# - The branch names no story file but still looks like it carries a code
#   (`ABC-123`): a story not init'd here — no answer.
# - Otherwise, the one In Progress story, when there is exactly one.
# No branch at all (a detached HEAD: a rebase stopped mid-way, a checked-out
# SHA) has no answer either — the commit may belong to any story.
# No answer returns non-zero, which the caller reads as no.
coauthor_story_file() {
  local dir=".workflow-dev/context" branch f named=0 hit="" all=0 only=""
  [[ -d "$dir" ]] || return 1
  branch=$(git symbolic-ref --short HEAD 2>/dev/null)
  [[ -n "$branch" ]] || return 1
  while IFS= read -r f; do
    if has_code "$branch" "$(basename "$f" .md)"; then
      named=$((named + 1)); hit="$f"
    fi
  done < <(find "$dir" -maxdepth 1 -name "*.md" ! -name "REPO.md" 2>/dev/null)
  if [[ $named -gt 0 ]]; then
    [[ $named -eq 1 ]] && is_in_progress "$hit" 2>/dev/null && { printf '%s' "$hit"; return 0; }
    return 1
  fi
  printf '%s' "$branch" | grep -qE '(^|[^A-Za-z0-9])[A-Za-z]+-[0-9]+([^0-9]|$)' && return 1
  while IFS= read -r f; do
    all=$((all + 1)); only="$f"
  done < <(story_candidates "$dir" 2>/dev/null)
  [[ $all -eq 1 ]] || return 1
  printf '%s' "$only"
}

# Reads a story file and prints yes only for exactly one well-formed
# `Agent co-authorship: yes` row decided by Human, inside a section headed
# Decisions and outside any fenced block; prints no otherwise. Any line of that
# section that mentions co-authorship at all counts as a decision row, table row
# or not, whatever sits between "co" and "author" (a hyphen, a space, a Unicode
# dash, nothing), so a malformed or reworded second row makes
# the decision ambiguous rather than being skipped. The value is compared
# exactly, letter case included: it is a recorded value, written one way.
coauthor_decision_in() {
  awk "$AWK_SKIP_FENCES"'
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    /^#+[[:space:]]/ {
      head = $0
      sub(/^#+[[:space:]]+/, "", head)
      inside = (trim(head) == "Decisions")
      next
    }
    inside && tolower($0) ~ /co[^a-z]*author/ {
      rows++
      n = split($0, c, "|")
      good = ($0 ~ /^[[:space:]]*\|/ && n == 5 && trim(c[1]) == "" && trim(c[5]) == "")
      if (good) good = (trim(c[2]) ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/)
      if (good) good = (trim(c[3]) == "Agent co-authorship: yes")
      if (good) good = (trim(c[4]) == "Human")
    }
    END { print (rows == 1 && good) ? "yes" : "no" }
  ' "$1" 2>/dev/null || printf 'no\n'
}

# yes or no for the working directory. Never fails: any error is no.
coauthor_decision() {
  local f answer
  f=$(coauthor_story_file) || { printf 'no'; return 0; }
  [[ -f "$f" && -r "$f" ]] || { printf 'no'; return 0; }
  answer=$(coauthor_decision_in "$f")
  [[ "$answer" == "yes" ]] && printf 'yes' || printf 'no'
}

# $1 = text, $2 = the decision (yes|no; anything else is no). Succeeds when the
# text carries attribution the decision does not allow. With yes: any
# attribution outside the allowed lines, or a credit phrase inside one.
# Otherwise: any attribution at all.
has_ai_attribution() {
  local text="$1"
  if [[ "${2:-no}" != "yes" ]]; then
    printf '%s' "$text" | grep -qiE "$AI_ATTRIBUTION_PATTERN"
    return
  fi
  printf '%s\n' "$text" | grep -vE "$AI_COAUTHOR_ALLOWED_LINE_PATTERN" | grep -qiE "$AI_ATTRIBUTION_PATTERN" && return 0
  printf '%s\n' "$text" | grep -E "$AI_COAUTHOR_ALLOWED_LINE_PATTERN" | grep -qiE "$AI_CREDIT_PHRASE_PATTERN"
}

# Succeeds when a command may act on a repository other than the working
# directory, whose story the decision was read from: `git -C`, `--git-dir`,
# `--work-tree`, `core.worktree` / `core.bare`, a GIT_DIR / GIT_WORK_TREE /
# GH_REPO assignment, a `cd` / `pushd` (also as `\cd`), or `gh -R` / `--repo`
# (also glued, `-Rowner/repo`). The message text is not read: a heredoc body
# (an opener `<<WORD` ending its line) and the quoted argument of a message flag
# (`-m`, `--message`, `--body`, `--title`) are dropped first, so a message that
# mentions `cd` or `--repo` does not count. Every other quoted string is kept,
# quotes removed, so `bash -c 'cd ../x && git commit'` or `git "-C" ../x` still
# count. Deliberately coarse otherwise — a false match only means the decision
# falls back to no, the behavior before this rule existed. The awk walks each
# line once through split(), linear in its length.
coauthor_command_elsewhere() {
  printf '%s\n' "$1" | awk '
    function flag(w) { return w ~ /^(-[A-Za-z]*m|--message|--body|--title)=?$/ }
    hd != "" { t = $0; sub(/^\t+/, "", t); if (t == hd) hd = ""; next }
    {
      n = split($0, ch, "")
      out = ""
      for (i = 1; i <= n; i++) {
        c = ch[i]
        if (q != "") {
          if (q == "d" && c == "\\") { if (!drop) out = out ch[i + 1]; i++; continue }
          if ((q == "s" && c == "\047") || (q == "d" && c == "\"")) { q = ""; drop = 0; word = ""; prev = ""; out = out " "; continue }
          if (!drop) out = out c
          continue
        }
        if (c == "\047" || c == "\"") {
          q = (c == "\"") ? "d" : "s"
          drop = (word != "") ? flag(word) : flag(prev)
          continue
        }
        if (c ~ /[[:space:]]/) { if (word != "") prev = word; word = ""; out = out c; continue }
        word = word c
        out = out c
      }
      if (word != "") prev = word
      word = ""
      print out
      if (match($0, /<<-?[[:space:]]*[\047"]?[A-Za-z_]+[\047"]?[[:space:]]*$/)) {
        hd = substr($0, RSTART, RLENGTH)
        sub(/^<<-?[[:space:]]*[\047"]?/, "", hd)
        sub(/[\047"]?[[:space:]]*$/, "", hd)
      }
    }' | grep -qE '(^|[[:space:];&|(\\])(-C|--git-dir|--work-tree|-R|--repo|cd|pushd)([[:space:]=]|$)|(^|[[:space:]])-R[^[:space:]]|GIT_(DIR|WORK_TREE)=|GH_REPO=|core\.(worktree|bare)'
}
