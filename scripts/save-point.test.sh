#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Tests for the source-aware save point (WD-0007 AC 13): Claude Code
# (transcript + line count) and OpenCode (session + message seq), including
# switching between them, which must preserve the other source's position.
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
as_claude()   { env -u OPENCODE_TERMINAL -u OPENCODE CLAUDECODE=1 bash "$@"; }
as_opencode() { env -u CLAUDECODE OPENCODE_TERMINAL=1 OPENCODE_DB="$DBF" bash "$@"; }
as_opencode_db() { local db="$1"; shift; env -u CLAUDECODE OPENCODE_TERMINAL=1 OPENCODE_DB="$db" bash "$@"; }
STATE_OF() { cat "$1/.workflow-dev/context/.compaction-state/$STORY.json"; }

# ---------------------------------------------------------------------------
# Claude Code: transcript + line-count save point
# ---------------------------------------------------------------------------
PROJ="$TMP/claude"; mkdir -p "$PROJ/.workflow-dev/context/.compaction-state"
TRANSCRIPT="$TMP/transcript.jsonl"
printf '{"n":1}\n{"n":2}\n{"n":3}\n' > "$TRANSCRIPT"
printf '{"transcriptPath":"%s","length":1}' "$TRANSCRIPT" > "$PROJ/.workflow-dev/context/.compaction-state/$STORY.json"

OUT=$( cd "$PROJ" && as_claude "$READ" "$STORY" )
assert_contains '{"n":2}' "$OUT" "claude: reads only after the saved line"
assert_absent '{"n":1}' "$OUT" "claude: must not re-read the saved line"
( cd "$PROJ" && as_claude "$MARK" "$STORY" >/dev/null )
assert_contains '"claudeLength":3' "$(STATE_OF "$PROJ")" "claude: mark advances the line count"
assert_valid_json "$(STATE_OF "$PROJ")" "claude: state is valid JSON"
assert_contains "Nothing unsaved" "$( cd "$PROJ" && as_claude "$READ" "$STORY" )" "claude: nothing unsaved after marking"

# ---------------------------------------------------------------------------
# OpenCode: session + message-seq save point
# ---------------------------------------------------------------------------
PROJ2="$TMP/oc"; mkdir -p "$PROJ2/.workflow-dev/context"
PROJDIR="$(cd "$PROJ2" && pwd -P)"
DBF="$TMP/oc.db"
sqlite3 "$DBF" <<SQL
CREATE TABLE session_v2 (id text, parent_id text, directory text, time_updated integer);
CREATE TABLE session_message (session_id text, seq integer, type text, data text);
INSERT INTO session_v2 VALUES ('ses_x',NULL,'$PROJDIR',100);
INSERT INTO session_v2 VALUES ('ses_child','ses_x','$PROJDIR',999);
INSERT INTO session_message VALUES ('ses_x',1,'user','{"m":1}');
INSERT INTO session_message VALUES ('ses_x',2,'assistant','{"m":2}');
INSERT INTO session_message VALUES ('ses_x',3,'assistant','{"m":3}');
SQL

OUT3=$( cd "$PROJ2" && as_opencode "$READ" "$STORY" )
assert_contains "OpenCode session ses_x" "$OUT3" "opencode: resolves the top-level session, not a newer child"
assert_contains '{"m":1}' "$OUT3" "opencode: reads the messages"
( cd "$PROJ2" && as_opencode "$MARK" "$STORY" >/dev/null )
ST=$(STATE_OF "$PROJ2")
assert_contains '"opencodeSession":"ses_x"' "$ST" "opencode: state stores the session id"
assert_contains '"opencodeSeq":3' "$ST" "opencode: mark advances the seq"
assert_valid_json "$ST" "opencode: state is valid JSON"
assert_contains "Nothing unsaved" "$( cd "$PROJ2" && as_opencode "$READ" "$STORY" )" "opencode: nothing unsaved after marking"
sqlite3 "$DBF" "INSERT INTO session_message VALUES ('ses_x',4,'assistant','{\"m\":4}');"
OUT5=$( cd "$PROJ2" && as_opencode "$READ" "$STORY" )
assert_contains '{"m":4}' "$OUT5" "opencode: reads only messages after the save point"
assert_absent '{"m":1}' "$OUT5" "opencode: must not re-read earlier messages"

# ---------------------------------------------------------------------------
# Switching Claude → OpenCode preserves the Claude position
# ---------------------------------------------------------------------------
PROJ3="$TMP/switch"; mkdir -p "$PROJ3/.workflow-dev/context/.compaction-state"
cp "$TRANSCRIPT" "$TMP/switch.jsonl"
PROJDIR3="$(cd "$PROJ3" && pwd -P)"
DBF3="$TMP/switch.db"
sqlite3 "$DBF3" <<SQL
CREATE TABLE session_v2 (id text, parent_id text, directory text, time_updated integer);
CREATE TABLE session_message (session_id text, seq integer, type text, data text);
INSERT INTO session_v2 VALUES ('ses_sw',NULL,'$PROJDIR3',100);
INSERT INTO session_message VALUES ('ses_sw',1,'user','{"s":1}');
INSERT INTO session_message VALUES ('ses_sw',2,'assistant','{"s":2}');
INSERT INTO session_message VALUES ('ses_sw',3,'assistant','{"s":3}');
SQL
# a story already saved in Claude Code (line 3 of 3, i.e. fully caught up)
printf '{"current":"claude","claudePath":"%s","claudeLength":3,"opencodeSession":"","opencodeSeq":0}' \
  "$TMP/switch.jsonl" > "$PROJ3/.workflow-dev/context/.compaction-state/$STORY.json"
# continue it in OpenCode: a new source, read from 0, then marked
SW=$( cd "$PROJ3" && as_opencode_db "$DBF3" "$READ" "$STORY" )
assert_contains "OpenCode session ses_sw" "$SW" "switch: OpenCode reads the new source"
( cd "$PROJ3" && as_opencode_db "$DBF3" "$MARK" "$STORY" >/dev/null )
ST3=$(STATE_OF "$PROJ3")
assert_contains '"claudeLength":3' "$ST3" "switch: the Claude position is preserved"
assert_contains '"opencodeSeq":3' "$ST3" "switch: the OpenCode position is advanced"
# back in Claude Code: still caught up — the position survived
assert_contains "Nothing unsaved" "$( cd "$PROJ3" && as_claude "$READ" "$STORY" )" "switch: back in Claude, position preserved"

# ---------------------------------------------------------------------------
# Digest: readable lines, tool payloads/reasoning stripped
# ---------------------------------------------------------------------------
PROJ5="$TMP/digest"; mkdir -p "$PROJ5/.workflow-dev/context/.compaction-state"
DIG="$TMP/digest.jsonl"
cat > "$DIG" <<'JSONL'
{"type":"user","message":{"role":"user","content":"hello there"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"the answer"},{"type":"tool_use","name":"Bash","input":{"command":"SECRET_TOOL_PAYLOAD"}}]}}
JSONL
printf '{"current":"claude","claudePath":"%s","claudeLength":0,"opencodeSession":"","opencodeSeq":0}' "$DIG" \
  > "$PROJ5/.workflow-dev/context/.compaction-state/$STORY.json"
DGOUT=$( cd "$PROJ5" && as_claude "$READ" --digest "$STORY" )
assert_contains "[user] hello there" "$DGOUT" "digest: user text"
assert_contains "[assistant] the answer" "$DGOUT" "digest: assistant text"
assert_absent "SECRET_TOOL_PAYLOAD" "$DGOUT" "digest: tool payload stripped"
assert_contains "SECRET_TOOL_PAYLOAD" "$( cd "$PROJ5" && as_claude "$READ" --raw "$STORY" )" "raw: tool payload present"

# ---------------------------------------------------------------------------
# No source at all → honest message
# ---------------------------------------------------------------------------
PROJ4="$TMP/none"; mkdir -p "$PROJ4"
OUT6=$( cd "$PROJ4" && env -u OPENCODE_TERMINAL CLAUDECODE=1 OPENCODE_DB="$TMP/missing.db" bash "$READ" "$STORY" )
assert_contains "No Claude Code transcript known" "$OUT6" "no source → honest message"

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
