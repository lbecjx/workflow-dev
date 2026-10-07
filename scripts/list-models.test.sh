#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code and OpenCode
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
# Fixture ids are deliberately synthetic: the plugin names no model anywhere by
# design, and a realistic sample would read as one. What matters here is the
# shape — vendor/model, with a nested slash in the middle entry.
cat > "$FIX" <<'LINES'
alpha/alpha-one
nested-vendor/sub/id-three
beta/beta-two
LINES
OUT="$(env WD_OPENCODE_MODELS_CMD="cat $FIX" bash "$SCRIPT" --harness opencode 2>/dev/null)"
assert_contains "alpha	alpha-one" "$OUT" "plain provider/model splits on the slash"
assert_contains "nested-vendor	sub/id-three" "$OUT" "nested id splits on the FIRST slash only"
FIRST_LINE="$(printf '%s\n' "$OUT" | head -1)"
[[ "$FIRST_LINE" == "alpha	alpha-one" ]] && ok "input order preserved" \
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
printf '{"data":[{"type":"model","id":"model-alpha"},{"type":"model","id":"model-beta"}]}' > "$FIXC"
OUTC="$(env WD_CLAUDE_MODELS_CMD="cat $FIXC" bash "$SCRIPT" --harness claude 2>/dev/null)"
assert_contains "claude-code	model-alpha" "$OUTC" "gateway id parsed"
assert_contains "claude-code	model-beta" "$OUTC" "second gateway id parsed"

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

# --- 5f: the real curl branch (curl present + base URL) parses gateway ids --
# A fake curl records its args and answers with a known /v1/models body, so the
# branch that is otherwise unreachable in a hermetic test (real curl against a
# real gateway) gets exercised: ids parsed, trailing slash stripped, key sent.
mkdir -p "$TMP/curlbin"
cat > "$TMP/curlbin/curl" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "$FAKE_CURL_ARGS"
printf '%s' '{"data":[{"type":"model","id":"model-gateway"}]}'
EOF
chmod +x "$TMP/curlbin/curl"
ARGS_FILE="$TMP/curlargs.txt"
OUTCU="$(env PATH="$TMP/curlbin:$PATH" FAKE_CURL_ARGS="$ARGS_FILE" \
  ANTHROPIC_BASE_URL="http://gw.example/" ANTHROPIC_API_KEY="k-test" \
  bash "$SCRIPT" --harness claude 2>/dev/null)"
assert_contains "claude-code	model-gateway" "$OUTCU" "real curl path parses gateway ids"
assert_contains "http://gw.example/v1/models" "$(cat "$ARGS_FILE")" "base URL trailing slash stripped"
assert_contains "x-api-key: k-test" "$(cat "$ARGS_FILE")" "API key sent as header"

# --- 6: no harness signal at all → exit 1 ----------------------------------
env -u OPENCODE -u OPENCODE_TERMINAL -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT \
  bash "$SCRIPT" >/dev/null 2>"$TMP/err4"
rc=$?
[[ $rc -eq 1 ]] && assert_contains "no harness detected" "$(cat "$TMP/err4")" "no harness signal → exit 1" \
              || no "no harness signal → exit 1"

# --- 7: --harness opencode wins even when Claude env is also present --------
OUT7="$(env CLAUDECODE=1 WD_OPENCODE_MODELS_CMD="cat $FIX" bash "$SCRIPT" --harness opencode 2>/dev/null)"
assert_contains "alpha	alpha-one" "$OUT7" "--harness overrides ambient detection"

# --- 8: --print-harness reports just the detected harness ------------------
PH="$(env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT OPENCODE_TERMINAL=1 bash "$SCRIPT" --print-harness 2>/dev/null)"
[[ "$PH" == "opencode" ]] && ok "--print-harness → opencode" || no "--print-harness → opencode (got: $PH)"

PH2="$(env -u OPENCODE -u OPENCODE_TERMINAL CLAUDECODE=1 bash "$SCRIPT" --print-harness 2>/dev/null)"
[[ "$PH2" == "claude" ]] && ok "--print-harness → claude" || no "--print-harness → claude (got: $PH2)"

env -u OPENCODE -u OPENCODE_TERMINAL -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT \
  bash "$SCRIPT" --print-harness >/dev/null 2>"$TMP/errH"
rc=$?
[[ $rc -eq 1 ]] && assert_contains "no harness detected" "$(cat "$TMP/errH")" "--print-harness with no signal → exit 1" \
              || no "--print-harness with no signal → exit 1"

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
