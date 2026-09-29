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

printf '\n%d passed, %d failed\n' "$pass" "$fail"
exit $((fail == 0 ? 0 : 1))
