#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code and OpenCode
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Tests for roles-hash.sh — the one value both setup-models (write side) and
# model-tiering-check.sh (read side) share, so the write/read sides can't drift.
# No test framework in this repo; run it directly:
#
#   bash scripts/roles-hash.test.sh
#
# Exits non-zero if any assertion fails.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/roles-hash.sh"
ROLES="$HERE/../skills/setup-models/references/roles.md"

pass=0
fail=0
ok() { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }

# --- 1: the hash is exactly `shasum roles.md`, first field -------------------
EXPECTED="$(shasum "$ROLES" | cut -d' ' -f1)"
GOT="$(bash "$SCRIPT")"
[[ "$GOT" == "$EXPECTED" ]] && ok "hash matches shasum roles.md" \
  || no "hash matches shasum roles.md (got: $GOT, want: $EXPECTED)"
[[ "$GOT" =~ ^[0-9a-f]{40}$ ]] && ok "hash is 40 hex chars" \
  || no "hash is 40 hex chars (got: $GOT)"

# --- 2: an unreadable registry → exit 1 + stderr, never an empty hash --------
mv "$ROLES" "$ROLES.bak"
restore_roles() { [[ -e "$ROLES.bak" ]] && mv "$ROLES.bak" "$ROLES"; }
trap restore_roles EXIT
OUT="$(bash "$SCRIPT" 2>&1)"; rc=$?
[[ $rc -eq 1 ]] && ok "unreadable registry → exit 1" || no "unreadable registry → exit 1 (got: $rc)"
case "$OUT" in
  *"cannot read"*) ok "unreadable registry → stderr message" ;;
  *) no "unreadable registry → stderr message (got: $OUT)" ;;
esac
restore_roles
trap - EXIT

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
