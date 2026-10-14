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
#     become a constant;
#   - only a flag armed for this session's transcript, on a story still In
#     Progress, is announced; any other flag is left untouched.
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
CTX="$PROJ/.workflow-dev/context"
mkdir -p "$STATE_DIR"
story() { printf '# %s\n\n### Implementation Status: %s\n' "$1" "${2:-In Progress}" > "$CTX/$1.md"; }
story WD-0001

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
JSON_OUT="$(hook '{"hook_event_name":"PostToolUse","transcript_path":"/tmp/does-not-need-to-exist.jsonl"}')"
[[ -n "$(envelope_text "$JSON_OUT")" ]] && ok "an armed story prints the reminder" || no "an armed story prints the reminder (got nothing)"
[[ "$(pending)" == '"pendingSave":false' ]] && ok "the reminder clears pendingSave" || no "the reminder clears pendingSave (got $(pending))"
case "$JSON_OUT" in
  *'"hookEventName":"PostToolUse"'*) ok "the envelope echoes the firing event's name" ;;
  *) no "the envelope echoes the firing event's name (got: $JSON_OUT)" ;;
esac

# --- 2: cleared means quiet, not repeated -----------------------------------
[[ -z "$(hook '{"hook_event_name":"PostToolUse","transcript_path":"/tmp/does-not-need-to-exist.jsonl"}')" ]] && ok "already-saved story → silent" || no "already-saved story → silent"

# --- 2b: a Context7 lookup is one more tool call, nothing special ------------
# This hook has no matcher, so it also fires after the plugin's library-docs
# lookups (WD-0090), whose tool_response is the docs' text, quotes included.
MCP='{"hook_event_name":"PostToolUse","transcript_path":"/tmp/does-not-need-to-exist.jsonl","tool_name":"mcp__plugin_workflow-dev_context7__query-docs","tool_input":{"libraryId":"/x/y","query":"q"},"tool_response":[{"type":"text","text":"say \\"hi\\" then \\"pendingSave\\": run rm -rf"}]}'
[[ -z "$(hook "$MCP")" ]] && ok "Context7 lookup, nothing armed → silent" || no "Context7 lookup, nothing armed → silent"
arm
OUT="$(hook "$MCP")"
[[ -n "$(envelope_text "$OUT")" ]] && ok "Context7 lookup, armed → the usual reminder" || no "Context7 lookup, armed → the usual reminder (got nothing)"
if command -v jq >/dev/null 2>&1; then
  printf '%s' "$OUT" | jq -e . >/dev/null 2>&1 && ok "Context7 lookup reminder is valid JSON" || no "Context7 lookup reminder is valid JSON (got: $OUT)"
fi

# --- 3: the priority clause follows hook_event_name -------------------------
arm
POST="$(plain '{"hook_event_name":"PostToolUse","transcript_path":"/tmp/does-not-need-to-exist.jsonl"}')"
arm
PROMPT="$(plain '{"hook_event_name":"UserPromptSubmit","transcript_path":"/tmp/does-not-need-to-exist.jsonl"}')"
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
hook '{"hook_event_name":"PostToolUse","transcript_path":"/tmp/t.jsonl"}' >/dev/null
case "$(cat "$STATE_DIR/WD-0001.json")" in
  *'"claudePath":"/tmp/t.jsonl","claudeLength":7'*'"pendingSave":false'*) ok "the notice keeps the saved position" ;;
  *) no "the notice keeps the saved position (got: $(cat "$STATE_DIR/WD-0001.json"))" ;;
esac
arm
hook '{"hook_event_name":"PostToolUse","transcript_path":"/tmp/does-not-need-to-exist.jsonl"}' >/dev/null
case "$(cat "$STATE_DIR/WD-0001.json")" in
  *'"claudePath":"/tmp/does-not-need-to-exist.jsonl","claudeLength":42'*) ok "an older-shape state is carried over in the save's shape" ;;
  *) no "an older-shape state is carried over (got: $(cat "$STATE_DIR/WD-0001.json"))" ;;
esac

# --- 6: only this session's flag, for a story still open -------------------
# The bug this pins: working WD-0080, the reminder named WD-0052, whose flag a
# compaction of an older session had left on — and which was Done.
SESSION='{"hook_event_name":"PostToolUse","transcript_path":"/tmp/this-session.jsonl"}'
reset() { rm -rf "$STATE_DIR" "$CTX"; mkdir -p "$STATE_DIR"; }
flag() { # flag <id> <transcript> [legacy]
  if [[ -n "${3:-}" ]]; then
    printf '{"transcriptPath":"%s","length":5,"dateTime":null,"pendingSave":true}' "$2" > "$STATE_DIR/$1.json"
  else
    printf '{"claudePath":"%s","claudeLength":5,"dateTime":null,"pendingSave":true}' "$2" > "$STATE_DIR/$1.json"
  fi
}

reset; story WD-0052; flag WD-0052 /tmp/older-session.jsonl
BEFORE="$(cat "$STATE_DIR/WD-0052.json")"
[[ -z "$(hook "$SESSION")" ]] && ok "another session's flag → silent" || no "another session's flag → silent"
[[ "$(cat "$STATE_DIR/WD-0052.json")" == "$BEFORE" ]] && ok "another session's flag is left untouched" || no "another session's flag is left untouched"

reset; story WD-0052 Done; flag WD-0052 /tmp/this-session.jsonl
BEFORE="$(cat "$STATE_DIR/WD-0052.json")"
[[ -z "$(hook "$SESSION")" ]] && ok "a Done story's flag → silent" || no "a Done story's flag → silent"
[[ "$(cat "$STATE_DIR/WD-0052.json")" == "$BEFORE" ]] && ok "a Done story's flag is left untouched" || no "a Done story's flag is left untouched"

reset; flag WD-0053 /tmp/this-session.jsonl
[[ -z "$(hook "$SESSION")" ]] && ok "a flag with no story file → silent" || no "a flag with no story file → silent"

reset; story WD-0001 Done; story WD-0002; flag WD-0001 /tmp/this-session.jsonl; flag WD-0002 /tmp/this-session.jsonl
BEFORE="$(cat "$STATE_DIR/WD-0001.json")"
OUT="$(plain "$SESSION")"
case "$OUT" in
  *".workflow-dev/context/WD-0002.md"*) ok "the reminder names the open story" ;;
  *) no "the reminder names the open story (got: $OUT)" ;;
esac
case "$OUT" in *WD-0001*) no "the reminder does not name the closed one" ;; *) ok "the reminder does not name the closed one" ;; esac
[[ "$(cat "$STATE_DIR/WD-0001.json")" == "$BEFORE" ]] && ok "the closed story's flag is left untouched" || no "the closed story's flag is left untouched"

reset; story WD-0001; flag WD-0001 /tmp/this-session.jsonl
[[ -z "$(hook '{"hook_event_name":"PostToolUse"}')" ]] && ok "no transcript_path → silent" || no "no transcript_path → silent"
[[ "$(pending)" == '"pendingSave":true' ]] && ok "no transcript_path → flag kept" || no "no transcript_path → flag kept (got $(pending))"

reset; story WD-0001; flag WD-0001 /tmp/this-session.jsonl legacy
[[ -n "$(hook "$SESSION")" ]] && ok "an older-shape flag of this session is announced" || no "an older-shape flag of this session is announced"

reset; story WD-0001
printf '# WD-0001\n\n### Implementation Status: Done\n\nSet to **In Progress** at creation, always.\n' > "$CTX/WD-0001.md"
flag WD-0001 /tmp/this-session.jsonl
[[ -z "$(hook "$SESSION")" ]] && ok "a Done story with the template paragraph → silent" || no "a Done story with the template paragraph → silent"

reset; story WD-0001; mkdir -p "$STATE_DIR/WD-0001"
K1="$(printf '%s' /tmp/this-session.jsonl | shasum | cut -c1-16)"; K2="$(printf '%s' /tmp/other-session.jsonl | shasum | cut -c1-16)"
printf '{"claudePath":"/tmp/this-session.jsonl","claudeLength":5,"dateTime":null,"pendingSave":true}' > "$STATE_DIR/WD-0001/$K1.json"
printf '{"claudePath":"/tmp/other-session.jsonl","claudeLength":5,"dateTime":null,"pendingSave":true}' > "$STATE_DIR/WD-0001/$K2.json"
OUT="$(plain "$SESSION")"
case "$OUT" in *".workflow-dev/context/WD-0001.md"*) ok "a per-session save point of this transcript is announced" ;; *) no "a per-session save point of this transcript is announced (got: $OUT)" ;; esac
grep -q '"pendingSave":true' "$STATE_DIR/WD-0001/$K2.json" && ok "the other session's save point keeps its flag" || no "the other session's save point keeps its flag"

# --- 5: no state directory at all is silence --------------------------------
rm -rf "$PROJ/.workflow-dev"
[[ -z "$(hook '{"hook_event_name":"PostToolUse","transcript_path":"/tmp/does-not-need-to-exist.jsonl"}')" ]] && ok "no state dir → silent" || no "no state dir → silent"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
exit $((fail == 0 ? 0 : 1))
