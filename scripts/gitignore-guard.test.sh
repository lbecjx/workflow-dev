#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Tests for the `.gitignore` guard in ensure_gitignored (WD-0009): when an
# ancestor pattern already ignores the compaction-state dir, nothing is added
# (a tracked `.gitignore` must not be dirtied by a save); when it isn't ignored,
# the pattern is added exactly once. Run directly:
#
#   bash scripts/gitignore-guard.test.sh

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
READ="$HERE/save-read-unsaved.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok() { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }

STORY="GIT-1"
PATTERN='.workflow-dev/context/.compaction-state/'

# A state file pointing at a transcript with unsaved lines, so the save's read
# runs far enough to call ensure_gitignored.
seed() { # $1 project dir
  mkdir -p "$1/.workflow-dev/context/.compaction-state"
  printf '{"n":1}\n' > "$1/transcript.jsonl"
  printf '{"claudePath":"%s","claudeLength":0}' "$1/transcript.jsonl" \
    > "$1/.workflow-dev/context/.compaction-state/$STORY.json"
}
run_save() { # $1 project dir
  ( cd "$1" && bash "$READ" "$STORY" >/dev/null 2>&1 )
}

# --- A: an ancestor already ignores .workflow-dev/ → .gitignore untouched -----
A="$TMP/a"; mkdir -p "$A"; ( cd "$A" && git init -q )
printf '.workflow-dev/\n' > "$A/.gitignore"
seed "$A"
run_save "$A"
if [[ "$(cat "$A/.gitignore")" == ".workflow-dev/" ]]; then
  ok "ancestor ignores it: .gitignore untouched"
else
  no "ancestor ignores it: .gitignore was modified → $(cat "$A/.gitignore")"
fi

# --- B: not ignored → the pattern is appended, exactly once -------------------
B="$TMP/b"; mkdir -p "$B"; ( cd "$B" && git init -q )
: > "$B/.gitignore"
seed "$B"
run_save "$B"
if grep -qxF "$PATTERN" "$B/.gitignore"; then
  ok "not ignored: pattern appended"
else
  no "not ignored: pattern missing"
fi
run_save "$B"
n=$(grep -cxF "$PATTERN" "$B/.gitignore")
[[ "$n" == "1" ]] && ok "not ignored: appended once (not duplicated)" || no "not ignored: appended $n times"

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
