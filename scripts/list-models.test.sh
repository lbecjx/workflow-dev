#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Tests for list-models.sh — its input boundary is the harness's own model
# list, so per the coding standards ("every new input boundary ships its
# edge-case tests") the parse/failure cases are pinned here against a stub
# command, not a live `opencode models` that depends on the machine.
# No test framework in this repo; run it directly:
#
#   bash scripts/list-models.test.sh
#
# Exits non-zero if any assertion fails.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/list-models.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
no()  { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }
assert_contains() { # $1 expected substring, $2 haystack, $3 label
  case "$2" in
    *"$1"*) ok "$3" ;;
    *) no "$3 (missing: $1)" ;;
  esac
}

# --- 1: OpenCode — provider/model split on the first slash, order kept ------
FIX="$TMP/models.txt"
cat > "$FIX" <<'LINES'
deepseek/deepseek-flash
openrouter/~anthropic/claude-haiku-latest
opencode/ling-3.0-flash-fin-free
LINES
OUT="$(env WD_OPENCODE_MODELS_CMD="cat $FIX" bash "$SCRIPT" --harness opencode 2>/dev/null)"
assert_contains "deepseek	deepseek-flash" "$OUT" "plain provider/model splits on the slash"
assert_contains "openrouter	~anthropic/claude-haiku-latest" "$OUT" "nested id splits on the FIRST slash only"
FIRST_LINE="$(printf '%s\n' "$OUT" | head -1)"
[[ "$FIRST_LINE" == "deepseek	deepseek-flash" ]] && ok "input order preserved" \
  || no "input order preserved (got: $FIRST_LINE)"

# --- 2: a line without a slash is skipped, not emitted as provider-only -----
FIX2="$TMP/models2.txt"
printf 'noslashmodel\nvalid/model\n' > "$FIX2"
OUT2="$(env WD_OPENCODE_MODELS_CMD="cat $FIX2" bash "$SCRIPT" --harness opencode 2>/dev/null)"
assert_contains "valid	model" "$OUT2" "valid entry kept"
case "$OUT2" in
  *noslashmodel*) no "slashless line skipped" ;;
  *) ok "slashless line skipped" ;;
esac

# --- 3: the command failing → exit 1, honest message ------------------------
env WD_OPENCODE_MODELS_CMD="false" bash "$SCRIPT" --harness opencode >/dev/null 2>"$TMP/err"
rc=$?
[[ $rc -eq 1 ]] && assert_contains "cannot enumerate" "$(cat "$TMP/err")" "failed command → exit 1 with reason" \
              || no "failed command → exit 1 with reason"

# --- 4: a command that succeeds but returns nothing → exit 1, not empty list -
printf '' > "$TMP/empty.txt"
env WD_OPENCODE_MODELS_CMD="cat $TMP/empty.txt" bash "$SCRIPT" --harness opencode >/dev/null 2>"$TMP/err2"
rc=$?
[[ $rc -eq 1 ]] && assert_contains "no provider/model entries" "$(cat "$TMP/err2")" "empty output → exit 1, not an empty list" \
              || no "empty output → exit 1, not an empty list"

# --- 5: Claude Code with no gateway → exit 2, manual-entry guidance --------
env -u OPENCODE -u OPENCODE_TERMINAL -u ANTHROPIC_BASE_URL bash "$SCRIPT" --harness claude >/dev/null 2>"$TMP/err3"
rc=$?
[[ $rc -eq 2 ]] && assert_contains "run \`/model\`" "$(cat "$TMP/err3")" "CC without a gateway → exit 2 with manual guidance" \
              || no "CC without a gateway → exit 2 with manual guidance"

# --- 5b: an unknown harness → exit 1 ---------------------------------------
env -u OPENCODE -u OPENCODE_TERMINAL bash "$SCRIPT" --harness acme >/dev/null 2>"$TMP/errU"
rc=$?
[[ $rc -eq 1 ]] && assert_contains "unknown harness 'acme'" "$(cat "$TMP/errU")" "unknown harness → exit 1" \
              || no "unknown harness → exit 1"

# --- 5c: Claude Code via a gateway → ids parsed, provider claude-code ------
FIXC="$TMP/claude-models.json"
printf '{"data":[{"type":"model","id":"claude-sonnet-5-5"},{"type":"model","id":"claude-haiku-5"}]}' > "$FIXC"
OUTC="$(env WD_CLAUDE_MODELS_CMD="cat $FIXC" bash "$SCRIPT" --harness claude 2>/dev/null)"
assert_contains "claude-code	claude-sonnet-5-5" "$OUTC" "gateway id parsed"
assert_contains "claude-code	claude-haiku-5" "$OUTC" "second gateway id parsed"

# --- 5d: a gateway response with no ids → exit 2, not an empty list ---------
printf '{"data":[]}' > "$TMP/claude-empty.json"
env WD_CLAUDE_MODELS_CMD="cat $TMP/claude-empty.json" bash "$SCRIPT" --harness claude >/dev/null 2>"$TMP/errE"
rc=$?
[[ $rc -eq 2 ]] && assert_contains "no automatic model source" "$(cat "$TMP/errE")" "gateway without ids → exit 2" \
              || no "gateway without ids → exit 2"

# --- 5e: a base URL set but curl unavailable → exit 2 (manual), not a crash -
BASH_ABS="$(command -v bash)"
mkdir -p "$TMP/emptybin2"
env PATH="$TMP/emptybin2" ANTHROPIC_BASE_URL="http://example.invalid" "$BASH_ABS" "$SCRIPT" --harness claude >/dev/null 2>"$TMP/errN"
rc=$?
[[ $rc -eq 2 ]] && assert_contains "no automatic model source" "$(cat "$TMP/errN")" "no curl → exit 2 (manual), not a crash" \
              || no "no curl → exit 2 (manual), not a crash"

# --- 6: no harness signal at all → exit 1 ----------------------------------
env -u OPENCODE -u OPENCODE_TERMINAL -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT \
  bash "$SCRIPT" >/dev/null 2>"$TMP/err4"
rc=$?
[[ $rc -eq 1 ]] && assert_contains "no harness detected" "$(cat "$TMP/err4")" "no harness signal → exit 1" \
              || no "no harness signal → exit 1"

# --- 7: --harness opencode wins even when Claude env is also present --------
OUT7="$(env CLAUDECODE=1 WD_OPENCODE_MODELS_CMD="cat $FIX" bash "$SCRIPT" --harness opencode 2>/dev/null)"
assert_contains "deepseek	deepseek-flash" "$OUT7" "--harness overrides ambient detection"

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
