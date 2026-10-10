#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Sourced, never run: the one owner of "which init'd stories exist and which
# branch names which story". session-start-check.sh (the greeting) and
# coauthor-decision.sh (the commit/PR attribution decision) both read stories
# through these functions, so the two cannot disagree about what "In Progress"
# or "the branch carries the code" means. Each caller keeps its own selection
# policy on top: the greeting may guess from a title, the attribution decision
# may not. Defines functions only — sourcing it has no side effects.

# Read the Implementation Status *property*, deterministically — never scan the
# section body for the phrase. Every file init writes carries a paragraph under
# the heading that itself contains "In Progress" ("Set to **In Progress** at
# creation, always — …"), so a body scan reports a finished story as active: a
# Done story listed as resumable, which is the greeting being wrong whenever
# more than one story was ever init'd (WD-0032). The property has two shapes,
# both real: the value on the heading line ("### Implementation Status: In
# Progress"), and — when the heading is bare — the value on the immediately-
# following non-empty line as a status assignment ("**Status:** In Progress").
# Only that heading line, or that one following "Status:" line, is read. Lines
# inside a fenced code block are not the property at all: this very bug is
# documented by quoting the heading in a fence, so a context file whose
# description carries that quote would otherwise have the example read as its
# status — the same false positive, one layer up. Fences are matched by type and
# length (a ``` fence is closed only by ```, never by ~~~), so a fenced example
# cannot be shut early by content that merely looks like a delimiter; an
# unclosed fence runs to EOF, as CommonMark says, and then the file has no
# readable status — the conservative answer, not a wrong one. Any other line
# (the template paragraph, prose) is not a status value. Tolerant to how init
# paraphrased the heading, intolerant to the body around it.
#
# AWK_SKIP_FENCES is that fence rule as an awk prelude, shared by every awk
# program here that reads a story file (is_in_progress, coauthor_decision_in):
# prepend it, and every line inside a fence is skipped before the program's own
# rules see it. The run length comes from match()/RLENGTH, linear in the line,
# rather than a substr() walk, which is quadratic on a long run of backticks.
AWK_SKIP_FENCES='
    /^[[:space:]]*(```|~~~)/ {
      delim = $0
      sub(/^[[:space:]]*/, "", delim)
      ch = substr(delim, 1, 1)
      if (ch == "`") match(delim, /^`+/); else match(delim, /^~+/)
      len = RLENGTH
      if (!fence) { fence = ch; flen = len; next }
      if (ch == fence && len >= flen) { fence = ""; next }
      next
    }
    fence { next }
'
is_in_progress() {
  awk "$AWK_SKIP_FENCES"'
    /^#+[[:space:]].*[Ii]mplementation Status/ {
      line = $0
      sub(/^[^:]*:[[:space:]]*/, "", line)
      # An inline value only counts when there is one; a bare heading written
      # with a trailing colon ("## Implementation Status:") has its value on the
      # next line, and reading the empty string as the value would drop a
      # genuinely In Progress story.
      if (line != $0 && line != "") {
        print (line ~ /In Progress/) ? "yes" : "no"
        exit
      }
      want = 1
      next
    }
    want && /^[[:space:]]*$/ { next }
    want {
      line = $0
      sub(/^[[:space:]]*[*]*/, "", line)
      rest = line
      sub(/^[[:space:]]*[Ss]tatus[*]*:[[:space:]]*[*]*/, "", line)
      if (line == rest) { print "no"; exit }
      print (line ~ /In Progress/) ? "yes" : "no"
      exit
    }
  ' "$1" | grep -q "^yes$"
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

# Every story file under $1 (default .workflow-dev/context) still In Progress on
# our own clock, one path per line, sorted. Done and Won't Do are closed on our
# side, and the section 1.1 Story `Status` only mirrors the source ticket — a
# different clock, not read here.
story_candidates() {
  local dir="${1:-.workflow-dev/context}" f
  while IFS= read -r f; do
    is_in_progress "$f" && printf '%s\n' "$f"
  done < <(find "$dir" -maxdepth 1 -name "*.md" ! -name "REPO.md" | sort)
}
