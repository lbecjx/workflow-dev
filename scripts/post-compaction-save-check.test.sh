#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code and OpenCode
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Tests for post-compaction-save-check.sh. It reads the pendingSave flag out of
# .workflow-dev/context/.compaction-state/*.json and *writes it off* as it
# fires — so each case here gets a freshly armed state file, or it would be
# testing the second run instead of the first.
#
# Two things this pins beyond the text duality:
#   - the flag is cleared in both modes, so an OpenCode notice is not a notice
#     that fires on every subsequent event forever;
#   - the priority wording still follows `hook_event_name`, because that field
#     is a caller-supplied input in --message mode and could silently become a
#     constant.
#
#   bash scripts/post-compaction-save-check.test.sh

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/post-compaction-save-check.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok() { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }

PROJ="$TMP/proj"
STATE_DIR="$PROJ/.workflow-dev/context/.compaction-state"
mkdir -p "$STATE_DIR"

arm() {
  cat > "$STATE_DIR/WD-0001.json" <<'JSON'
{"transcriptPath":"/tmp/does-not-need-to-exist.jsonl","length":42,"dateTime":"2026-09-29T00:00:00Z","pendingSave":true}
JSON
}

hook() { ( cd "$PROJ" && printf '%s' "$1" | bash "$SCRIPT" ); }
plain() { ( cd "$PROJ" && bash "$SCRIPT" --message "$1" ); }
envelope_text() { printf '%s' "$1" | sed -E 's/.*"additionalContext":"(.*)"\}\}$/\1/'; }
pending() { grep -o '"pendingSave":[a-z]*' "$STATE_DIR/WD-0001.json"; }

# --- 1: the same text in both modes, and the flag cleared in both -----------
arm
PLAIN_OUT="$(plain '{"hook_event_name":"PostToolUse"}')"
[[ -n "$PLAIN_OUT" ]] && ok "--message prints the reminder" || no "--message prints the reminder (got nothing)"
[[ "$(pending)" == '"pendingSave":false' ]] && ok "--message clears pendingSave" || no "--message clears pendingSave (got $(pending))"

arm
JSON_OUT="$(hook '{"hook_event_name":"PostToolUse"}')"
[[ "$(envelope_text "$JSON_OUT")" == "$PLAIN_OUT" ]] \
  && ok "both modes carry the same text (one copy, no drift)" \
  || no "both modes carry the same text"
[[ "$(pending)" == '"pendingSave":false' ]] && ok "hook mode clears pendingSave" || no "hook mode clears pendingSave"
case "$JSON_OUT" in
  *'"hookEventName":"PostToolUse"'*) ok "hook mode echoes the firing event's name" ;;
  *) no "hook mode echoes the firing event's name (got: $JSON_OUT)" ;;
esac

# --- 2: cleared means quiet, not repeated -----------------------------------
[[ -z "$(plain '{"hook_event_name":"PostToolUse"}')" ]] && ok "already-saved story → --message silent" || no "already-saved story → --message silent"
[[ -z "$(hook '{"hook_event_name":"PostToolUse"}')" ]] && ok "already-saved story → hook mode silent" || no "already-saved story → hook mode silent"

# --- 3: the priority clause follows hook_event_name -------------------------
arm
POST="$(plain '{"hook_event_name":"PostToolUse"}')"
arm
PROMPT="$(plain '{"hook_event_name":"UserPromptSubmit"}')"
[[ "$POST" != "$PROMPT" ]] && ok "the two events word the priority clause differently" || no "the two events word the priority clause differently"
case "$POST" in
  *"Before running the next tool call"*) ok "PostToolUse keeps the autonomous-run wording" ;;
  *) no "PostToolUse keeps the autonomous-run wording (got: $POST)" ;;
esac
case "$PROMPT" in
  *"Before answering the question below"*) ok "UserPromptSubmit keeps the human-turn wording" ;;
  *) no "UserPromptSubmit keeps the human-turn wording (got: $PROMPT)" ;;
esac

# --- 4: a missing event name is silence, in both modes ----------------------
arm
[[ -z "$(plain '{}')" ]] && ok "no hook_event_name → --message silent" || no "no hook_event_name → --message silent"
[[ -z "$(hook '{}')" ]] && ok "no hook_event_name → hook mode silent" || no "no hook_event_name → hook mode silent"

# --- 5: no state directory at all is silence --------------------------------
rm -rf "$PROJ/.workflow-dev"
[[ -z "$(plain '{"hook_event_name":"PostToolUse"}')" ]] && ok "no state dir → --message silent" || no "no state dir → --message silent"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
exit $((fail == 0 ? 0 : 1))
