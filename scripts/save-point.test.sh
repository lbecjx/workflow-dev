#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Tests for the save point: the Claude Code transcript the hooks recorded plus
# a line count into it. Also pinned (WD-0026): state and pending files written
# by an older version — with `current`, `opencodeSession`, `opencodeSeq`, or a
# pending `"harness":"opencode"` — degrade to the Claude Code path or to
# "nothing to extract", never an error or a wrong position.
# Run directly: bash scripts/save-point.test.sh

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
READ="$HERE/save-read-unsaved.sh"
MARK="$HERE/save-mark-saved.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok() { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }
assert_contains() { case "$2" in *"$1"*) ok "$3" ;; *) no "$3 (missing: $1)" ;; esac; }
assert_absent()   { case "$2" in *"$1"*) no "$3 (unexpected: $1)" ;; *) ok "$3" ;; esac; }
assert_valid_json() { # $1 content, $2 label
  if printf '%s' "$1" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then ok "$2"; else no "$2"; fi
}

STORY="TEST-1"
STATE_OF() { cat "$1/.workflow-dev/context/.compaction-state/$STORY.json"; }
PENDING_OF() { cat "$1/.workflow-dev/context/.compaction-state/.pending-save-$STORY" 2>/dev/null; }

# ---------------------------------------------------------------------------
# Transcript + line-count save point (the old `transcriptPath`/`length` shape)
# ---------------------------------------------------------------------------
PROJ="$TMP/claude"; mkdir -p "$PROJ/.workflow-dev/context/.compaction-state"
TRANSCRIPT="$TMP/transcript.jsonl"
printf '{"n":1}\n{"n":2}\n{"n":3}\n' > "$TRANSCRIPT"
printf '{"transcriptPath":"%s","length":1}' "$TRANSCRIPT" > "$PROJ/.workflow-dev/context/.compaction-state/$STORY.json"

OUT=$( cd "$PROJ" && bash "$READ" "$STORY" )
assert_contains '{"n":2}' "$OUT" "reads only after the saved line"
assert_absent '{"n":1}' "$OUT" "must not re-read the saved line"
assert_contains '"length":3' "$(PENDING_OF "$PROJ")" "the pending marker carries the position"
assert_absent 'harness' "$(PENDING_OF "$PROJ")" "the pending marker carries no source name"
( cd "$PROJ" && bash "$MARK" "$STORY" >/dev/null )
ST=$(STATE_OF "$PROJ")
assert_contains '"claudeLength":3' "$ST" "mark advances the line count"
assert_contains "\"claudePath\":\"$TRANSCRIPT\"" "$ST" "mark keeps the transcript path"
assert_valid_json "$ST" "state is valid JSON"
assert_contains "Nothing unsaved" "$( cd "$PROJ" && bash "$READ" "$STORY" )" "nothing unsaved after marking"

# The save point does not depend on the environment it runs under.
printf '{"n":4}\n' >> "$TRANSCRIPT"
OUTSIDE=$( cd "$PROJ" && env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT bash "$READ" "$STORY" )
assert_contains '{"n":4}' "$OUTSIDE" "reads the transcript without a Claude Code signal in the env"

# ---------------------------------------------------------------------------
# Digest: readable lines, tool payloads/reasoning stripped
# ---------------------------------------------------------------------------
PROJ5="$TMP/digest"; mkdir -p "$PROJ5/.workflow-dev/context/.compaction-state"
DIG="$TMP/digest.jsonl"
cat > "$DIG" <<'JSONL'
{"type":"user","message":{"role":"user","content":"hello there"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"the answer"},{"type":"tool_use","name":"Bash","input":{"command":"SECRET_TOOL_PAYLOAD"}}]}}
JSONL
printf '{"claudePath":"%s","claudeLength":0}' "$DIG" \
  > "$PROJ5/.workflow-dev/context/.compaction-state/$STORY.json"
DGOUT=$( cd "$PROJ5" && bash "$READ" --digest "$STORY" )
assert_contains "[user] hello there" "$DGOUT" "digest: user text"
assert_contains "[assistant] the answer" "$DGOUT" "digest: assistant text"
assert_absent "SECRET_TOOL_PAYLOAD" "$DGOUT" "digest: tool payload stripped"
assert_contains "SECRET_TOOL_PAYLOAD" "$( cd "$PROJ5" && bash "$READ" --raw "$STORY" )" "raw: tool payload present"

# ---------------------------------------------------------------------------
# No source at all → honest message
# ---------------------------------------------------------------------------
PROJ4="$TMP/none"; mkdir -p "$PROJ4"
OUT6=$( cd "$PROJ4" && bash "$READ" "$STORY" )
assert_contains "No Claude Code transcript known" "$OUT6" "no source → honest message"

# ---------------------------------------------------------------------------
# Legacy state: written while a second source was supported (WD-0026)
# ---------------------------------------------------------------------------
# Only the other source was ever recorded → nothing to extract, not an error.
PROJ6="$TMP/legacy-oc"; mkdir -p "$PROJ6/.workflow-dev/context/.compaction-state"
printf '{"current":"opencode","claudePath":"","claudeLength":0,"opencodeSession":"ses_old","opencodeSeq":3,"dateTime":"2026-09-27T08:33:52Z","pendingSave":false}' \
  > "$PROJ6/.workflow-dev/context/.compaction-state/$STORY.json"
L1=$( cd "$PROJ6" && bash "$READ" "$STORY" ); rc=$?
[[ $rc -eq 0 ]] && ok "legacy other-source state: exit 0" || no "legacy other-source state: exit 0 (got $rc)"
assert_contains "No Claude Code transcript known" "$L1" "legacy other-source state → nothing to extract"
[[ -z "$(PENDING_OF "$PROJ6")" ]] && ok "legacy other-source state → no pending marker" || no "legacy other-source state → no pending marker"

# Both positions recorded, `current` naming the other source → the Claude Code
# position is used, and the next save drops the legacy keys.
PROJ7="$TMP/legacy-both"; mkdir -p "$PROJ7/.workflow-dev/context/.compaction-state"
T7="$TMP/legacy-both.jsonl"; printf '{"b":1}\n{"b":2}\n{"b":3}\n' > "$T7"
printf '{"current":"opencode","claudePath":"%s","claudeLength":2,"opencodeSession":"ses_x","opencodeSeq":40,"dateTime":"2026-09-27T08:33:52Z","pendingSave":true}' "$T7" \
  > "$PROJ7/.workflow-dev/context/.compaction-state/$STORY.json"
L2=$( cd "$PROJ7" && bash "$READ" "$STORY" )
assert_contains '{"b":3}' "$L2" "legacy both-sources state → reads past the Claude Code position"
assert_absent '{"b":2}' "$L2" "legacy both-sources state → does not re-read saved lines"
( cd "$PROJ7" && bash "$MARK" "$STORY" >/dev/null )
ST7=$(STATE_OF "$PROJ7")
assert_contains '"claudeLength":3' "$ST7" "legacy both-sources state → mark advances the Claude Code position"
assert_absent 'opencode' "$ST7" "legacy keys are dropped on the next save"
assert_absent '"current"' "$ST7" "the legacy current marker is dropped"
assert_valid_json "$ST7" "legacy both-sources state → rewritten state is valid JSON"

# A pending marker left for the other source → nothing marked, state untouched.
PROJ8="$TMP/legacy-pending"; mkdir -p "$PROJ8/.workflow-dev/context/.compaction-state"
T8="$TMP/legacy-pending.jsonl"; printf '{"p":1}\n' > "$T8"
printf '{"claudePath":"%s","claudeLength":1,"dateTime":"2026-10-01T00:00:00Z","pendingSave":false}' "$T8" \
  > "$PROJ8/.workflow-dev/context/.compaction-state/$STORY.json"
BEFORE8=$(STATE_OF "$PROJ8")
printf '{"harness":"opencode","sessionId":"ses_x","seq":41}' > "$PROJ8/.workflow-dev/context/.compaction-state/.pending-save-$STORY"
M8=$( cd "$PROJ8" && bash "$MARK" "$STORY" 2>&1 ); rc=$?
[[ $rc -eq 0 ]] && ok "legacy other-source pending: exit 0" || no "legacy other-source pending: exit 0 (got $rc)"
assert_contains "carries no transcript position" "$M8" "legacy other-source pending → says nothing was marked"
[[ "$(STATE_OF "$PROJ8")" == "$BEFORE8" ]] && ok "legacy other-source pending → state untouched" || no "legacy other-source pending → state untouched (got: $(STATE_OF "$PROJ8"))"

# A pending marker in the older Claude Code shape (with `harness`) still marks.
printf '{"harness":"claude","length":1}' > "$PROJ8/.workflow-dev/context/.compaction-state/.pending-save-$STORY"
( cd "$PROJ8" && bash "$MARK" "$STORY" >/dev/null )
assert_contains '"claudeLength":1' "$(STATE_OF "$PROJ8")" "older Claude Code pending shape still marks"
[[ -z "$(PENDING_OF "$PROJ8")" ]] && ok "a marked pending file is removed" || no "a marked pending file is removed"

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
