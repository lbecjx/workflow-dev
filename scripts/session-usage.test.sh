#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Tests for session-usage.sh — the parser at its heart (main transcript +
# per-agent side-chain files) is an input boundary, so per the coding
# standards ("every new input boundary ships its edge-case tests") it gets
# fixtures here instead of relying on a live transcript that may be purged.
# No test framework in this repo; run it directly:
#
#   bash scripts/session-usage.test.sh
#
# Exits non-zero if any assertion fails.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/session-usage.sh"
BASH_ABS="$(command -v bash)"
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

# --- Fixtures ---------------------------------------------------------------
# One side-chain file with usage. The two records share message.id "msg_S":
# the harness repeats `usage` per content block, so a correct parser must
# count it once (input 100, output 50, cache_read 1000, cache_create 200).
SIDE="$TMP/agent.output"
cat > "$SIDE" <<'JSONL'
{"type":"assistant","message":{"id":"msg_S","model":"m","usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200}},"timestamp":"2026-01-01T00:00:20.000Z"}
{"type":"assistant","message":{"id":"msg_S","model":"m","usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200}},"timestamp":"2026-01-01T00:00:21.000Z"}
JSONL

# Main transcript: message.id "msg_A" appears twice (must count once),
# "msg_B" once; plus one Agent call whose result names the side-chain file.
# Correct main totals: turns 2, input 11, output 7, cache_read 103, cache_create 24.
MAIN="$TMP/main.jsonl"
cat > "$MAIN" <<JSONL
{"type":"assistant","message":{"id":"msg_A","model":"m","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":100,"cache_creation_input_tokens":20}},"timestamp":"2026-01-01T00:00:00.000Z"}
{"type":"assistant","message":{"id":"msg_A","model":"m","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":100,"cache_creation_input_tokens":20}},"timestamp":"2026-01-01T00:00:01.000Z"}
{"type":"assistant","message":{"id":"msg_B","model":"m","usage":{"input_tokens":1,"output_tokens":2,"cache_read_input_tokens":3,"cache_creation_input_tokens":4}},"timestamp":"2026-01-01T00:00:10.000Z"}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu_1","name":"Agent","input":{"description":"Fixture agent"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu_1","content":[{"type":"text","text":"Async agent launched.\noutput_file: $SIDE"}]}]}}
JSONL

# --- 1: dedupe by message.id; main + side-chain sum; Agent label -----------
OUT="$(bash "$SCRIPT" "$MAIN")"
assert_contains "input: 111  output: 57  cache_read: 1103  cache_create: 224" "$OUT" \
  "dedupes repeated message.id and sums main + side-chain"
assert_contains "Fixture agent" "$OUT" "sub-agent labeled from its Agent description"
assert_contains "1 sub-agent(s): 1 with usage, 0 unavailable" "$OUT" "side-chain counted"

# --- 2: a present-but-nonexistent side-chain is reported, never zero --------
MAIN2="$TMP/main2.jsonl"
sed "s#$SIDE#$TMP/missing.output#" "$MAIN" > "$MAIN2"
OUT2="$(bash "$SCRIPT" "$MAIN2")"
assert_contains "1 sub-agent(s): 0 with usage, 1 unavailable" "$OUT2" \
  "missing side-chain reported unavailable"

# --- 3: a present-but-unparseable side-chain is unavailable, not blank ------
BAD="$TMP/bad.output"
printf 'not json at all\n' > "$BAD"
MAIN3="$TMP/main3.jsonl"
sed "s#$SIDE#$BAD#" "$MAIN" > "$MAIN3"
OUT3="$(bash "$SCRIPT" "$MAIN3")"
assert_contains "side-chain unreadable" "$OUT3" "unparseable side-chain reported unreadable"
assert_contains "1 sub-agent(s): 0 with usage, 1 unavailable" "$OUT3" "unparseable side-chain not counted"

# --- 4: a tool_result with no output_file token → unavailable --------------
MAIN4="$TMP/main4.jsonl"
cat > "$MAIN4" <<'JSONL'
{"type":"assistant","message":{"id":"m1","model":"m","usage":{"input_tokens":1,"output_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu_9","name":"Agent","input":{"description":"Sync-style agent"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu_9","content":[{"type":"text","text":"Fork started - processing in background"}]}]}}
JSONL
OUT4="$(bash "$SCRIPT" "$MAIN4")"
assert_contains "1 sub-agent(s): 0 with usage, 1 unavailable" "$OUT4" \
  "absent output_file reported unavailable"

# --- 5: an explicit bad path errors, never silently uses another session ----
bash "$SCRIPT" "$TMP/nope.jsonl" >/dev/null 2>"$TMP/err"
[[ $? -eq 1 ]] && assert_contains "Not a file" "$(cat "$TMP/err")" "explicit bad path exits 1 with a message" \
              || no "explicit bad path exits 1 with a message"

# --- 6: no source resolvable → graceful message, exit 0 ---------------------
mkdir -p "$TMP/empty" "$TMP/nohome"
( cd "$TMP/empty" && HOME="$TMP/nohome" bash "$SCRIPT" >/dev/null 2>"$TMP/err2" )
rc=$?
[[ $rc -eq 0 ]] && assert_contains "No usage source found" "$(cat "$TMP/err2")" "no source → exit 0 with message" \
              || no "no source → exit 0 with message"

# --- 6b: OpenCode backend — parent + child session, cost/tokens/wall ---------
mkdir -p "$TMP/proj"
PROJDIR="$(cd "$TMP/proj" && pwd -P)"
DBF="$TMP/fixture.db"
sqlite3 "$DBF" <<SQL
CREATE TABLE session_v2 (id text primary key, parent_id text, directory text, title text,
  agent text, model text, cost real, tokens_input integer, tokens_output integer,
  tokens_reasoning integer, tokens_cache_read integer, tokens_cache_write integer,
  time_created integer, time_updated integer);
CREATE TABLE session_message (session_id text, time_created integer);
INSERT INTO session_v2 VALUES ('ses_parent',NULL,'$PROJDIR','Main run','build','{"id":"m1"}',1.5,100,10,5,1000,0,0,100);
INSERT INTO session_v2 VALUES ('ses_child1','ses_parent','$PROJDIR','Sub A','general','{"id":"m1"}',0.5,50,5,2,500,0,0,999);
INSERT INTO session_message VALUES ('ses_parent',0),('ses_parent',10000),('ses_child1',0),('ses_child1',30000);
SQL
OUT6=$( cd "$TMP/proj" && HOME="$TMP/nohome" OPENCODE_DB="$DBF" bash "$SCRIPT" 2>/dev/null )
assert_contains "Workflow usage (OpenCode)" "$OUT6" "OpenCode backend selected"
assert_contains "Session: ses_parent" "$OUT6" "OpenCode resolves the top-level session, not a newer child"
assert_contains "Sub A" "$OUT6" "child session listed as sub-agent"
assert_contains "input: 150  output: 15  reasoning: 7  cache_read: 1500" "$OUT6" "OpenCode grand total sums parent + child"
assert_contains "cost: \$2.0000" "$OUT6" "OpenCode grand total includes cost"

# --- 6c: --sessions sums an explicit set (per-story attribution) -----------
OUT7=$( cd "$TMP/proj" && OPENCODE_DB="$DBF" bash "$SCRIPT" --sessions ses_parent,ses_child1 2>/dev/null )
assert_contains "2.0000" "$OUT7" "--sessions sums the explicit session list"
assert_contains "ses_bogus" "$( cd "$TMP/proj" && OPENCODE_DB="$DBF" bash "$SCRIPT" --sessions ses_parent,ses_bogus 2>/dev/null )" "--sessions reports unknown ids"

# --- 6d: --transcripts sums an explicit set (Claude per-story attribution) --
printf '{"type":"assistant","message":{"id":"a1","usage":{"input_tokens":10,"output_tokens":1,"cache_read_input_tokens":100,"cache_creation_input_tokens":0}}}\n' > "$TMP/tx1.jsonl"
printf '{"type":"assistant","message":{"id":"a2","usage":{"input_tokens":20,"output_tokens":2,"cache_read_input_tokens":200,"cache_creation_input_tokens":0}}}\n' > "$TMP/tx2.jsonl"
OUT8=$(bash "$SCRIPT" --transcripts "$TMP/tx1.jsonl,$TMP/tx2.jsonl")
TOT8=$(printf '%s' "$OUT8" | grep TOTAL)
assert_contains "300" "$TOT8" "--transcripts sums cache_read across transcripts"
assert_contains "30" "$TOT8" "--transcripts sums input across transcripts"

# --- 6e: an explicit --transcripts wins over a resolvable Claude transcript ---
# The 2-assert failure this story fixes: from the project root (inside a live
# session) a transcript resolves, and the old order ran claude_report and exited
# before --transcripts was read. Make that resolution happen on purpose and pin
# that the explicit selector is still the source.
PROJP="$TMP/projp"; FAKEHOME="$TMP/fakehome"
mkdir -p "$PROJP" "$FAKEHOME"
SLUG="$( cd "$PROJP" && pwd -P | sed 's#/#-#g' )"
mkdir -p "$FAKEHOME/.claude/projects/$SLUG"
printf '{"type":"assistant","message":{"id":"fake1","model":"m","usage":{"input_tokens":999,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' \
  > "$FAKEHOME/.claude/projects/$SLUG/fake.jsonl"
# Default (no selector): the implicit resolution does find it...
OUTD=$( cd "$PROJP" && HOME="$FAKEHOME" bash "$SCRIPT" 2>/dev/null )
assert_contains "input: 999" "$OUTD" "implicit resolution finds a resolvable transcript"
# ...and the explicit selector still wins, ignoring the transcript.
OUTE=$( cd "$PROJP" && HOME="$FAKEHOME" bash "$SCRIPT" --transcripts "$TMP/tx1.jsonl,$TMP/tx2.jsonl" )
TOTE=$(printf '%s' "$OUTE" | grep TOTAL)
assert_contains "300" "$TOTE" "--transcripts wins over a resolvable transcript (cache_read)"
assert_contains "30" "$TOTE" "--transcripts wins over a resolvable transcript (input)"
# The other two explicit selectors take the same precedence (the --session
# branch is reached for the first time here; before the reorder it was dead
# whenever a transcript resolved).
OUTS=$( cd "$PROJP" && HOME="$FAKEHOME" OPENCODE_DB="$DBF" bash "$SCRIPT" --sessions ses_parent,ses_child1 )
assert_contains "explicit sessions" "$OUTS" "--sessions wins over a resolvable transcript"
OUTSS=$( cd "$PROJP" && HOME="$FAKEHOME" OPENCODE_DB="$DBF" bash "$SCRIPT" --session ses_parent )
assert_contains "Session: ses_parent" "$OUTSS" "--session wins over a resolvable transcript"

# --- 7: jq missing → clear failure, not a wrong number ----------------------
# Empty PATH that still runs bash by absolute path: the jq guard fires before
# any other external tool, so this is portable (unlike assuming /bin has no jq).
mkdir -p "$TMP/emptybin"
env PATH="$TMP/emptybin" "$BASH_ABS" "$SCRIPT" "$MAIN" >/dev/null 2>&1
[[ $? -eq 1 ]] && ok "exits 1 when jq is missing" || no "exits 1 when jq is missing"

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
