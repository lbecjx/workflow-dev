#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Sourced, never run: which stories a session worked on, and whether a story
# is still open on our own clock. One owner for both questions, so the hooks
# that ask them cannot disagree (WD-0081).
#
# The compaction hooks used to answer them on their own, and got both wrong:
# the PreCompact hook walked every context file in directory order and stopped
# at the first one whose Implementation Status *section* mentioned "In
# Progress" anywhere, which every Done story does through the template
# paragraph under the heading. So a compaction while working WD-0080 marked
# WD-0052, Done for weeks, for a save. Which story to save is the one the
# session actually worked, never a guess from the directory or the branch.

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
is_in_progress() {
  awk '
    /^[[:space:]]*(```|~~~)/ {
      delim = $0
      sub(/^[[:space:]]*/, "", delim)
      ch = substr(delim, 1, 1)
      len = 0
      while (substr(delim, len + 1, 1) == ch) len++
      if (!fence) { fence = ch; flen = len; next }
      if (ch == fence && len >= flen) { fence = ""; next }
      next
    }
    fence { next }
    /^#+[[:space:]].*[Ii]mplementation Status/ {
      line = $0
      sub(/^[^:]*:[[:space:]]*/, "", line)
      # An inline value only counts when there is one; a bare heading written
      # with a trailing colon ("## Implementation Status:") has its value on the
      # next line, and reading the empty string as the value would drop a
      # genuinely In Progress story.
      if (line != $0 && line != "") {
        print (line ~ /^[[:space:]*]*In Progress/) ? "yes" : "no"
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
      print (line ~ /^[[:space:]*]*In Progress/) ? "yes" : "no"
      exit
    }
  ' "$1" | grep -q "^yes$"
}

# Does text $1 carry story code $2 (WD-0021 in wd-0021-foo or feat/WD-0021)?
# Case-insensitive, bounded so WD-21 never matches WD-215. One definition, used
# by session-start-check.sh for the branch and by session_stories for a skill's
# arguments, so they cannot disagree about what "carries the code" means.
has_code() {
  local CODE_RE
  CODE_RE=$(printf '%s' "$2" | sed 's/[][\.*^$+?(){}|/]/\\&/g')
  printf '%s' "$1" | grep -qiE "(^|[^A-Za-z0-9])${CODE_RE}([^0-9]|$)"
}

# The stories transcript $1 worked on, one id per line, sorted: every context
# file in directory $2 (REPO.md aside) that is still In Progress and that the
# session took up — a Write or Edit of that very file by an assistant tool call,
# or a workflow-dev skill that starts or resumes story work (init, init-auto,
# resume, refresh, plan, implement) whose first argument starts with its code
# (`WD-0081`, or a backlog path whose file name starts with it), called by the
# assistant or typed by the human (Claude Code keeps a typed command as a user
# line with <command-name> and <command-args> tags, not as a tool call). A
# story closed during the session (Done, Won't Do) drops out by its status.
#
# What does not count, each found the hard way: tool results (an `ls` lists
# every story without working any); a path quoted inside a file's content or a
# Bash command (a test fixture or a grep for reference names other stories);
# free text in a skill's arguments ("follows up WD-0052" in a commit summary, a
# backlog slug such as wd-0012-follow-up-to-wd-0005);
# a Read, since reading a sibling story for reference is not working it; the
# same file name in another checkout. A skill called with a shorthand
# (`init-auto wd81`) or with no argument (`resume`) is not resolved; the story
# attaches at the first write to its context file, which init and save make.
#
# A written path counts when it is the whole `file_path` value and names a file
# of this very directory once resolved on disk, so a symlinked or unnormalized
# spelling (/tmp → /private/tmp, `context/../context/`) and a path holding a
# JSON-escaped `"` or `\` still match. Claude Code writes "type":"assistant"
# after the content block, so both markers are matched in either order; each
# tool_use block is split onto its own line before it is read, so a Read beside
# a Write on one line is still only a Read. -a because a transcript can hold
# bytes that make grep report "Binary file matches" instead of the line.
#
# The ids come only from the directory listing, and are compared, never
# searched for: nothing read from the transcript becomes a pattern, a command,
# or JSON. A path read from it is only used to `cd` into its directory and
# compare where that lands.
# Does skill argument $1 start with story code $2? Only its file name counts
# for a path, and only its start, so a code named later in a slug does not.
arg_names_code() { # arg_names_code <first argument> <code>
  local CODE_RE
  CODE_RE=$(printf '%s' "$2" | sed 's/[][\.*^$+?(){}|/]/\\&/g')
  printf '%s' "${1##*/}" | grep -qiE "^${CODE_RE}([^0-9]|$)"
}

session_stories() { # session_stories <transcript> <context dir>
  local transcript="$1" dir="$2" here blocks value path written="" args typed file id name arg
  [[ -n "$transcript" && -s "$transcript" && -d "$dir" ]] || return 0
  here="$(CDPATH='' cd -- "$dir" && pwd -P)" || return 0
  blocks="$(LC_ALL=C grep -aF '"type":"tool_use"' "$transcript" 2>/dev/null \
    | LC_ALL=C grep -aF '"type":"assistant"' \
    | LC_ALL=C awk '{ gsub(/\{"type":"tool_use"/, "\n&"); print }' \
    | LC_ALL=C grep -aE '^\{"type":"tool_use".*"name":"(Write|Edit|MultiEdit|Skill)"')"
  typed="$(LC_ALL=C grep -aF '"type":"user"' "$transcript" 2>/dev/null \
    | LC_ALL=C grep -avF '"tool_result"' \
    | LC_ALL=C grep -aE '<command-name>/?workflow-dev:(init|init-auto|resume|refresh|plan|implement)</command-name>' \
    | LC_ALL=C grep -aoE '<command-args>[^<" \\]*' | sed 's/^<command-args>//')"
  [[ -n "$blocks" || -n "$typed" ]] || return 0
  while IFS= read -r value; do
    [[ -n "$value" ]] || continue
    path="${value#\"file_path\":\"}"; path="${path%\"}"
    path="${path//\\\\/$'\001'}"; path="${path//\\\"/\"}"; path="${path//\\\//\/}"; path="${path//$'\001'/\\}"
    [[ "$path" == *.md ]] || continue
    [[ "$(CDPATH='' cd -- "$(dirname -- "$path")" 2>/dev/null && pwd -P)" == "$here" ]] || continue
    written="$written$(basename "$path")"$'\n'
  done < <(printf '%s\n' "$blocks" | LC_ALL=C grep -aE '^\{"type":"tool_use".*"name":"(Write|Edit|MultiEdit)"' \
    | LC_ALL=C grep -aoE '"file_path":"([^"\\]|\\.)*"' | LC_ALL=C sort -u)
  args="$(printf '%s\n' "$blocks" | LC_ALL=C grep -aE '"skill":"workflow-dev:(init|init-auto|resume|refresh|plan|implement)"' \
    | LC_ALL=C grep -aoE '"args":"[^" \\]*' | sed 's/^"args":"//')"
  args="$args"$'\n'"$typed"
  while IFS= read -r file; do
    id="$(basename "$file" .md)"
    is_in_progress "$file" || continue
    while IFS= read -r name; do
      if [[ -n "$name" && "$name" == "$id.md" ]]; then printf '%s\n' "$id"; continue 2; fi
    done <<< "$written"
    while IFS= read -r arg; do
      if [[ -n "$arg" ]] && arg_names_code "$arg" "$id"; then printf '%s\n' "$id"; continue 2; fi
    done <<< "$args"
  done < <(find "$dir" -maxdepth 1 -type f -name '*.md' ! -name 'REPO.md' | LC_ALL=C sort)
}
