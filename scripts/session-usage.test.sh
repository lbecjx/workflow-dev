#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code and OpenCode
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
OUT6=$( cd "$TMP/proj" && HOME="$TMP/nohome" OPENCODE_DB="$DBF" OPENCODE_SESSION_ID= bash "$SCRIPT" 2>/dev/null )
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

# --- 6f: a stale tracked .compaction-state path must not shadow this run -----
# The WD-0035 defect: resolve_claude preferred a tracked transcriptPath even
# when it belonged to a finished run, so the report showed a fixed total while
# the actual run grew. A stale tracked path now loses to the fresh transcript.
PROJT="$TMP/tracked"; FAKEHT="$TMP/fakehome-tracked"
mkdir -p "$PROJT/.workflow-dev/context/.compaction-state" "$FAKEHT"
SLUGT="$( cd "$PROJT" && pwd -P | sed 's#/#-#g' )"
mkdir -p "$FAKEHT/.claude/projects/$SLUGT"
TRACKED_OLD="$FAKEHT/.claude/projects/$SLUGT/old.jsonl"
printf '{"type":"assistant","message":{"id":"old","model":"m","usage":{"input_tokens":111,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' > "$TRACKED_OLD"
touch -t 202001010000 "$TRACKED_OLD"
NEW_RUN="$FAKEHT/.claude/projects/$SLUGT/new.jsonl"
printf '{"type":"assistant","message":{"id":"new","model":"m","usage":{"input_tokens":222,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' > "$NEW_RUN"
printf '{"transcriptPath":"%s","length":0}\n' "$TRACKED_OLD" > "$PROJT/.workflow-dev/context/.compaction-state/WD-T.json"
OUT_T=$( cd "$PROJT" && HOME="$FAKEHT" OPENCODE_DB="$TMP/none.db" bash "$SCRIPT" 2>/dev/null )
assert_contains "input: 222" "$OUT_T" "stale tracked transcriptPath does not shadow the current run"

# --- 6f2: freshness is not identity — a fresh path a just-ended run left -----
# behind still loses to the newer, current transcript.
TRACKED_ENDED="$TMP/elsewhere/ended.jsonl"
mkdir -p "$TMP/elsewhere"
printf '{"type":"assistant","message":{"id":"ended","model":"m","usage":{"input_tokens":111,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' > "$TRACKED_ENDED"
printf '{"transcriptPath":"%s","length":0}\n' "$TRACKED_ENDED" > "$PROJT/.workflow-dev/context/.compaction-state/WD-T.json"
# The current run's transcript is written after it, so it is the newer file.
printf '{"type":"assistant","message":{"id":"new","model":"m","usage":{"input_tokens":222,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' > "$NEW_RUN"
OUT_T2=$( cd "$PROJT" && HOME="$FAKEHT" OPENCODE_DB="$TMP/none.db" bash "$SCRIPT" 2>/dev/null )
assert_contains "input: 222" "$OUT_T2" "a fresh-but-ended tracked path does not win over the newer transcript"

# --- 6g: with no fresh project transcript, a fresh tracked path is the pin ---
rm -f "$FAKEHT/.claude/projects/$SLUGT/"*.jsonl
mkdir -p "$TMP/elsewhere"
TRACKED_FRESH="$TMP/elsewhere/pinned.jsonl"
printf '{"type":"assistant","message":{"id":"pin","model":"m","usage":{"input_tokens":333,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' > "$TRACKED_FRESH"
printf '{"transcriptPath":"%s","length":0}\n' "$TRACKED_FRESH" > "$PROJT/.workflow-dev/context/.compaction-state/WD-T.json"
OUT_P=$( cd "$PROJT" && HOME="$FAKEHT" OPENCODE_DB="$TMP/none.db" bash "$SCRIPT" 2>/dev/null )
assert_contains "input: 333" "$OUT_P" "a fresh tracked transcriptPath is used when the project has none"

# --- 6h: a stale tracked path with nothing fresh is refused, not reported ----
PROJR="$TMP/refuse"; FAKEHR="$TMP/fakehome-refuse"
mkdir -p "$PROJR/.workflow-dev/context/.compaction-state" "$FAKEHR"
STALE_R="$FAKEHR/old.jsonl"
printf '{"type":"assistant","message":{"id":"old","model":"m","usage":{"input_tokens":444,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' > "$STALE_R"
touch -t 202001010000 "$STALE_R"
printf '{"transcriptPath":"%s","length":0}\n' "$STALE_R" > "$PROJR/.workflow-dev/context/.compaction-state/WD-T.json"
OUT_R=$( cd "$PROJR" && HOME="$FAKEHR" OPENCODE_DB="$TMP/none.db" bash "$SCRIPT" 2>&1 )
assert_contains "No usage source found" "$OUT_R" "a stale tracked path with no fresh transcript is refused"
case "$OUT_R" in
  *"input: 444"*) no "stale tracked totals are not reported as this run" ;;
  *) ok "stale tracked totals are not reported as this run" ;;
esac

# --- 6i: the current state shape (`claudePath`) is read too ------------------
CUR_PATH="$TMP/elsewhere/current.jsonl"
printf '{"type":"assistant","message":{"id":"cur","model":"m","usage":{"input_tokens":555,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' > "$CUR_PATH"
printf '{"current":"claude","claudePath":"%s","claudeLength":0}\n' "$CUR_PATH" > "$PROJT/.workflow-dev/context/.compaction-state/WD-T.json"
OUT_CP=$( cd "$PROJT" && HOME="$FAKEHT" OPENCODE_DB="$TMP/none.db" bash "$SCRIPT" 2>/dev/null )
assert_contains "input: 555" "$OUT_CP" "the current state shape (claudePath) is honored"
# An empty `claudePath` (the OpenCode-shaped state) must not hide the legacy key.
printf '{"current":"claude","claudePath":"","transcriptPath":"%s","claudeLength":0}\n' "$CUR_PATH" > "$PROJT/.workflow-dev/context/.compaction-state/WD-T.json"
OUT_CE=$( cd "$PROJT" && HOME="$FAKEHT" OPENCODE_DB="$TMP/none.db" bash "$SCRIPT" 2>/dev/null )
assert_contains "input: 555" "$OUT_CE" "an empty claudePath falls back to transcriptPath"

# --- 6j: OpenCode default tracks OPENCODE_SESSION_ID, not the newest ---------
DBT="$TMP/current.db"
sqlite3 "$DBT" <<SQL
CREATE TABLE session_v2 (id text primary key, parent_id text, directory text, title text,
  agent text, model text, cost real, tokens_input integer, tokens_output integer,
  tokens_reasoning integer, tokens_cache_read integer, tokens_cache_write integer,
  time_created integer, time_updated integer);
CREATE TABLE session_message (session_id text, time_created integer);
INSERT INTO session_v2 VALUES ('ses_current',NULL,'$PROJDIR','Current run','build','{"id":"m1"}',0.1,11,1,0,0,0,100,100);
INSERT INTO session_v2 VALUES ('ses_newer',NULL,'$PROJDIR','Other run','build','{"id":"m1"}',9.9,999,0,0,0,0,5000,5000);
INSERT INTO session_v2 VALUES ('ses_child','ses_current','$PROJDIR','Sub','general','{"id":"m1"}',0,0,0,0,0,0,0,0);
INSERT INTO session_v2 VALUES ('ses_grand','ses_child','$PROJDIR','Sub-sub','general','{"id":"m1"}',0,0,0,0,0,0,0,0);
SQL
OUT_I=$( cd "$TMP/proj" && HOME="$TMP/nohome" OPENCODE_DB="$DBT" OPENCODE_SESSION_ID=ses_current bash "$SCRIPT" 2>/dev/null )
assert_contains "Session: ses_current" "$OUT_I" "OpenCode default uses OPENCODE_SESSION_ID"
case "$OUT_I" in
  *"Session: ses_newer"*) no "OPENCODE_SESSION_ID beats the newest top-level session" ;;
  *) ok "OPENCODE_SESSION_ID beats the newest top-level session" ;;
esac
OUT_J=$( cd "$TMP/proj" && HOME="$TMP/nohome" OPENCODE_DB="$DBT" OPENCODE_SESSION_ID=ses_child bash "$SCRIPT" 2>/dev/null )
assert_contains "Session: ses_current" "$OUT_J" "a sub-agent's child OPENCODE_SESSION_ID resolves to its parent run"
OUT_L=$( cd "$TMP/proj" && HOME="$TMP/nohome" OPENCODE_DB="$DBT" OPENCODE_SESSION_ID=ses_grand bash "$SCRIPT" 2>/dev/null )
assert_contains "Session: ses_current" "$OUT_L" "a nested sub-agent id walks up to the run"
# ...and so does a top-level one belonging to another directory.
mkdir -p "$TMP/otherdir"
OTHER_DIR="$( cd "$TMP/otherdir" && pwd -P )"
sqlite3 "$DBT" "INSERT INTO session_v2 VALUES ('ses_foreign',NULL,'$OTHER_DIR','Foreign','build','{\"id\":\"m1\"}',0,0,0,0,0,0,9000,9000);"
OUT_K=$( cd "$TMP/proj" && HOME="$TMP/nohome" OPENCODE_DB="$DBT" OPENCODE_SESSION_ID=ses_foreign bash "$SCRIPT" 2>/dev/null )
assert_contains "Session: ses_newer" "$OUT_K" "an OPENCODE_SESSION_ID from another directory is refused"

# --- 6k: snapshot — the common normalized object, both harnesses -----------
# OpenCode: cost/tokens come from the WHOLE recursive session tree, so a
# grandchild (a sub-sub-agent) is counted once and only once. The old report
# summed direct children only, which is exactly the undercount this replaces.
TGDB="$TMP/snapshot.db"
sqlite3 "$TGDB" <<SQL
CREATE TABLE session_v2 (id text primary key, parent_id text, directory text, title text,
  agent text, model text, cost real, tokens_input integer, tokens_output integer,
  tokens_reasoning integer, tokens_cache_read integer, tokens_cache_write integer,
  time_created integer, time_updated integer);
INSERT INTO session_v2 VALUES ('ses_p',NULL,'$PROJDIR','Run','build','{"id":"m1"}',1.0,10,5,1,100,2,0,100);
INSERT INTO session_v2 VALUES ('ses_c','ses_p','$PROJDIR','Sub','wd-judge','{"id":"m2"}',0.5,4,2,0,50,0,0,200);
INSERT INTO session_v2 VALUES ('ses_g','ses_c','$PROJDIR','Sub-sub','general','{"id":"m3"}',0.25,2,1,0,25,0,0,300);
SQL
SNAP_OC=$( cd "$TMP/proj" && HOME="$TMP/nohome" OPENCODE_TERMINAL=1 OPENCODE_DB="$TGDB" OPENCODE_SESSION_ID=ses_p bash "$SCRIPT" --snapshot WD-T --stage test 2>/dev/null )
assert_contains '"harness": "opencode"' "$SNAP_OC" "snapshot dispatches to the OpenCode adapter"
assert_contains '"cost_usd": 1.75' "$SNAP_OC" "OpenCode snapshot sums the whole tree (grandchild included)"
assert_contains '"input": 16' "$SNAP_OC" "OpenCode snapshot tokens include the grandchild"
assert_contains '"output": 8' "$SNAP_OC" "OpenCode snapshot output sums parent + child + grandchild"

# Claude Code: cost and the sub-agent-inclusive total come from the last
# `cost-state`; tokens come from message.usage plus each readable side-chain.
SNAP_MAIN="$TMP/snapshot-main.jsonl"
SNAP_SIDE="$TMP/snapshot-side.output"
printf '%s\n' '{"type":"assistant","message":{"id":"s1","model":"claude-haiku-4-5","usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200}}}' > "$SNAP_SIDE"
cat > "$SNAP_MAIN" <<JSONL
{"type":"assistant","message":{"id":"m1","model":"claude-sonnet-5-5","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":100,"cache_creation_input_tokens":20}},"timestamp":"2026-01-01T00:00:10.000Z"}
{"type":"assistant","message":{"id":"m2","model":"claude-sonnet-5-5","usage":{"input_tokens":7,"output_tokens":3,"cache_read_input_tokens":50,"cache_creation_input_tokens":10}},"timestamp":"2026-01-01T00:00:20.000Z"}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu_1","name":"Agent","input":{"description":"Fixture judge","subagent_type":"wd-judge"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu_1","content":[{"type":"text","text":"output_file: $SNAP_SIDE"}]}]}}
{"type":"cost-state","totalCostUSD":74.027,"modelUsage":{"claude-haiku-4-5":{"costUSD":0.1166},"claude-sonnet-5-5":{"costUSD":71.265},"claude-opus-5-5":{"costUSD":2.645}}}
JSONL
mkdir -p "$TMP/snapdir"
SNAP_CL=$( cd "$TMP/snapdir" && env -u OPENCODE -u OPENCODE_TERMINAL -u OPENCODE_SESSION_ID CLAUDECODE=1 bash "$SCRIPT" --snapshot WD-T --stage test "$SNAP_MAIN" 2>/dev/null )
assert_contains '"harness": "claude"' "$SNAP_CL" "snapshot dispatches to the Claude adapter"
assert_contains '"cost_usd": 74.027' "$SNAP_CL" "Claude snapshot cost is the last cost-state's totalCostUSD (sub-agents included)"
assert_contains '"input": 117' "$SNAP_CL" "Claude snapshot tokens include the readable side-chain"
assert_contains '"claude-opus-5-5"' "$SNAP_CL" "Claude snapshot models carry a model seen only in cost-state"

# No `cost-state` written yet → cost_usd null, tokens still reported — never a
# fabricated zero.
SNAP_NC="$TMP/snapshot-nocost.jsonl"
printf '{"type":"assistant","message":{"id":"x1","model":"m","usage":{"input_tokens":9,"output_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' > "$SNAP_NC"
SNAP_NULL=$( cd "$TMP/snapdir" && env -u OPENCODE -u OPENCODE_TERMINAL -u OPENCODE_SESSION_ID CLAUDECODE=1 bash "$SCRIPT" --snapshot WD-T --stage test "$SNAP_NC" 2>/dev/null )
assert_contains '"cost_usd": null' "$SNAP_NULL" "no cost-state → cost_usd null, never 0"
assert_contains '"input": 9' "$SNAP_NULL" "tokens are still reported when cost is unknown"

# No harness signal and no source → an honest `unavailable`, never a total.
SNAP_NA=$( cd "$TMP/empty" && HOME="$TMP/nohome" env -u OPENCODE -u OPENCODE_TERMINAL -u OPENCODE_SESSION_ID -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT OPENCODE_DB="$TMP/none.db" bash "$SCRIPT" --snapshot WD-T --stage test 2>/dev/null )
assert_contains '"status":"unavailable"' "$SNAP_NA" "no source and no harness → unavailable"

# --- 6l: ledger — delta, idempotency, reset, cross-harness, durability ------
LEDGER_PROJ="$TMP/ledgerproj"
mkdir -p "$LEDGER_PROJ/.workflow-dev/context"
LEDGER_DB="$TMP/ledger.db"
sqlite3 "$LEDGER_DB" <<SQL
CREATE TABLE session_v2 (id text primary key, parent_id text, directory text, title text,
  agent text, model text, cost real, tokens_input integer, tokens_output integer,
  tokens_reasoning integer, tokens_cache_read integer, tokens_cache_write integer,
  time_created integer, time_updated integer);
INSERT INTO session_v2 VALUES ('ses_lp',NULL,'$LEDGER_PROJ','Run','build','{"id":"m1"}',1.0,10,5,1,100,2,0,100);
SQL
snap_oc() { # $1 story, $2 stage
  ( cd "$LEDGER_PROJ" && HOME="$TMP/nohome" OPENCODE_TERMINAL=1 OPENCODE_DB="$LEDGER_DB" \
      OPENCODE_SESSION_ID=ses_lp bash "$SCRIPT" --snapshot "$1" --stage "$2" >/dev/null 2>&1 )
}
snap_cl() { # $1 story, $2 stage, $3 transcript
  ( cd "$LEDGER_PROJ" && env -u OPENCODE -u OPENCODE_TERMINAL -u OPENCODE_SESSION_ID \
      CLAUDECODE=1 bash "$SCRIPT" --snapshot "$1" --stage "$2" "$3" >/dev/null 2>&1 )
}
LEDGER_FILE="$LEDGER_PROJ/.workflow-dev/context/.usage/WD-L1.json"

snap_oc WD-L1 plan                       # abs 1.0  → delta 1.0, tokens in 10
sqlite3 "$LEDGER_DB" "UPDATE session_v2 SET cost=1.5, tokens_input=16 WHERE id='ses_lp';"
snap_oc WD-L1 validate                   # abs 1.5  → delta 0.5, token delta 6
snap_oc WD-L1 validate                   # same state → idempotent, no new line
[[ "$(jq -r '.checkpoints | length' "$LEDGER_FILE")" == "2" ]] \
  && ok "same source|stage|state is idempotent (no duplicate checkpoint)" \
  || no "same source|stage|state is idempotent"

sqlite3 "$LEDGER_DB" "UPDATE session_v2 SET cost=0.25, tokens_input=2 WHERE id='ses_lp';"
snap_oc WD-L1 save                       # abs fell → new segment, delta 0.25, token delta 2

# Cross-harness: a Claude checkpoint for the SAME story, a different `source`.
LEDGER_TX="$TMP/ledger-claude.jsonl"
printf '%s\n' \
  '{"type":"assistant","message":{"id":"c1","model":"m","usage":{"input_tokens":5,"output_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}' \
  '{"type":"cost-state","totalCostUSD":3.0,"modelUsage":{"m":{"costUSD":3.0}}}' > "$LEDGER_TX"
snap_cl WD-L1 plan "$LEDGER_TX"

LED_TOT=$( cd "$LEDGER_PROJ" && bash "$SCRIPT" --story WD-L1 )
assert_contains '$4.75' "$LED_TOT" "story total sums deltas across both harnesses"
assert_contains 'opencode: $1.75' "$LED_TOT" "per-harness split: OpenCode deltas"
assert_contains 'claude: $3' "$LED_TOT" "per-harness split: Claude delta"
# Tokens are summed as DELTAS too (10 + 6 + 2 from OpenCode, +5 from Claude),
# never as the sum of each checkpoint's absolute cumulative count.
assert_contains 'input 23' "$LED_TOT" "story token total sums deltas, not absolutes"
[[ "$(jq -r '[.checkpoints[] | select(.source=="ses_lp")] | last | .segment' "$LEDGER_FILE")" == "2" ]] \
  && ok "a falling absolute starts a new segment" || no "a falling absolute starts a new segment"

# AC 17: delete every source — the ledger still answers with the recorded total.
rm -f "$LEDGER_TX"
sqlite3 "$LEDGER_DB" "DELETE FROM session_v2;"
LED_AFTER=$( cd "$LEDGER_PROJ" && bash "$SCRIPT" --story WD-L1 )
assert_contains '$4.75' "$LED_AFTER" "the total survives deletion of every source (AC 17)"

# AC 18: no source and no checkpoint → unavailable, never a zero or invented total.
LED_NONE=$( cd "$LEDGER_PROJ" && bash "$SCRIPT" --story WD-NOPE )
assert_contains 'unavailable' "$LED_NONE" "no ledger and no source → unavailable (AC 18)"

# --- 6m: --story renders the per-role breakdown and the configured binding --
# Cubes come from what actually ran (never a fixed list); the binding line
# comes from model-tiering-check.sh --role-models; and a generic sub-agent is
# surfaced as a config-vs-observed discrepancy, not hidden.
REPORT_HOME="$TMP/report-home"
mkdir -p "$REPORT_HOME/.config/opencode/agents"
REPORT_HASH="$(bash "$HERE/roles-hash.sh")"
printf -- '---\ndescription: d\nmode: subagent\nmodel: ghost/cheap\n---\nb\n<!-- workflow-dev:roles-hash %s -->\n' \
  "$REPORT_HASH" > "$REPORT_HOME/.config/opencode/agents/wd-judge.md"
REPORT_DB="$TMP/report.db"
sqlite3 "$REPORT_DB" <<SQL
CREATE TABLE session_v2 (id text primary key, parent_id text, directory text, title text,
  agent text, model text, cost real, tokens_input integer, tokens_output integer,
  tokens_reasoning integer, tokens_cache_read integer, tokens_cache_write integer,
  time_created integer, time_updated integer);
INSERT INTO session_v2 VALUES ('ses_rp',NULL,'$LEDGER_PROJ','Run','build','{"id":"m1"}',1.0,10,5,1,100,2,0,100);
INSERT INTO session_v2 VALUES ('ses_rc','ses_rp','$LEDGER_PROJ','Sub','general','{"id":"m2"}',0.5,4,2,0,50,0,0,200);
SQL
( cd "$LEDGER_PROJ" && HOME="$REPORT_HOME" OPENCODE_TERMINAL=1 OPENCODE_DB="$REPORT_DB" \
    OPENCODE_SESSION_ID=ses_rp bash "$SCRIPT" --snapshot WD-R --stage plan >/dev/null 2>&1 )
REP=$( cd "$LEDGER_PROJ" && HOME="$REPORT_HOME" OPENCODE_TERMINAL=1 bash "$SCRIPT" --story WD-R )
assert_contains 'orchestrator' "$REP" "--story breaks spend down by the orchestrator cub"
assert_contains 'general' "$REP" "--story breaks spend down by an observed agent cub"
assert_contains 'wd-judge' "$REP" "--story prints the configured binding for a defined role"
assert_contains 'ghost/cheap' "$REP" "--story shows the bound model"
assert_contains 'not a configured role' "$REP" "--story flags a config-vs-observed discrepancy"
assert_contains 'setup-models' "$REP" "--story reminds how to change a role's model"

# --- 6n: robustness — unpriced source, corrupt ledger, bad story id, resume --
# An OpenCode session with no price (cost NULL) reports cost_usd null, never a
# fabricated 0 (AC 6).
NULLDB="$TMP/nullcost.db"
sqlite3 "$NULLDB" <<SQL
CREATE TABLE session_v2 (id text primary key, parent_id text, directory text, title text,
  agent text, model text, cost real, tokens_input integer, tokens_output integer,
  tokens_reasoning integer, tokens_cache_read integer, tokens_cache_write integer,
  time_created integer, time_updated integer);
INSERT INTO session_v2 VALUES ('ses_n',NULL,'$LEDGER_PROJ','R','build','{"id":"m"}',NULL,5,1,0,0,0,0,1);
SQL
NULLOUT=$( cd "$LEDGER_PROJ" && HOME="$TMP/nohome" OPENCODE_TERMINAL=1 OPENCODE_DB="$NULLDB" OPENCODE_SESSION_ID=ses_n bash "$SCRIPT" --snapshot WD-NULL --stage test 2>/dev/null )
assert_contains '"cost_usd": null' "$NULLOUT" "an unpriced OpenCode session reports cost_usd null, never 0"

# A corrupt ledger is refused, never silently overwritten — overwriting would
# destroy recorded spend and report the reduced total as authoritative.
CORRUPT="$LEDGER_PROJ/.workflow-dev/context/.usage/WD-CORRUPT.json"
printf 'NOT JSON {{{\n' > "$CORRUPT"
CORR_ERR=$( cd "$LEDGER_PROJ" && HOME="$TMP/nohome" OPENCODE_TERMINAL=1 OPENCODE_DB="$NULLDB" OPENCODE_SESSION_ID=ses_n bash "$SCRIPT" --snapshot WD-CORRUPT --stage test 2>&1 >/dev/null )
assert_contains 'refusing to overwrite' "$CORR_ERR" "a corrupt ledger is refused, not overwritten"
assert_contains 'NOT JSON' "$(cat "$CORRUPT")" "the corrupt ledger file is left untouched"

# A story id is a bare name: a path separator (or `.`/`..`) is refused, so
# --snapshot/--story cannot read or write outside .usage/.
BAD_ERR=$( cd "$LEDGER_PROJ" && HOME="$TMP/nohome" OPENCODE_TERMINAL=1 OPENCODE_DB="$NULLDB" OPENCODE_SESSION_ID=ses_n bash "$SCRIPT" --snapshot '../escape' --stage test 2>&1 >/dev/null )
assert_contains 'invalid story id' "$BAD_ERR" "a story id with a path separator is refused"
[[ ! -e "$LEDGER_PROJ/.workflow-dev/escape.json" && ! -e "$LEDGER_PROJ/.workflow-dev/context/escape.json" ]] \
  && ok "no file is written outside .usage/ for a bad story id" \
  || no "no file is written outside .usage/ for a bad story id"
assert_contains 'invalid story id' "$( cd "$LEDGER_PROJ" && bash "$SCRIPT" --story '../x' )" "--story rejects an invalid story id"

# priced → unpriced → priced must NOT double-count: the priced baseline is the
# last checkpoint that carried a price, so the resume is a delta, not a reset.
RESUME_TX="$TMP/resume.jsonl"
printf '%s\n' '{"type":"assistant","message":{"id":"a","model":"m","usage":{"input_tokens":1,"output_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}' '{"type":"cost-state","totalCostUSD":5.0,"modelUsage":{"m":{"costUSD":5.0}}}' > "$RESUME_TX"
snap_cl WD-RESUME a "$RESUME_TX"
printf '%s\n' '{"type":"assistant","message":{"id":"b","model":"m","usage":{"input_tokens":2,"output_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}' > "$RESUME_TX"
snap_cl WD-RESUME b "$RESUME_TX"
printf '%s\n' '{"type":"assistant","message":{"id":"c","model":"m","usage":{"input_tokens":3,"output_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}' '{"type":"cost-state","totalCostUSD":7.0,"modelUsage":{"m":{"costUSD":7.0}}}' > "$RESUME_TX"
snap_cl WD-RESUME c "$RESUME_TX"
assert_contains 'total: $7' "$( cd "$LEDGER_PROJ" && bash "$SCRIPT" --story WD-RESUME )" \
  "priced→unpriced→priced totals the real spend, not a double count"

# A reset while the source is UNPRICED must still restart the token baseline
# (a falling token counter is itself a reset) — never a negative delta.
URDB="$TMP/unpriced-reset.db"
sqlite3 "$URDB" <<SQL
CREATE TABLE session_v2 (id text primary key, parent_id text, directory text, title text,
  agent text, model text, cost real, tokens_input integer, tokens_output integer,
  tokens_reasoning integer, tokens_cache_read integer, tokens_cache_write integer,
  time_created integer, time_updated integer);
INSERT INTO session_v2 VALUES ('ses_u',NULL,'$LEDGER_PROJ','R','build','{"id":"m"}',1.0,100,10,1,1000,2,0,1);
SQL
snap_ur() { ( cd "$LEDGER_PROJ" && HOME="$TMP/nohome" OPENCODE_TERMINAL=1 OPENCODE_DB="$URDB" \
    OPENCODE_SESSION_ID=ses_u bash "$SCRIPT" --snapshot "$1" --stage "$2" >/dev/null 2>&1 ); }
snap_ur WD-UR a
sqlite3 "$URDB" "UPDATE session_v2 SET cost=NULL, tokens_input=50, tokens_output=5 WHERE id='ses_u';"
snap_ur WD-UR b
assert_contains 'input 150' "$( cd "$LEDGER_PROJ" && bash "$SCRIPT" --story WD-UR )" \
  "an unpriced reset restarts the token baseline (no negative delta)"

# A reset while UNPRICED, then a resume at a HIGHER price: the resumed cost is
# the new segment's first reading (delta = abs), never a delta across the reset
# (which would undercount), and the tokens are deltas throughout.
UR2DB="$TMP/unpriced-reset2.db"
sqlite3 "$UR2DB" <<SQL
CREATE TABLE session_v2 (id text primary key, parent_id text, directory text, title text,
  agent text, model text, cost real, tokens_input integer, tokens_output integer,
  tokens_reasoning integer, tokens_cache_read integer, tokens_cache_write integer,
  time_created integer, time_updated integer);
INSERT INTO session_v2 VALUES ('ses_u2',NULL,'$LEDGER_PROJ','R','build','{"id":"m"}',1.0,100,10,1,1000,2,0,1);
SQL
snap_u2() { ( cd "$LEDGER_PROJ" && HOME="$TMP/nohome" OPENCODE_TERMINAL=1 OPENCODE_DB="$UR2DB" \
    OPENCODE_SESSION_ID=ses_u2 bash "$SCRIPT" --snapshot "$1" --stage "$2" >/dev/null 2>&1 ); }
snap_u2 WD-UR2 a
sqlite3 "$UR2DB" "UPDATE session_v2 SET cost=NULL, tokens_input=50, tokens_output=5 WHERE id='ses_u2';"
snap_u2 WD-UR2 b
sqlite3 "$UR2DB" "UPDATE session_v2 SET cost=2.0, tokens_input=70, tokens_output=7 WHERE id='ses_u2';"
snap_u2 WD-UR2 c
UR2=$( cd "$LEDGER_PROJ" && bash "$SCRIPT" --story WD-UR2 )
assert_contains 'total: $3' "$UR2" "a resume after an unpriced reset starts a new segment (no undercount)"
assert_contains 'input 170' "$UR2" "tokens across an unpriced reset and resume stay deltas"

# A cost that falls while tokens RISE is a cost reset (AC 8) but NOT a token
# reset — the token total must not inflate to the whole absolute.
CFDB="$TMP/costfall.db"
sqlite3 "$CFDB" <<SQL
CREATE TABLE session_v2 (id text primary key, parent_id text, directory text, title text,
  agent text, model text, cost real, tokens_input integer, tokens_output integer,
  tokens_reasoning integer, tokens_cache_read integer, tokens_cache_write integer,
  time_created integer, time_updated integer);
INSERT INTO session_v2 VALUES ('ses_cf',NULL,'$LEDGER_PROJ','R','build','{"id":"m"}',5.0,100,10,1,1000,2,0,1);
SQL
snap_cf() { ( cd "$LEDGER_PROJ" && HOME="$TMP/nohome" OPENCODE_TERMINAL=1 OPENCODE_DB="$CFDB" \
    OPENCODE_SESSION_ID=ses_cf bash "$SCRIPT" --snapshot "$1" --stage "$2" >/dev/null 2>&1 ); }
snap_cf WD-CF a
sqlite3 "$CFDB" "UPDATE session_v2 SET cost=NULL, tokens_input=150, tokens_output=15 WHERE id='ses_cf';"
snap_cf WD-CF b
sqlite3 "$CFDB" "UPDATE session_v2 SET cost=3.0, tokens_input=200, tokens_output=20 WHERE id='ses_cf';"
snap_cf WD-CF c
CF=$( cd "$LEDGER_PROJ" && bash "$SCRIPT" --story WD-CF )
assert_contains 'total: $8' "$CF" "a falling cost with rising tokens is a cost reset (AC 8)"
assert_contains 'input 200' "$CF" "a cost-only reset does not inflate the token total"

# A reset that lands on a byte-identical tuple of an OLDER checkpoint must be
# recorded as a new segment, not swallowed as a duplicate of that older one.
RTDB="$TMP/reset-dup.db"
sqlite3 "$RTDB" <<SQL
CREATE TABLE session_v2 (id text primary key, parent_id text, directory text, title text,
  agent text, model text, cost real, tokens_input integer, tokens_output integer,
  tokens_reasoning integer, tokens_cache_read integer, tokens_cache_write integer,
  time_created integer, time_updated integer);
INSERT INTO session_v2 VALUES ('ses_rt',NULL,'$LEDGER_PROJ','R','build','{"id":"m"}',5.0,100,10,1,1000,2,0,1);
SQL
snap_rt() { ( cd "$LEDGER_PROJ" && HOME="$TMP/nohome" OPENCODE_TERMINAL=1 OPENCODE_DB="$RTDB" \
    OPENCODE_SESSION_ID=ses_rt bash "$SCRIPT" --snapshot "$1" --stage "$2" >/dev/null 2>&1 ); }
snap_rt WD-RT dev
sqlite3 "$RTDB" "UPDATE session_v2 SET cost=7.0, tokens_input=200 WHERE id='ses_rt';"
snap_rt WD-RT dev
sqlite3 "$RTDB" "UPDATE session_v2 SET cost=5.0, tokens_input=100 WHERE id='ses_rt';"
snap_rt WD-RT dev
RT=$( cd "$LEDGER_PROJ" && bash "$SCRIPT" --story WD-RT )
assert_contains 'total: $12' "$RT" "a reset to an older identical tuple is recorded, not deduped"
assert_contains 'checkpoints: 3' "$RT" "the reset adds a checkpoint rather than being swallowed"

# A corrupt parent cycle must terminate (bounded recursion), not hang — the
# walk-up CTE in opencode_default_session is reached whenever the id is set.
CYCDB="$TMP/cycle.db"
sqlite3 "$CYCDB" <<SQL
CREATE TABLE session_v2 (id text primary key, parent_id text, directory text, title text,
  agent text, model text, cost real, tokens_input integer, tokens_output integer,
  tokens_reasoning integer, tokens_cache_read integer, tokens_cache_write integer,
  time_created integer, time_updated integer);
INSERT INTO session_v2 VALUES ('ses_a','ses_c','$LEDGER_PROJ','A','build','{"id":"m"}',1.0,1,1,0,0,0,0,1);
INSERT INTO session_v2 VALUES ('ses_c','ses_a','$LEDGER_PROJ','C','build','{"id":"m"}',0,1,1,0,0,0,0,1);
SQL
( cd "$LEDGER_PROJ" && HOME="$TMP/nohome" OPENCODE_TERMINAL=1 OPENCODE_DB="$CYCDB" \
    OPENCODE_SESSION_ID=ses_a bash "$SCRIPT" --snapshot WD-CYC --stage t >/dev/null 2>&1 ) & CYCPID=$!
sleep 3
if kill -0 "$CYCPID" 2>/dev/null; then
  kill "$CYCPID" 2>/dev/null
  no "a parent cycle terminates instead of hanging"
else
  wait "$CYCPID" 2>/dev/null
  ok "a parent cycle terminates instead of hanging"
fi

# --- 7: jq missing → clear failure, not a wrong number ----------------------
# Empty PATH that still runs bash by absolute path: the jq guard fires before
# any other external tool, so this is portable (unlike assuming /bin has no jq).
mkdir -p "$TMP/emptybin"
env PATH="$TMP/emptybin" "$BASH_ABS" "$SCRIPT" "$MAIN" >/dev/null 2>&1
[[ $? -eq 1 ]] && ok "exits 1 when jq is missing" || no "exits 1 when jq is missing"

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
