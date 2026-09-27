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

# A minimal OpenCode store with one top-level session for the given directory,
# so the save's OpenCode path runs (and calls ensure_gitignored).
mkdb() { # $1 db path, $2 directory
  sqlite3 "$1" <<SQL
CREATE TABLE session_v2 (id text, parent_id text, directory text, time_updated integer);
CREATE TABLE session_message (session_id text, seq integer, type text, data text);
INSERT INTO session_v2 VALUES ('ses_g',NULL,'$2',100);
INSERT INTO session_message VALUES ('ses_g',1,'user','{"x":1}');
SQL
}
run_save() { # $1 project dir, $2 db
  ( cd "$1" && env -u CLAUDECODE OPENCODE_TERMINAL=1 OPENCODE_DB="$2" bash "$READ" "$STORY" >/dev/null 2>&1 )
}

# --- A: an ancestor already ignores .workflow-dev/ → .gitignore untouched -----
A="$TMP/a"; mkdir -p "$A"; ( cd "$A" && git init -q )
printf '.workflow-dev/\n' > "$A/.gitignore"
mkdb "$TMP/a.db" "$(cd "$A" && pwd -P)"
run_save "$A" "$TMP/a.db"
if [[ "$(cat "$A/.gitignore")" == ".workflow-dev/" ]]; then
  ok "ancestor ignores it: .gitignore untouched"
else
  no "ancestor ignores it: .gitignore was modified → $(cat "$A/.gitignore")"
fi

# --- B: not ignored → the pattern is appended, exactly once -------------------
B="$TMP/b"; mkdir -p "$B"; ( cd "$B" && git init -q )
: > "$B/.gitignore"
mkdb "$TMP/b.db" "$(cd "$B" && pwd -P)"
run_save "$B" "$TMP/b.db"
if grep -qxF "$PATTERN" "$B/.gitignore"; then
  ok "not ignored: pattern appended"
else
  no "not ignored: pattern missing"
fi
run_save "$B" "$TMP/b.db"
n=$(grep -cxF "$PATTERN" "$B/.gitignore")
[[ "$n" == "1" ]] && ok "not ignored: appended once (not duplicated)" || no "not ignored: appended $n times"

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
