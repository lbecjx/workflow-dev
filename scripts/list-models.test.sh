#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Tests for list-models.sh — its input boundary is the gateway's model list, so
# per the coding standards ("every new input boundary ships its edge-case
# tests") the parse/failure cases are pinned here against a stub command, not a
# live gateway that depends on the machine. The Claude Code signal is set (or
# cleared) explicitly in every case, so nothing depends on the ambient
# environment the suite runs under.
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
# Under Claude Code: CLAUDECODE set, no gateway unless a case adds one.
cc() { env -u ANTHROPIC_BASE_URL -u CLAUDE_CODE_ENTRYPOINT CLAUDECODE=1 "$@"; }
# Outside Claude Code: neither signal set.
outside() { env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT "$@"; }

# --- 1: no gateway → exit 2, manual-entry guidance --------------------------
cc bash "$SCRIPT" >/dev/null 2>"$TMP/err3"
rc=$?
[[ $rc -eq 2 ]] && assert_contains "run \`/model\`" "$(cat "$TMP/err3")" "no gateway → exit 2 with manual guidance" \
              || no "no gateway → exit 2 with manual guidance"

# --- 2: via a gateway → ids parsed, provider claude-code, order kept --------
# Fixture ids are deliberately synthetic: the plugin names no model anywhere by
# design, and a realistic sample would read as one.
FIXC="$TMP/claude-models.json"
printf '{"data":[{"type":"model","id":"model-alpha"},{"type":"model","id":"model-beta"}]}' > "$FIXC"
OUTC="$(cc WD_CLAUDE_MODELS_CMD="cat $FIXC" bash "$SCRIPT" 2>/dev/null)"
assert_contains "claude-code	model-alpha" "$OUTC" "gateway id parsed"
assert_contains "claude-code	model-beta" "$OUTC" "second gateway id parsed"
FIRST_LINE="$(printf '%s\n' "$OUTC" | head -1)"
[[ "$FIRST_LINE" == "claude-code	model-alpha" ]] && ok "input order preserved" \
  || no "input order preserved (got: $FIRST_LINE)"

# --- 3: a gateway response with no ids → exit 2, not an empty list ----------
printf '{"data":[]}' > "$TMP/claude-empty.json"
cc WD_CLAUDE_MODELS_CMD="cat $TMP/claude-empty.json" bash "$SCRIPT" >/dev/null 2>"$TMP/errE"
rc=$?
[[ $rc -eq 2 ]] && assert_contains "no automatic model source" "$(cat "$TMP/errE")" "gateway without ids → exit 2" \
              || no "gateway without ids → exit 2"

# --- 4: a base URL set but curl unavailable → exit 2 (manual), not a crash --
BASH_ABS="$(command -v bash)"
mkdir -p "$TMP/emptybin2"
env -u CLAUDE_CODE_ENTRYPOINT CLAUDECODE=1 PATH="$TMP/emptybin2" ANTHROPIC_BASE_URL="http://example.invalid" \
  "$BASH_ABS" "$SCRIPT" >/dev/null 2>"$TMP/errN"
rc=$?
[[ $rc -eq 2 ]] && assert_contains "no automatic model source" "$(cat "$TMP/errN")" "no curl → exit 2 (manual), not a crash" \
              || no "no curl → exit 2 (manual), not a crash"

# --- 5: the real curl branch (curl present + base URL) parses gateway ids ---
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
OUTCU="$(cc PATH="$TMP/curlbin:$PATH" FAKE_CURL_ARGS="$ARGS_FILE" \
  ANTHROPIC_BASE_URL="http://gw.example/" ANTHROPIC_API_KEY="k-test" \
  bash "$SCRIPT" 2>/dev/null)"
assert_contains "claude-code	model-gateway" "$OUTCU" "real curl path parses gateway ids"
assert_contains "http://gw.example/v1/models" "$(cat "$ARGS_FILE")" "base URL trailing slash stripped"
assert_contains "x-api-key: k-test" "$(cat "$ARGS_FILE")" "API key sent as header"

# --- 6: outside Claude Code → exit 1 ----------------------------------------
outside bash "$SCRIPT" >/dev/null 2>"$TMP/err4"
rc=$?
[[ $rc -eq 1 ]] && assert_contains "not running under Claude Code" "$(cat "$TMP/err4")" "outside Claude Code → exit 1" \
              || no "outside Claude Code → exit 1"

# --- 7: --print-harness -----------------------------------------------------
PH="$(env -u CLAUDE_CODE_ENTRYPOINT CLAUDECODE=1 bash "$SCRIPT" --print-harness 2>/dev/null)"
[[ "$PH" == "claude" ]] && ok "--print-harness → claude (CLAUDECODE)" || no "--print-harness → claude (got: $PH)"
PH2="$(env -u CLAUDECODE CLAUDE_CODE_ENTRYPOINT=cli bash "$SCRIPT" --print-harness 2>/dev/null)"
[[ "$PH2" == "claude" ]] && ok "--print-harness → claude (CLAUDE_CODE_ENTRYPOINT)" || no "--print-harness → claude via entrypoint (got: $PH2)"
outside bash "$SCRIPT" --print-harness >/dev/null 2>"$TMP/errH"
rc=$?
[[ $rc -eq 1 ]] && assert_contains "not running under Claude Code" "$(cat "$TMP/errH")" "--print-harness outside Claude Code → exit 1" \
              || no "--print-harness outside Claude Code → exit 1"

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
