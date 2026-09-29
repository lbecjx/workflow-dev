#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Tests for pre-commit-message-check.sh, which is the one script here that has
# *two* enforcement levels — so it owns three words, not a boolean:
# `ok` (nothing to raise), `notify` (the Part 12 review) and `block` (the
# AI-attribution hard rule). All three are pinned, because OpenCode's plugin
# reads that word to decide whether to post a notice or stop the command, and a
# missing word would silently become "no reminder".
#
# The reviewed-marker path is exercised too: it is the only thing that turns
# `notify` into `ok`, and TMPDIR is redirected so the live marker store is
# untouched.
#
#   bash scripts/pre-commit-message-check.test.sh

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/pre-commit-message-check.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok() { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }

# Payload construction needs real JSON escaping, and the script's own jq-less
# extraction is best-effort *by design* (its comment says so: it handles the
# shapes this repo's own git conventions produce, and fails toward doing nothing
# otherwise). So rather than assert a decision table the fallback was never
# written to support, skip the way the other suites do — a jq-less host reads
# "not covered here", not eight failures that look like regressions.
if ! command -v jq >/dev/null 2>&1; then
  echo "  skip  jq isn't installed — payload construction for this suite needs it"
  exit 0
fi

export TMPDIR="$TMP/tmpdir"
mkdir -p "$TMPDIR"

mk() { printf '{"tool_input":{"command":%s}}' "$(printf '%s' "$1" | jq -Rs .)"; }
hook() { printf '%s' "$1" | bash "$SCRIPT"; }
status() { bash "$SCRIPT" --status "$1"; }
plain() { bash "$SCRIPT" --message "$1"; }
envelope_reason() { printf '%s' "$1" | sed -E 's/.*"permissionDecisionReason":"(.*)"\}\}$/\1/'; }

ATTR="$(mk 'git commit -m "feat: x

Co-Authored-By: Claude <noreply@anthropic.com>"')"
CLEAN="$(mk 'git commit -m "feat: add a thing"')"
OTHER="$(mk 'ls -la')"
PR="$(mk 'gh pr create --title "Add a thing" --body "Some description."')"

# --- 1: not a commit/PR → ok, and silence -----------------------------------
[[ "$(status "$OTHER")" == "ok" ]] && ok "non-commit command → ok" || no "non-commit command → ok (got: $(status "$OTHER"))"
[[ -z "$(plain "$OTHER")" ]] && ok "non-commit command → --message silent" || no "non-commit command → --message silent"
[[ -z "$(hook "$OTHER")" ]] && ok "non-commit command → hook mode silent" || no "non-commit command → hook mode silent"

# --- 2: attribution → block, and the same text in both modes ----------------
[[ "$(status "$ATTR")" == "block" ]] && ok "AI attribution → block" || no "AI attribution → block (got: $(status "$ATTR"))"
ATTR_TEXT="$(plain "$ATTR")"
[[ -n "$ATTR_TEXT" ]] && ok "AI attribution → --message prints the reason" || no "AI attribution → --message prints the reason"
ATTR_JSON="$(hook "$ATTR")"
case "$ATTR_JSON" in
  *'"permissionDecision":"deny"'*) ok "AI attribution → hook mode still denies" ;;
  *) no "AI attribution → hook mode still denies (got: $ATTR_JSON)" ;;
esac
[[ "$(envelope_reason "$ATTR_JSON")" == "$ATTR_TEXT" ]] \
  && ok "attribution: hook JSON and --message carry the same text" \
  || no "attribution: hook JSON and --message carry the same text"
case "$ATTR_TEXT" in
  *"Part 12.3"*) ok "the block reason names the hard rule" ;;
  *) no "the block reason names the hard rule (got: $ATTR_TEXT)" ;;
esac

# --- 3: clean but unreviewed → notify, and the same text in both modes ------
[[ "$(status "$CLEAN")" == "notify" ]] && ok "clean unreviewed → notify" || no "clean unreviewed → notify (got: $(status "$CLEAN"))"
CLEAN_TEXT="$(plain "$CLEAN")"
CLEAN_JSON="$(hook "$CLEAN")"
case "$CLEAN_JSON" in
  *'"permissionDecision":"ask"'*) ok "clean unreviewed → hook mode still asks (never denies)" ;;
  *) no "clean unreviewed → hook mode still asks (got: $CLEAN_JSON)" ;;
esac
[[ "$(envelope_reason "$CLEAN_JSON")" == "$CLEAN_TEXT" ]] \
  && ok "review: hook JSON and --message carry the same text" \
  || no "review: hook JSON and --message carry the same text"

# --- 4: a reviewed message is ok, in both modes -----------------------------
# Same formula the script uses to key its marker: shasum of the extracted body.
BODY_HASH="$(printf '%s' 'feat: add a thing' | shasum | cut -d' ' -f1)"
mkdir -p "$TMPDIR/workflow-dev-validate/messages"
: > "$TMPDIR/workflow-dev-validate/messages/$BODY_HASH.json"
[[ "$(status "$CLEAN")" == "ok" ]] && ok "reviewed message → ok" || no "reviewed message → ok (got: $(status "$CLEAN"))"
[[ -z "$(plain "$CLEAN")" ]] && ok "reviewed message → --message silent" || no "reviewed message → --message silent"
[[ -z "$(hook "$CLEAN")" ]] && ok "reviewed message → hook mode silent" || no "reviewed message → hook mode silent"
# ...and it does not launder attribution: the deny does not consult the marker.
[[ "$(status "$ATTR")" == "block" ]] && ok "a reviewed marker never un-blocks attribution" || no "a reviewed marker never un-blocks attribution"
rm -rf "$TMPDIR/workflow-dev-validate/messages"

# --- 5: a PR's title+description is hashed together -------------------------
# The PR path is the one place HASH_TEXT is not just the body — pinned because
# summarize-changes marks a PR with the same concatenation, and the two must agree.
PR_TITLE="Add a thing"
PR_BODY="Some description."
PR_HASH="$(printf '%s\n\n%s' "$PR_TITLE" "$PR_BODY" | shasum | cut -d' ' -f1)"
mkdir -p "$TMPDIR/workflow-dev-validate/messages"
: > "$TMPDIR/workflow-dev-validate/messages/$PR_HASH.json"
[[ "$(status "$PR")" == "ok" ]] && ok "PR marked with title+body hash → ok" || no "PR marked with title+body hash → ok (got: $(status "$PR"))"
rm -rf "$TMPDIR/workflow-dev-validate/messages"
[[ "$(status "$PR")" == "notify" ]] && ok "PR with no marker → notify" || no "PR with no marker → notify (got: $(status "$PR"))"

# --- 6: the vocabulary is exactly three words -------------------------------
WORDS="$(status "$OTHER") $(status "$CLEAN") $(status "$ATTR")"
unknown=0
for w in $WORDS; do
  case "$w" in
    ok|notify|block) ;;
    *) no "unknown status word: $w"; unknown=1 ;;
  esac
done
# Conditional on the loop above: printing this unconditionally would report a
# pass for the property that just failed.
[[ $unknown -eq 0 ]] && ok "every verdict is one of ok|notify|block ($WORDS)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
exit $((fail == 0 ? 0 : 1))
