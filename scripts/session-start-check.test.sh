#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Tests for session-start-check.sh. Its inputs are the hook JSON (on stdin, or
# as the --message argument) and the project's own .workflow-dev/context tree —
# so everything here runs against a throwaway project, never this repo's live
# context.
#
# The assertion that carries the weight is the duality: the text --message
# prints (what OpenCode's plugin forwards) and the JSON `additionalContext`
# (what Claude Code reads) must be the *same* text. One copy is the entire
# point of the split — a second wording is free to drift from the first, which
# is the bug this shape exists to prevent.
#
#   bash scripts/session-start-check.test.sh

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/session-start-check.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok() { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }

# Both modes, run from inside the throwaway project — the script resolves
# .workflow-dev/context relative to the cwd, so cwd is part of the input.
hook() { ( cd "$PROJ" && printf '%s' "$1" | bash "$SCRIPT" ); }
plain() { ( cd "$PROJ" && bash "$SCRIPT" --message "$1" ); }

# The envelope's own field, extracted without assuming jq (the repo's scripts
# don't require it either). The reminder text contains no `"`, so a greedy
# match to the closing `"}}` is unambiguous.
envelope_text() { printf '%s' "$1" | sed -E 's/.*"additionalContext":"(.*)"\}\}$/\1/'; }

PROJ="$TMP/proj"
mkdir -p "$PROJ/.workflow-dev/context"
cat > "$PROJ/.workflow-dev/context/WD-0001.md" <<'MD'
# WD-0001

### Implementation Status: In Progress

### Plan Progress
| # | Task Group | Status |
|---|-----------|--------|
| 1 | thing | Not Started |
MD

# --- 1: the same text in both modes -----------------------------------------
PLAIN_OUT="$(plain '{"source":"startup"}')"
JSON_OUT="$(hook '{"source":"startup"}')"
[[ -n "$PLAIN_OUT" ]] && ok "--message prints the reminder" || no "--message prints the reminder (got nothing)"
case "$PLAIN_OUT" in
  '{'*) no "--message prints plain text, not an envelope (got: $PLAIN_OUT)" ;;
  *) ok "--message prints plain text, not an envelope" ;;
esac
[[ "$(envelope_text "$JSON_OUT")" == "$PLAIN_OUT" ]] \
  && ok "both modes carry the same text (one copy, no drift)" \
  || no "both modes carry the same text (json: $(envelope_text "$JSON_OUT") | msg: $PLAIN_OUT)"
case "$JSON_OUT" in
  *'"hookEventName":"SessionStart"'*) ok "hook mode still names SessionStart" ;;
  *) no "hook mode still names SessionStart (got: $JSON_OUT)" ;;
esac

# --- 2: the startup gate belongs to the script, not the caller --------------
[[ -z "$(plain '{"source":"resume"}')" ]] && ok "--message: source=resume → silent" || no "--message: source=resume → silent"
[[ -z "$(hook '{"source":"resume"}')" ]] && ok "hook mode: source=resume → silent" || no "hook mode: source=resume → silent"
[[ -z "$(plain '{}')" ]] && ok "--message: no source field → silent" || no "--message: no source field → silent"

# --- 3: a story with no Plan yet is a different reminder --------------------
cat > "$PROJ/.workflow-dev/context/WD-0002.md" <<'MD'
# WD-0002

### Implementation Status: In Progress
MD
rm "$PROJ/.workflow-dev/context/WD-0001.md"
NO_PLAN="$(plain '{"source":"startup"}')"
case "$NO_PLAN" in
  *"no Plan yet"*) ok "a story with no Plan gets its own wording" ;;
  *) no "a story with no Plan gets its own wording (got: $NO_PLAN)" ;;
esac

# --- 4: nothing to say → silence in both modes ------------------------------
rm "$PROJ/.workflow-dev/context/WD-0002.md"
[[ -z "$(plain '{"source":"startup"}')" ]] && ok "no context dir → --message silent" || no "no context dir → --message silent"
[[ -z "$(hook '{"source":"startup"}')" ]] && ok "no context dir → hook mode silent" || no "no context dir → hook mode silent"

# --- 5: a closed story is not resumed ---------------------------------------
mkdir -p "$PROJ/.workflow-dev/context"
cat > "$PROJ/.workflow-dev/context/WD-0003.md" <<'MD'
# WD-0003

### Implementation Status: Done
MD
[[ -z "$(plain '{"source":"startup"}')" ]] && ok "Done story → --message silent" || no "Done story → --message silent"

# --- 6: which story is live — the branch decides, never filename order -------
# A fresh project per case: the decision reads the git branch, so each case
# needs its own repo. WD-0017 is deliberately the lower-numbered file, the one
# the old first-match-wins loop would have picked.
fresh_project() {
  rm -rf "$PROJ"
  mkdir -p "$PROJ/.workflow-dev/context"
  ( cd "$PROJ" && git init -q && git checkout -q -b "$1" \
      && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init )
}
story() { # $1=code $2=title $3=extra body
  printf '# %s: %s\n\n### Implementation Status: In Progress\n%s\n' "$1" "$2" "${3:-}" \
    > "$PROJ/.workflow-dev/context/$1.md"
}
# the table spans lines; hook mode escapes them to \n, --message keeps them raw
json_text_plain() { envelope_text "$1" | sed 's/\\n/\
/g'; }

fresh_project wd-0023-commit-hook
story WD-0017 "Quality gate wiring"
story WD-0023 "Commit hook matches mentions" '## 5. Plan
### Plan Progress
| # | Task Group | Status |
|---|---|---|
| 1 | x | Not Started |'
OUT="$(plain '{"source":"startup"}')"
case "$OUT" in
  *"unfinished task groups"*WD-0023*) ok "branch carrying a story code picks that story, not the lower-numbered one" ;;
  *) no "branch carrying a story code picks that story (got: $OUT)" ;;
esac
case "$OUT" in *WD-0017*) no "the other story is not mentioned (got: $OUT)" ;; *) ok "the other story is not mentioned" ;; esac

fresh_project fix/greeting-offers-unstarted
story WD-0017 "Quality gate wiring"
story WD-0021 "Stop the greeting offering unstarted stories"
OUT="$(plain '{"source":"startup"}')"
case "$OUT" in
  *"no Plan yet"*WD-0021*) ok "branch words matching one story's title pick that story" ;;
  *) no "branch words matching one story's title pick that story (got: $OUT)" ;;
esac

fresh_project main
story WD-0017 "Quality gate wiring"
story WD-0024 "Always show the PR url"
OUT="$(plain '{"source":"startup"}')"
case "$OUT" in
  *"| WD-0017 | Quality gate wiring |"*"| WD-0024 | Always show the PR url |"*) ok "no way to tell → both init'd stories in a table" ;;
  *) no "no way to tell → both init'd stories in a table (got: $OUT)" ;;
esac
case "$OUT" in *"/workflow-dev:resume to continue"*|*"no Plan yet"*) no "no way to tell → nothing is offered as the active story (got: $OUT)" ;; *) ok "no way to tell → nothing is offered as the active story" ;; esac
[[ "$(json_text_plain "$(hook '{"source":"startup"}')")" == "$OUT" ]] \
  && ok "the table is the same text in both modes" \
  || no "the table is the same text in both modes"
case "$(hook '{"source":"startup"}')" in *'
'*) no "hook mode puts no raw newline inside the JSON" ;; *) ok "hook mode puts no raw newline inside the JSON" ;; esac

fresh_project main
story WD-0017 "Quality gate wiring"
OUT="$(plain '{"source":"startup"}')"
case "$OUT" in
  *"no Plan yet"*WD-0017*) ok "one init'd story and no branch match → it is the active one, as before" ;;
  *) no "one init'd story and no branch match → it is the active one (got: $OUT)" ;;
esac

fresh_project main
story WD-0017 "Quality gate wiring"
printf '# WD-0030: Closed one\n\n### Implementation Status: Done\n' > "$PROJ/.workflow-dev/context/WD-0030.md"
story WD-0024 "Always show the PR url"
OUT="$(plain '{"source":"startup"}')"
case "$OUT" in *WD-0030*) no "a Done story is never listed (got: $OUT)" ;; *) ok "a Done story is never listed" ;; esac

# AC #3: the third wording — every task group Done — still reaches a story the
# branch points at.
fresh_project wd-0023-commit-hook
story WD-0023 "Commit hook matches mentions" '## 5. Plan
### Plan Progress
| # | Task Group | Status |
|---|---|---|
| 1 | x | Done |'
story WD-0017 "Quality gate wiring"
OUT="$(plain '{"source":"startup"}')"
case "$OUT" in
  *WD-0023*"every task group as Done"*) ok "a story with every task group Done keeps its own wording" ;;
  *) no "a story with every task group Done keeps its own wording (got: $OUT)" ;;
esac

# Step 2 must not guess: two stories equally close to the branch, or only one
# shared word, fall through to the table.
fresh_project fix/greeting-offers
story WD-0017 "Stop greeting offers early"
story WD-0021 "Stop greeting offers late"
OUT="$(plain '{"source":"startup"}')"
case "$OUT" in
  *"| WD-0017 |"*"| WD-0021 |"*) ok "two stories equally close to the branch → table, no guess" ;;
  *) no "two stories equally close to the branch → table, no guess (got: $OUT)" ;;
esac
fresh_project fix/greeting
story WD-0017 "Quality gate wiring"
story WD-0021 "Stop the greeting offering unstarted stories"
OUT="$(plain '{"source":"startup"}')"
case "$OUT" in
  *"| WD-0017 |"*"| WD-0021 |"*) ok "a single shared word is not enough → table, no guess" ;;
  *) no "a single shared word is not enough → table, no guess (got: $OUT)" ;;
esac

# A branch carrying two stories' codes is not an answer: filename order must not
# pick one — table instead.
fresh_project wd-0024-merge-wd-0017-cleanup
story WD-0017 "Quality gate wiring"
story WD-0024 "Always show the PR url"
OUT="$(plain '{"source":"startup"}')"
case "$OUT" in
  *"| WD-0017 |"*"| WD-0024 |"*) ok "a branch carrying two story codes → table, not filename order" ;;
  *) no "a branch carrying two story codes → table, not filename order (got: $OUT)" ;;
esac

# The table's Branch column must not attribute WD-215's branch to WD-21.
fresh_project main
( cd "$PROJ" && git branch feature/WD-215-payments )
story WD-21 "Short code story"
story WD-0099 "Another one"
OUT="$(plain '{"source":"startup"}')"
case "$OUT" in
  *"| WD-21 | Short code story | - |"*) ok "table Branch column does not match WD-21 to WD-215's branch" ;;
  *) no "table Branch column does not match WD-21 to WD-215's branch (got: $OUT)" ;;
esac

# --- 7: candidacy is the status *property*, not the section body ------------
# The regression (WD-0032): every init-written file carries a paragraph under
# the heading that itself contains the words "In Progress", so scanning the
# section body for the phrase counts a finished story as active.

# A Done story that keeps the template paragraph must never surface — not as a
# suggestion, not in the table. One genuine candidate sits beside it, so a reader
# that scanned the body would see two candidates, fall through to the table, and
# name WD-0040.
fresh_project main
cat > "$PROJ/.workflow-dev/context/WD-0040.md" <<'MD'
# WD-0040: Finished long ago

### Implementation Status: Done
Set to **In Progress** at creation, always — a context file existing at all means work has begun.

### Acceptance Criteria
| # | Criterion | Status | Notes |
|---|----------|--------|-------|
| 1 | Something | ✅ done | |
MD
story WD-0041 "Still being worked on"
OUT="$(plain '{"source":"startup"}')"
case "$OUT" in *WD-0040*) no "a Done story keeping the template paragraph never surfaces (got: $OUT)" ;; *) ok "a Done story keeping the template paragraph never surfaces" ;; esac
case "$OUT" in *"no Plan yet"*WD-0041*) ok "the In Progress story beside a Done one is the candidate" ;; *) no "the In Progress story beside a Done one is the candidate (got: $OUT)" ;; esac

# Won't Do is closed the same way, paragraph or not.
rm -f "$PROJ/.workflow-dev/context/WD-0041.md"
cat > "$PROJ/.workflow-dev/context/WD-0042.md" <<'MD'
# WD-0042: Abandoned

### Implementation Status: Won't Do
Set to **In Progress** at creation, always.
MD
[[ -z "$(plain '{"source":"startup"}')" ]] && ok "a Won't Do story with the paragraph is silent" || no "a Won't Do story with the paragraph is silent"

# The paraphrase the tolerant scan exists for stays accepted: a bare
# "## Implementation Status" heading with a "**Status:** In Progress" line.
fresh_project wd-0043-paraphrase
cat > "$PROJ/.workflow-dev/context/WD-0043.md" <<'MD'
# WD-0043: Paraphrased heading

## Implementation Status
**Status:** In Progress
MD
OUT="$(plain '{"source":"startup"}')"
case "$OUT" in *"no Plan yet"*WD-0043*) ok "the paraphrased In Progress shape is still a candidate" ;; *) no "the paraphrased In Progress shape is still a candidate (got: $OUT)" ;; esac

# A bare heading with no readable status value is not a candidate, even when the
# line below it carries the phrase in prose.
fresh_project main
cat > "$PROJ/.workflow-dev/context/WD-0044.md" <<'MD'
# WD-0044: Bare heading, prose below

## Implementation Status
Set to **In Progress** at creation, always.
MD
[[ -z "$(plain '{"source":"startup"}')" ]] && ok "a bare heading with prose below is not a candidate" || no "a bare heading with prose below is not a candidate"

# A heading quoted inside a fenced code block is an example, not the property.
# This bug is documented by quoting the heading, so a context file can carry a
# copy of it before its real one; read naively, the example wins.
fresh_project main
cat > "$PROJ/.workflow-dev/context/WD-0045.md" <<'MD'
# WD-0045: Documents the shape

The scanner used to match this heading quoted in a fence:

```
### Implementation Status: In Progress
Set to **In Progress** at creation, always.
```

### Implementation Status: Done
Set to **In Progress** at creation, always.
MD
[[ -z "$(plain '{"source":"startup"}')" ]] && ok "a fenced heading example is not read as the status" || no "a fenced heading example is not read as the status (got: $(plain '{"source":"startup"}'))"

# The real init shape — In Progress and the template paragraph — is a candidate.
fresh_project wd-0046-real-shape
cat > "$PROJ/.workflow-dev/context/WD-0046.md" <<'MD'
# WD-0046: Real init shape

### Implementation Status: In Progress
Set to **In Progress** at creation, always — a context file existing at all means work has begun.
MD
OUT="$(plain '{"source":"startup"}')"
case "$OUT" in *"no Plan yet"*WD-0046*) ok "the real init shape (In Progress and the paragraph) is a candidate" ;; *) no "the real init shape (In Progress and the paragraph) is a candidate (got: $OUT)" ;; esac

# The paraphrased shape with a closed value is closed too.
fresh_project main
cat > "$PROJ/.workflow-dev/context/WD-0047.md" <<'MD'
# WD-0047: Paraphrased Done

## Implementation Status
**Status:** Done
MD
[[ -z "$(plain '{"source":"startup"}')" ]] && ok "the paraphrased Done shape is silent" || no "the paraphrased Done shape is silent"

# A bare heading written with a trailing colon still carries its value on the
# next line; the empty inline value must not be read as the status.
fresh_project wd-0048-colon
cat > "$PROJ/.workflow-dev/context/WD-0048.md" <<'MD'
# WD-0048: Trailing colon

## Implementation Status:
**Status:** In Progress
MD
OUT="$(plain '{"source":"startup"}')"
case "$OUT" in *"no Plan yet"*WD-0048*) ok "a trailing-colon bare heading still reads the next line" ;; *) no "a trailing-colon bare heading still reads the next line (got: $OUT)" ;; esac

# A ``` fence is not closed by a ~~~ (or vice versa): the fenced example stays
# inside the fence, so it is not read as the status.
fresh_project main
cat > "$PROJ/.workflow-dev/context/WD-0049.md" <<'MD'
# WD-0049: Mixed fence delimiters

```
~~~
### Implementation Status: In Progress
```

### Implementation Status: Done
Set to **In Progress** at creation, always.
MD
[[ -z "$(plain '{"source":"startup"}')" ]] && ok "a ~~~ line does not close a backtick fence" || no "a ~~~ line does not close a backtick fence (got: $(plain '{"source":"startup"}'))"

# no local-backlog/ anywhere in $PROJ above: the decision uses only
# .workflow-dev/ and git, so this whole section already ran without it.
[[ ! -e "$PROJ/local-backlog" ]] && ok "decision made without any local-backlog folder" || no "decision made without any local-backlog folder"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
exit $((fail == 0 ? 0 : 1))
