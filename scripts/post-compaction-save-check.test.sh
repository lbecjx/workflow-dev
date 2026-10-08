#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
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
# Two things this pins beyond the text:
#   - the flag is cleared as the notice fires, so it is not a notice that
#     fires on every subsequent event forever;
#   - the priority wording follows `hook_event_name`, so it cannot silently
#     become a constant.
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
envelope_text() { printf '%s' "$1" | sed -E 's/.*"additionalContext":"(.*)"\}\}$/\1/'; }
# The reminder text the hook carries — empty when the hook is silent.
plain() { local out; out="$(hook "$1")"; [[ -n "$out" ]] && envelope_text "$out"; }
pending() { grep -o '"pendingSave":[a-z]*' "$STATE_DIR/WD-0001.json"; }

# --- 1: the reminder fires once and clears the flag ------------------------
arm
JSON_OUT="$(hook '{"hook_event_name":"PostToolUse"}')"
[[ -n "$(envelope_text "$JSON_OUT")" ]] && ok "an armed story prints the reminder" || no "an armed story prints the reminder (got nothing)"
[[ "$(pending)" == '"pendingSave":false' ]] && ok "the reminder clears pendingSave" || no "the reminder clears pendingSave (got $(pending))"
case "$JSON_OUT" in
  *'"hookEventName":"PostToolUse"'*) ok "the envelope echoes the firing event's name" ;;
  *) no "the envelope echoes the firing event's name (got: $JSON_OUT)" ;;
esac

# --- 2: cleared means quiet, not repeated -----------------------------------
[[ -z "$(hook '{"hook_event_name":"PostToolUse"}')" ]] && ok "already-saved story → silent" || no "already-saved story → silent"

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

# --- 4: a missing event name is silence -------------------------------------
arm
[[ -z "$(hook '{}')" ]] && ok "no hook_event_name → silent" || no "no hook_event_name → silent"

# --- 4b: the save point survives the notice ---------------------------------
# Clearing the flag must keep the position save-mark-saved.sh wrote
# (`claudePath`/`claudeLength`), or the next save loses it.
cat > "$STATE_DIR/WD-0001.json" <<'JSON'
{"claudePath":"/tmp/t.jsonl","claudeLength":7,"dateTime":"2026-09-29T00:00:00Z","pendingSave":true}
JSON
hook '{"hook_event_name":"PostToolUse"}' >/dev/null
case "$(cat "$STATE_DIR/WD-0001.json")" in
  *'"claudePath":"/tmp/t.jsonl","claudeLength":7'*'"pendingSave":false'*) ok "the notice keeps the saved position" ;;
  *) no "the notice keeps the saved position (got: $(cat "$STATE_DIR/WD-0001.json"))" ;;
esac
arm
hook '{"hook_event_name":"PostToolUse"}' >/dev/null
case "$(cat "$STATE_DIR/WD-0001.json")" in
  *'"claudePath":"/tmp/does-not-need-to-exist.jsonl","claudeLength":42'*) ok "an older-shape state is carried over in the save's shape" ;;
  *) no "an older-shape state is carried over (got: $(cat "$STATE_DIR/WD-0001.json"))" ;;
esac

# --- 5: no state directory at all is silence --------------------------------
rm -rf "$PROJ/.workflow-dev"
[[ -z "$(hook '{"hook_event_name":"PostToolUse"}')" ]] && ok "no state dir → silent" || no "no state dir → silent"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
exit $((fail == 0 ? 0 : 1))
