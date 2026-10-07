#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code and OpenCode
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
# Unset OPENCODE_SESSION_ID (and the Claude signals) so the running session's own
# environment can't leak a session id into the reader; tests that need an
# explicit id set it themselves.
as_claude()   { env -u OPENCODE_TERMINAL -u OPENCODE -u OPENCODE_SESSION_ID CLAUDECODE=1 bash "$@"; }
as_opencode() { env -u CLAUDECODE -u OPENCODE_SESSION_ID OPENCODE_TERMINAL=1 OPENCODE_DB="$DBF" bash "$@"; }
as_opencode_db() { local db="$1"; shift; env -u CLAUDECODE -u OPENCODE_SESSION_ID OPENCODE_TERMINAL=1 OPENCODE_DB="$db" bash "$@"; }
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
OUT6=$( cd "$PROJ4" && env -u OPENCODE_TERMINAL -u OPENCODE CLAUDECODE=1 OPENCODE_DB="$TMP/missing.db" bash "$READ" "$STORY" )
assert_contains "No Claude Code transcript known" "$OUT6" "no source → honest message"

# ---------------------------------------------------------------------------
# A story continued in a NEW OpenCode session reads the new one, not the old
# (the defect this story fixes: the stored id used to be returned verbatim)
# ---------------------------------------------------------------------------
PROJ6="$TMP/newsession"; mkdir -p "$PROJ6/.workflow-dev/context/.compaction-state"
D6="$(cd "$PROJ6" && pwd -P)"
DBF6="$TMP/newsession.db"
sqlite3 "$DBF6" <<SQL
CREATE TABLE session_v2 (id text, parent_id text, directory text, time_updated integer);
CREATE TABLE session_message (session_id text, seq integer, type text, data text);
INSERT INTO session_v2 VALUES ('ses_old',NULL,'$D6',100);
INSERT INTO session_v2 VALUES ('ses_new',NULL,'$D6',200);
INSERT INTO session_message VALUES ('ses_old',1,'user','{"old":1}');
INSERT INTO session_message VALUES ('ses_old',2,'assistant','{"old":2}');
INSERT INTO session_message VALUES ('ses_old',3,'assistant','{"old":3}');
INSERT INTO session_message VALUES ('ses_new',1,'user','{"new":1}');
INSERT INTO session_message VALUES ('ses_new',2,'assistant','{"new":2}');
SQL
printf '{"current":"opencode","opencodeSession":"ses_old","opencodeSeq":3,"claudePath":"","claudeLength":0}' \
  > "$PROJ6/.workflow-dev/context/.compaction-state/$STORY.json"

NS=$( cd "$PROJ6" && as_opencode_db "$DBF6" "$READ" "$STORY" )
assert_contains "OpenCode session ses_new" "$NS" "new session: the current session is read, not the stored one"
assert_contains '{"new":1}' "$NS" "new session: its messages are read from the start"
assert_absent '{"old":1}' "$NS" "new session: the old session's messages are not re-read"
( cd "$PROJ6" && as_opencode_db "$DBF6" "$MARK" "$STORY" >/dev/null )
assert_contains '"opencodeSession":"ses_new"' "$(STATE_OF "$PROJ6")" "new session: the state advances to it"
assert_contains '"opencodeSeq":2' "$(STATE_OF "$PROJ6")" "new session: ...through its last message"

# ---------------------------------------------------------------------------
# OpenCode's own session id (OPENCODE_SESSION_ID) is preferred over "newest",
# and a value naming no real session is never trusted
# ---------------------------------------------------------------------------
STATE6="$PROJ6/.workflow-dev/context/.compaction-state/$STORY.json"
# Even though ses_new is newest, the harness-supplied id wins...
PICK=$( cd "$PROJ6" && env -u CLAUDECODE OPENCODE_TERMINAL=1 OPENCODE_DB="$DBF6" OPENCODE_SESSION_ID="ses_old" bash "$READ" "$STORY" )
assert_contains "OpenCode session ses_old" "$PICK" "OPENCODE_SESSION_ID is preferred over the newest session"

# ...and one that names no real session falls back rather than being trusted.
printf '{"current":"opencode","opencodeSession":"","opencodeSeq":0}' > "$STATE6"
MISS=$( cd "$PROJ6" && env -u CLAUDECODE OPENCODE_TERMINAL=1 OPENCODE_DB="$DBF6" OPENCODE_SESSION_ID="ses_ghost" bash "$READ" "$STORY" )
assert_contains "OpenCode session ses_new" "$MISS" "an id naming no real session falls back to the newest"

# A real session in a *different* directory is not this project's current
# session, so it is not trusted either.
sqlite3 "$DBF6" "INSERT INTO session_v2 VALUES ('ses_foreign',NULL,'/some/other/dir',999);
INSERT INTO session_message VALUES ('ses_foreign',1,'user','{\"foreign\":1}');"
printf '{"current":"opencode","opencodeSession":"","opencodeSeq":0}' > "$STATE6"
FOREIGN=$( cd "$PROJ6" && env -u CLAUDECODE OPENCODE_TERMINAL=1 OPENCODE_DB="$DBF6" OPENCODE_SESSION_ID="ses_foreign" bash "$READ" "$STORY" )
assert_contains "OpenCode session ses_new" "$FOREIGN" "a session from another directory is not trusted as the current one"
assert_absent '{"foreign":1}' "$FOREIGN" "a foreign session's messages are never read"

# With no harness id, the newest top-level session wins — so a story continued
# in a new session is detected, not bound back to the one it last saved in.
printf '{"current":"opencode","opencodeSession":"ses_old","opencodeSeq":3}' > "$STATE6"
NEWEST=$( cd "$PROJ6" && as_opencode_db "$DBF6" "$READ" "$STORY" )
assert_contains "OpenCode session ses_new" "$NEWEST" "no harness id → the newest session, not the stored one"
assert_absent '{"old":1}' "$NEWEST" "no harness id → the old session's messages are not read"

# A stored directory spelled with a trailing slash still matches this directory.
sqlite3 "$DBF6" "INSERT INTO session_v2 VALUES ('ses_slash',NULL,'$D6/',300);
INSERT INTO session_message VALUES ('ses_slash',1,'user','{\"slash\":1}');"
printf '{"current":"opencode","opencodeSession":"","opencodeSeq":0}' > "$STATE6"
SLASH=$( cd "$PROJ6" && as_opencode_db "$DBF6" "$READ" "$STORY" )
assert_contains "OpenCode session ses_slash" "$SLASH" "a directory with a trailing slash still matches"

# ---------------------------------------------------------------------------
# No usable position is stated plainly — never a false "nothing unsaved"
# ---------------------------------------------------------------------------
PROJ7="$TMP/nosession"; mkdir -p "$PROJ7/.workflow-dev/context/.compaction-state"
DBF7="$TMP/nosession.db"
sqlite3 "$DBF7" <<SQL
CREATE TABLE session_v2 (id text, parent_id text, directory text, time_updated integer);
CREATE TABLE session_message (session_id text, seq integer, type text, data text);
INSERT INTO session_v2 VALUES ('ses_other',NULL,'/some/other/dir',100);
INSERT INTO session_message VALUES ('ses_other',1,'user','{"other":1}');
SQL
printf '{"current":"opencode","opencodeSession":"ses_old","opencodeSeq":3}' \
  > "$PROJ7/.workflow-dev/context/.compaction-state/$STORY.json"
NOSE=$( cd "$PROJ7" && as_opencode_db "$DBF7" "$READ" "$STORY" )
assert_contains "OpenCode save point unavailable" "$NOSE" "no session for this dir → says the save point is unavailable"
assert_absent "Nothing unsaved" "$NOSE" "no session → never claims nothing is unsaved"
assert_absent '{"other":1}' "$NOSE" "no session → does not borrow another directory's session"

NOST=$( cd "$PROJ7" && env -u CLAUDECODE OPENCODE_TERMINAL=1 OPENCODE_DB="$TMP/missing-oc.db" bash "$READ" "$STORY" )
assert_contains "OpenCode save point unavailable" "$NOST" "a missing store → says the save point is unavailable"
assert_absent "Nothing unsaved" "$NOST" "a missing store → never claims nothing is unsaved"

# A PATH with no sqlite3 at all is the same honesty (the `have_sqlite3` branch).
NOBIN="$TMP/nobin"; mkdir -p "$NOBIN"
for c in grep sed tr cat wc cut head date git dirname; do
  p=$(command -v "$c" 2>/dev/null) && ln -sf "$p" "$NOBIN/$c"
done
NO_SQLITE=$( cd "$PROJ7" && env -u CLAUDECODE PATH="$NOBIN" OPENCODE_TERMINAL=1 OPENCODE_DB="$DBF7" /bin/bash "$READ" "$STORY" )
assert_contains "OpenCode save point unavailable" "$NO_SQLITE" "no sqlite3 → says the save point is unavailable"
assert_absent "Nothing unsaved" "$NO_SQLITE" "no sqlite3 → never claims nothing is unsaved"

# An existing file that is not an OpenCode store names the real reason, and the
# raw sqlite error is not leaked.
printf 'this is not a database' > "$TMP/garbage.db"
GARBAGE=$( cd "$PROJ7" && as_opencode_db "$TMP/garbage.db" "$READ" "$STORY" 2>&1 )
assert_contains "not a readable OpenCode store" "$GARBAGE" "an unreadable store names the real reason"
assert_absent "Nothing unsaved" "$GARBAGE" "an unreadable store → never claims nothing is unsaved"
assert_absent "Parse error" "$GARBAGE" "an unreadable store → no raw sqlite error leaks"

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
