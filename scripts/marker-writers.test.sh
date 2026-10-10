#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# End-to-end tests for the two marker *writers* — validate-mark-deferred.sh and
# git-message-mark-reviewed.sh — and for what the hooks do with what they wrote
# (WD-0027). marker-dir.test.sh pins the shared primitives; this pins the glue
# the writers put around them (`marker_ensure_dir || exit 1`, `... |
# marker_write ... || { echo; exit 1; }`) and the full marker round-trip, which
# is what AC #4 and AC #6 are actually about.
#
#   bash scripts/marker-writers.test.sh

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok() { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }

# Building the hook payloads needs real JSON escaping; the scripts' own fallback
# is best-effort by design, so skip rather than fail on a jq-less host, as the
# other suites do.
if ! command -v jq >/dev/null 2>&1; then
  echo "  skip  jq isn't installed — payload construction for this suite needs it"
  exit 0
fi

mode_of() {
  local m
  m="$(stat -f '%Lp' "$1" 2>/dev/null)" && [[ "$m" =~ ^[0-7]+$ ]] && { printf '%s' "$m"; return 0; }
  stat -c '%a' "$1" 2>/dev/null
}

export TMPDIR="$TMP/tmpdir"
mkdir -p "$TMPDIR"
PROJ="$TMP/proj"
mkdir -p "$PROJ/.workflow-dev/context"

( cd "$PROJ" \
  && git init -q . \
  && git config user.email t@example.com \
  && git config user.name t \
  && printf 'one\n' > tracked.txt \
  && git add tracked.txt \
  && git commit -qm "chore: seed" \
  && printf 'one\ntwo\n' > tracked.txt ) || { echo "  FAIL could not build the throwaway repo"; exit 1; }

mk() { printf '{"tool_input":{"command":%s}}' "$(printf '%s' "$1" | jq -Rs .)"; }
validate_hook() { ( cd "$PROJ" && printf '%s' "$1" | bash "$HERE/pre-commit-validate-check.sh" ); }
message_hook() { ( cd "$PROJ" && printf '%s' "$1" | bash "$HERE/pre-commit-message-check.sh" ); }
defer() { ( cd "$PROJ" && bash "$HERE/validate-mark-deferred.sh" ); }
review() { printf '%s' "$1" | ( cd "$PROJ" && bash "$HERE/git-message-mark-reviewed.sh" ); }

MARKER_DIR="$TMPDIR/workflow-dev-validate"
MSG_DIR="$MARKER_DIR/messages"
COMMIT="$(mk 'git commit -m "feat: a reviewed message"')"

# --- the deferred writer creates privately and the marker round-trips --------
defer >/dev/null 2>&1 || no "validate-mark-deferred.sh succeeds on a private store"
[[ "$(mode_of "$MARKER_DIR")" == "700" ]] && ok "the deferred writer creates the store mode 700" || no "the deferred writer creates the store mode 700 (got: $(mode_of "$MARKER_DIR"))"
MARKER_FILE="$(ls "$MARKER_DIR"/*.json 2>/dev/null | head -1)"
[[ -n "$MARKER_FILE" && "$(mode_of "$MARKER_FILE")" == "600" ]] && ok "the deferred marker is mode 600" || no "the deferred marker is mode 600"
case "$(validate_hook "$COMMIT")" in
  *'"permissionDecision":"allow"'*) ok "a deferred marker lets the validate hook allow (the round-trip)" ;;
  *) no "a deferred marker lets the validate hook allow (got: $(validate_hook "$COMMIT"))" ;;
esac

# --- the reviewed writer creates privately and the marker round-trips --------
review 'feat: a reviewed message' >/dev/null 2>&1 || no "git-message-mark-reviewed.sh succeeds on a private store"
[[ "$(mode_of "$MSG_DIR")" == "700" ]] && ok "the reviewed writer creates the messages store mode 700" || no "the reviewed writer creates the messages store mode 700 (got: $(mode_of "$MSG_DIR"))"
MSG_FILE="$(ls "$MSG_DIR"/*.json 2>/dev/null | head -1)"
[[ -n "$MSG_FILE" && "$(mode_of "$MSG_FILE")" == "600" ]] && ok "the reviewed marker is mode 600" || no "the reviewed marker is mode 600"
[[ -z "$(message_hook "$COMMIT")" ]] && ok "a reviewed marker silences the message hook (the round-trip)" || no "a reviewed marker silences the message hook (got: $(message_hook "$COMMIT"))"

# --- nothing to defer → no marker, no directory even -------------------------
FRESH_TMP="$TMP/fresh"
mkdir -p "$FRESH_TMP"
( cd "$PROJ" && git add -A >/dev/null 2>&1 && git commit -qm "chore: settle" )
OUT="$( cd "$PROJ" && TMPDIR="$FRESH_TMP" bash "$HERE/validate-mark-deferred.sh" 2>&1 )"
RC=$?
[[ $RC -eq 0 ]] && ok "a clean tree exits 0" || no "a clean tree exits 0 (got rc=$RC)"
case "$OUT" in
  *"Nothing uncommitted to defer"*) ok "a clean tree writes no marker and says so" ;;
  *) no "a clean tree writes no marker and says so (got: $OUT)" ;;
esac
# The store itself may be created before the "nothing to defer" check (the
# `mkdir -p` this replaced did the same), so what must hold is that no *marker*
# was written — an empty private store means nothing to any reader.
if compgen -G "$FRESH_TMP/workflow-dev-validate/*.json" >/dev/null; then
  no "a clean tree writes no marker"
else
  ok "a clean tree writes no marker"
fi

# --- an untrusted store refuses the write, and the hook asks instead ---------
# Re-add an uncommitted change so there is something to defer.
( cd "$PROJ" && printf 'three\n' > tracked.txt )
BEFORE="$(cat "$MARKER_FILE")"
chmod 777 "$MARKER_DIR"
OUT="$(defer 2>&1)"; RC=$?
[[ $RC -ne 0 ]] && ok "the deferred writer refuses a world-writable store (rc=$RC)" || no "the deferred writer refuses a world-writable store (got rc=$RC)"
case "$OUT" in
  *"group- or world-writable"*) ok "…and names the reason" ;;
  *) no "…and names the reason (got: $OUT)" ;;
esac
[[ "$(cat "$MARKER_FILE")" == "$BEFORE" ]] && ok "…and leaves the existing marker untouched" || no "…and leaves the existing marker untouched"

OUT="$(review 'another message' 2>&1)"; RC=$?
[[ $RC -ne 0 ]] && ok "the reviewed writer refuses a world-writable store (rc=$RC)" || no "the reviewed writer refuses a world-writable store (got rc=$RC)"

chmod 700 "$MARKER_DIR"

# --- the reviewed writer follows the human's co-authorship decision ----------
# The decision lives in the active story (coauthor-decision.sh); the fixtures
# are built here, never typed into a shell command the live hook would deny.
( cd "$PROJ" && git checkout -q -b wd-0099-coauthor )
coauthor_story() {
  printf '# WD-0099: a story\n\n### Decisions\n| Date | Decision | Decided by |\n|---|---|---|\n%s\n\n### Implementation Status: In Progress\n' \
    "$1" > "$PROJ/.workflow-dev/context/WD-0099.md"
}
TRAILER='Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>'
PRLINE='🤖 Generated with [Claude Code](https://claude.com/claude-code)'
marks() { review "$1" >/dev/null 2>&1 && printf marked || printf refused; }
expect_mark() { [[ "$2" == "$3" ]] && ok "$1" || no "$1 (got: $2)"; }

coauthor_story '| 2026-10-10 | Agent co-authorship: yes | Human |'
expect_mark "yes: a message ending in the trailer is marked" "$(marks "$(printf 'Add a thing\n\n%s' "$TRAILER")")" marked
expect_mark "yes: a PR text ending in the PR line is marked" "$(marks "$(printf 'Title\n\nSummary.\n\n%s' "$PRLINE")")" marked
expect_mark "yes: an attribution phrase in the body is refused" "$(marks "$(printf 'AI-generated change\n\n%s' "$TRAILER")")" refused
coauthor_story '| 2026-10-10 | Agent co-authorship: no | Human |'
expect_mark "no: the trailer is refused" "$(marks "$(printf 'Add a thing\n\n%s' "$TRAILER")")" refused
coauthor_story ''
expect_mark "no decision: the trailer is refused" "$(marks "$(printf 'Add a thing\n\n%s' "$TRAILER")")" refused
coauthor_story '| 2026-10-10 | Agent co-authorship: yes | Agent (inferred) |'
expect_mark "a yes the agent inferred: the trailer is refused" "$(marks "$(printf 'Add a thing\n\n%s' "$TRAILER")")" refused
rm -f "$PROJ/.workflow-dev/context/WD-0099.md"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
exit $((fail == 0 ? 0 : 1))
