#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Tests for pre-commit-validate-check.sh. It needs a real git repo and a real
# marker file, so this builds a throwaway repo and points TMPDIR at a throwaway
# directory — the live /tmp marker store is never read or written.
#
# What it pins, beyond the text duality:
#   - the *deferred* marker still gets its own `allow` answer in hook mode, and
#     deliberately prints nothing in --message mode (see the script's comment:
#     `allow` surfaces no prompt on Claude Code either, so a notice here would
#     be a reminder the other harness never showed);
#   - a matching marker of either kind means silence, so the reminder cannot
#     become a tax paid on every commit after validate passed once.
#
#   bash scripts/pre-commit-validate-check.test.sh

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/pre-commit-validate-check.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok() { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }

# Payload construction needs real JSON escaping, and the scripts' own jq-less
# extraction is best-effort by design. Skip rather than fail on a host without
# jq, the same way the other suites in this repo do.
if ! command -v jq >/dev/null 2>&1; then
  echo "  skip  jq isn't installed — payload construction for this suite needs it"
  exit 0
fi

PROJ="$TMP/proj"
export TMPDIR="$TMP/tmpdir"
mkdir -p "$PROJ" "$TMPDIR"

( cd "$PROJ" \
  && git init -q . \
  && git config user.email t@example.com \
  && git config user.name t \
  && printf 'one\n' > tracked.txt \
  && git add tracked.txt \
  && git commit -qm "chore: seed" \
  && printf 'one\ntwo\n' > tracked.txt ) || { echo "  FAIL could not build the throwaway repo"; exit 1; }
mkdir -p "$PROJ/.workflow-dev/context"

mk() { printf '{"tool_input":{"command":%s}}' "$(printf '%s' "$1" | jq -Rs .)"; }
hook() { ( cd "$PROJ" && printf '%s' "$1" | bash "$SCRIPT" ); }
plain() { ( cd "$PROJ" && bash "$SCRIPT" --message "$1" ); }
envelope_reason() { printf '%s' "$1" | sed -E 's/.*"permissionDecisionReason":"(.*)"\}\}$/\1/'; }

# Same formula the script uses to key its marker, restated here on purpose: the
# test's job is to place a marker where the script looks for one.
MARKER_DIR="$TMPDIR/workflow-dev-validate"
REPO_HASH="$( cd "$PROJ" && git rev-parse --show-toplevel | tr -d '\n' | shasum | cut -c1-12 )"
MARKER="$MARKER_DIR/$REPO_HASH.json"
current_hash() {
  ( cd "$PROJ" \
    && { git diff --name-only HEAD -- . ':!.workflow-dev';
         git ls-files --others --exclude-standard -- . ':!.workflow-dev';
       } | sort -u | while IFS= read -r f; do
         [[ -n "$f" ]] && printf '%s\n' "$f" && cat "$f" 2>/dev/null
       done | shasum | cut -d' ' -f1 )
}

# --- 1: not a commit → silence in both modes --------------------------------
[[ -z "$(hook "$(mk 'ls -la')")" ]] && ok "non-commit command → hook mode silent" || no "non-commit command → hook mode silent"
[[ -z "$(plain "$(mk 'ls -la')")" ]] && ok "non-commit command → --message silent" || no "non-commit command → --message silent"

# --- 2: a commit with no marker → ask (hook) / the same text (--message) ----
mkdir -p "$MARKER_DIR"; rm -f "$MARKER"
COMMIT="$(mk 'git commit -m "feat: x"')"
JSON_OUT="$(hook "$COMMIT")"
PLAIN_OUT="$(plain "$COMMIT")"
[[ -n "$PLAIN_OUT" ]] && ok "--message prints the reminder" || no "--message prints the reminder (got nothing)"
[[ "$(envelope_reason "$JSON_OUT")" == "$PLAIN_OUT" ]] \
  && ok "both modes carry the same text (one copy, no drift)" \
  || no "both modes carry the same text (json: $(envelope_reason "$JSON_OUT") | msg: $PLAIN_OUT)"
case "$JSON_OUT" in
  *'"permissionDecision":"ask"'*) ok "hook mode still asks (never denies)" ;;
  *) no "hook mode still asks (got: $JSON_OUT)" ;;
esac

# --- 3: a matching 'deferred' marker → allow, and silence in --message ------
printf '{"diffHash":"%s","status":"deferred","at":"2026-09-29T00:00:00Z"}' "$(current_hash)" > "$MARKER"
JSON_OUT="$(hook "$COMMIT")"
case "$JSON_OUT" in
  *'"permissionDecision":"allow"'*) ok "deferred marker → hook mode allows" ;;
  *) no "deferred marker → hook mode allows (got: $JSON_OUT)" ;;
esac
[[ -z "$(plain "$COMMIT")" ]] && ok "deferred marker → --message silent (allow shows no prompt anywhere)" || no "deferred marker → --message silent (got: $(plain "$COMMIT"))"

# --- 4: a matching 'validated' marker → silence in both modes ---------------
printf '{"diffHash":"%s","status":"validated","at":"2026-09-29T00:00:00Z"}' "$(current_hash)" > "$MARKER"
[[ -z "$(hook "$COMMIT")" ]] && ok "validated marker → hook mode silent" || no "validated marker → hook mode silent"
[[ -z "$(plain "$COMMIT")" ]] && ok "validated marker → --message silent" || no "validated marker → --message silent"

# --- 5: a marker from an older diff is not a match --------------------------
printf '{"diffHash":"deadbeef","status":"validated","at":"2026-09-29T00:00:00Z"}' > "$MARKER"
[[ -n "$(plain "$COMMIT")" ]] && ok "stale marker hash → the reminder comes back" || no "stale marker hash → the reminder comes back"

# --- 6: no .workflow-dev/context → this project doesn't use the workflow -----
rm -rf "$PROJ/.workflow-dev"
rm -f "$MARKER"
[[ -z "$(plain "$COMMIT")" ]] && ok "no context dir → --message silent" || no "no context dir → --message silent"
[[ -z "$(hook "$COMMIT")" ]] && ok "no context dir → hook mode silent" || no "no context dir → hook mode silent"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
exit $((fail == 0 ? 0 : 1))
