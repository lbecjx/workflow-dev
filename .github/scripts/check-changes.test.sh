#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Tests for check-changes.sh, the validator of a pull request's release-note
# fragments.
# Run directly: bash .github/scripts/check-changes.test.sh

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
CHECK="$HERE/check-changes.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok() { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }

mkdir -p "$TMP/changes/sub"
cd "$TMP" || exit 1
note() { printf '%s\n' "${2:-A real note.}" > "$1"; }

# expect <label> <0|1> <path ...>: runs the checker on the paths as arguments.
expect() {
  local label="$1" want="$2"
  shift 2
  OUT="$("$CHECK" "$@" 2>&1 </dev/null)"
  local got=$?
  if [ "$got" -eq "$want" ]; then ok "$label"; else no "$label (exit $got, wanted $want: $OUT)"; fi
}

note changes/WD-1.feat.md
note changes/WD-2.fix.md
note changes/WD-3.breaking.md
note changes/WD-4.misc.md
note changes/WD-5.feat.1.md
note changes/WD-5.feat.2.md
: > changes/WD-6.fix.md
printf '  \n\t\n' > changes/WD-7.fix.md
note changes/WD-8.chore.md
note changes/sub/WD-9.feat.md
note changes/WD-10.feat.txt
note changes/.gitkeep ""
echo x > README.md

expect "valid feat" 0 changes/WD-1.feat.md
expect "valid fix" 0 changes/WD-2.fix.md
expect "valid breaking" 0 changes/WD-3.breaking.md
expect "valid misc" 0 changes/WD-4.misc.md
expect "numbered fragments of one story" 0 changes/WD-5.feat.1.md changes/WD-5.feat.2.md
expect "empty note fails" 1 changes/WD-6.fix.md
assert_msg() { case "$OUT" in *"$2"*) ok "$1" ;; *) no "$1 (output: $OUT)" ;; esac; }
assert_msg "empty note is named" "changes/WD-6.fix.md: the note is empty"
expect "whitespace-only note fails" 1 changes/WD-7.fix.md
expect "unknown type fails" 1 changes/WD-8.chore.md
assert_msg "unknown type is named" "changes/WD-8.chore.md: name must be"
expect "fragment in a subfolder fails" 1 changes/sub/WD-9.feat.md
expect "other extension fails" 1 changes/WD-10.feat.txt
expect "no fragment at all fails" 1
assert_msg "no fragment says what to add" "No release note found"
expect "only files outside changes/ fails" 1 README.md CHANGELOG.md
expect "only .gitkeep fails" 1 changes/.gitkeep
expect "valid plus invalid fails" 1 changes/WD-1.feat.md changes/WD-6.fix.md
assert_msg "the invalid one is still named" "WD-6.fix.md"
expect "a valid fragment with unrelated files passes" 0 README.md changes/WD-1.feat.md changes/.gitkeep
expect "missing file fails" 1 changes/WD-99.feat.md

OUT="$(printf 'changes/WD-1.feat.md\nREADME.md\n' | "$CHECK" 2>&1)"
[ $? -eq 0 ] && ok "paths on stdin" || no "paths on stdin ($OUT)"
OUT="$(printf '' | "$CHECK" 2>&1)"
[ $? -eq 1 ] && ok "empty stdin fails" || no "empty stdin fails ($OUT)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
