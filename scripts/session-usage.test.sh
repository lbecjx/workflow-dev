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

# --- 6l: a repeated subagent_type, and a checkpoint that fails loudly (WD-0049)
# Two Agent calls of the same subagent_type used to clobber the `agents`
# accumulator: `orchestrator` vanished, `tokens`/`models` landed at the top
# level, and ledger_record then died on `Cannot index array with string
# "cost_usd"` while still exiting 0 with nothing recorded.
REP_PROJ="$TMP/repproj"
mkdir -p "$REP_PROJ"
REP_TX="$TMP/repeated.jsonl"
cat > "$REP_TX" <<'JSONL'
{"type":"assistant","timestamp":"2026-10-08T00:00:00Z","message":{"id":"m1","model":"claude-opus-5-5","usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"content":[]}}
{"type":"assistant","timestamp":"2026-10-08T00:00:01Z","message":{"id":"m2","model":"claude-opus-5-5","usage":{"input_tokens":1,"output_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"content":[{"type":"tool_use","id":"t1","name":"Agent","input":{"subagent_type":"wd-operator","prompt":"x"}}]}}
{"type":"assistant","timestamp":"2026-10-08T00:00:02Z","message":{"id":"m3","model":"claude-opus-5-5","usage":{"input_tokens":1,"output_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"content":[{"type":"tool_use","id":"t2","name":"Agent","input":{"subagent_type":"wd-operator","prompt":"x"}}]}}
JSONL
snap_rep() { # $1 story, $2.. extra args; prints stderr, returns the exit code
  ( cd "$REP_PROJ" && env -u OPENCODE -u OPENCODE_TERMINAL -u OPENCODE_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
      CLAUDECODE=1 bash "$SCRIPT" --snapshot "$1" --stage init "${@:2}" 2>&1 >/dev/null )
}
snap_rep FX "$REP_TX" >/dev/null
[[ $? -eq 0 ]] && ok "a repeated subagent_type snapshot exits 0" || no "a repeated subagent_type snapshot exits 0"
REP_FILE="$REP_PROJ/.workflow-dev/context/.usage/FX.json"
[[ "$(jq -r '.checkpoints | length' "$REP_FILE" 2>/dev/null)" == "1" ]] \
  && ok "a repeated subagent_type still records its checkpoint" \
  || no "a repeated subagent_type still records its checkpoint"
[[ "$(jq -c '.checkpoints[0].agents | keys' "$REP_FILE" 2>/dev/null)" == '["orchestrator","wd-operator"]' ]] \
  && ok "agents keeps exactly orchestrator + the repeated type" \
  || no "agents keeps exactly orchestrator + the repeated type (got $(jq -c '.checkpoints[0].agents | keys' "$REP_FILE" 2>/dev/null))"

# Each call with its own side-chain: the repeated type accumulates both.
REP_S1="$TMP/rep-side1.output"; REP_S2="$TMP/rep-side2.output"
printf '%s\n' '{"type":"assistant","message":{"id":"r1","model":"claude-sonnet-5-5","usage":{"input_tokens":100,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}' > "$REP_S1"
printf '%s\n' '{"type":"assistant","message":{"id":"r2","model":"claude-sonnet-5-5","usage":{"input_tokens":200,"output_tokens":20,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}' > "$REP_S2"
REP_TX2="$TMP/repeated-side.jsonl"
cat "$REP_TX" > "$REP_TX2"
cat >> "$REP_TX2" <<JSONL
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":[{"type":"text","text":"output_file: $REP_S1"}]}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t2","content":[{"type":"text","text":"output_file: $REP_S2"}]}]}}
JSONL
snap_rep FX2 "$REP_TX2" >/dev/null
[[ "$(jq -c '.checkpoints[0].agents["wd-operator"].tokens | [.input,.output]' "$REP_PROJ/.workflow-dev/context/.usage/FX2.json" 2>/dev/null)" == "[300,30]" ]] \
  && ok "a repeated type sums the tokens of every call's side-chain" \
  || no "a repeated type sums the tokens of every call's side-chain"

# --transcript is a real flag, equivalent to the positional path.
snap_rep FX3 --transcript "$REP_TX" >/dev/null
[[ "$(jq -r '.checkpoints | length' "$REP_PROJ/.workflow-dev/context/.usage/FX3.json" 2>/dev/null)" == "1" ]] \
  && ok "--transcript <path> records like the positional path" \
  || no "--transcript <path> records like the positional path"
TX_ERR=$(snap_rep FX4 --transcript)
TX_RC=$?
[[ $TX_RC -ne 0 && -n "$TX_ERR" && ! -e "$REP_PROJ/.workflow-dev/context/.usage/FX4.json" ]] \
  && ok "--transcript with no value fails loudly and records nothing" \
  || no "--transcript with no value fails loudly and records nothing (rc $TX_RC)"

# A failing checkpoint computation is loud: stderr says so, no summary line,
# the ledger is unchanged, and the exit is non-zero. A jq shim fails only the
# ledger's checkpoint filter (`def cps`), so every other call is the real jq.
mkdir -p "$TMP/jqshim"
cat > "$TMP/jqshim/jq" <<SH
#!$BASH_ABS
case "\$*" in *"def cps"*) echo "jq: forced failure" >&2; exit 5 ;; esac
exec "$(command -v jq)" "\$@"
SH
chmod +x "$TMP/jqshim/jq"
BEFORE=$(cat "$REP_FILE")
FAIL_ERR=$( cd "$REP_PROJ" && env -u OPENCODE -u OPENCODE_TERMINAL -u OPENCODE_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
    PATH="$TMP/jqshim:$PATH" CLAUDECODE=1 bash "$SCRIPT" --snapshot FX --stage plan "$REP_TX" 2>&1 >/dev/null )
FAIL_RC=$?
assert_contains 'checkpoint NOT recorded' "$FAIL_ERR" "a failed checkpoint computation says so on stderr"
case "$FAIL_ERR" in *"story total"*) no "a failed checkpoint prints no summary line" ;; *) ok "a failed checkpoint prints no summary line" ;; esac
[[ "$(cat "$REP_FILE")" == "$BEFORE" ]] && ok "a failed checkpoint leaves the ledger unchanged" || no "a failed checkpoint leaves the ledger unchanged"
[[ $FAIL_RC -ne 0 ]] && ok "a failed checkpoint exits non-zero" || no "a failed checkpoint exits non-zero"

# --- 6m: this session's transcript, by id, from any cwd (WD-0049) -----------
# Two sessions on one repo: "newest" belonged to whichever wrote last, so a
# parallel session's spend was recorded as this one's. CLAUDE_CODE_SESSION_ID
# names this session's own file and wins — even when it is not the newest.
PROJS="$TMP/sidproj"; FAKEHS="$TMP/fakehome-sid"
mkdir -p "$PROJS"
SLUGS="$( cd "$PROJS" && pwd -P | sed 's#/#-#g' )"
mkdir -p "$FAKEHS/.claude/projects/$SLUGS" "$FAKEHS/.claude/projects/-some-other-project"
tx_line() { printf '{"type":"assistant","message":{"id":"%s","model":"m","usage":{"input_tokens":%s,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' "$1" "$2"; }
tx_line mine 555 > "$FAKEHS/.claude/projects/$SLUGS/sid-mine.jsonl"
touch -t 202001010000 "$FAKEHS/.claude/projects/$SLUGS/sid-mine.jsonl"
tx_line other 666 > "$FAKEHS/.claude/projects/$SLUGS/sid-other.jsonl"
snap_sid() { # $1 CLAUDE_CODE_SESSION_ID value ("" = unset), $2 cwd; prints the snapshot
  if [[ -n "$1" ]]; then
    ( cd "$2" && HOME="$FAKEHS" env -u OPENCODE -u OPENCODE_TERMINAL -u OPENCODE_SESSION_ID \
        CLAUDECODE=1 CLAUDE_CODE_SESSION_ID="$1" bash "$SCRIPT" --snapshot WD-SID --stage t 2>/dev/null )
  else
    ( cd "$2" && HOME="$FAKEHS" env -u OPENCODE -u OPENCODE_TERMINAL -u OPENCODE_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
        CLAUDECODE=1 bash "$SCRIPT" --snapshot WD-SID --stage t 2>/dev/null )
  fi
}
assert_contains '"input": 555' "$(snap_sid sid-mine "$PROJS")" "CLAUDE_CODE_SESSION_ID wins over a newer transcript in the project"
assert_contains '"input": 666' "$(snap_sid "" "$PROJS")" "without CLAUDE_CODE_SESSION_ID the newest fresh transcript is used"
assert_contains '"input": 666' "$(snap_sid sid-missing "$PROJS")" "a session id with no transcript falls back to the newest"
assert_contains '"input": 666' "$(snap_sid '../sid-mine' "$PROJS")" "a session id that could form a path is ignored"
tx_line elsewhere 777 > "$FAKEHS/.claude/projects/-some-other-project/sid-away.jsonl"
assert_contains '"input": 777' "$(snap_sid sid-away "$PROJS")" "a session id is found under another project's slug"

# Called from a subdirectory of the repo (the WD-0043 `plan` case: a skill
# `cd`ed into .workflow-dev/context/), the transcript resolves and the ledger
# is written at the git toplevel — never a nested .usage/.
GREPO="$TMP/gitrepo"; FAKEHG="$TMP/fakehome-git"
mkdir -p "$GREPO/.workflow-dev/context"
git -C "$GREPO" init -q
SLUGG="$( cd "$GREPO" && pwd -P | sed 's#/#-#g' )"
mkdir -p "$FAKEHG/.claude/projects/$SLUGG"
tx_line root 888 > "$FAKEHG/.claude/projects/$SLUGG/root.jsonl"
SUB_OUT=$( cd "$GREPO/.workflow-dev/context" && HOME="$FAKEHG" env -u OPENCODE -u OPENCODE_TERMINAL -u OPENCODE_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
    CLAUDECODE=1 bash "$SCRIPT" --snapshot WD-SUB --stage plan 2>/dev/null )
assert_contains '"input": 888' "$SUB_OUT" "a snapshot from a repo subdirectory resolves the project's transcript"
[[ -f "$GREPO/.workflow-dev/context/.usage/WD-SUB.json" ]] \
  && ok "a snapshot from a repo subdirectory writes the ledger at the toplevel" \
  || no "a snapshot from a repo subdirectory writes the ledger at the toplevel"
[[ ! -e "$GREPO/.workflow-dev/context/.workflow-dev" ]] \
  && ok "no nested .workflow-dev/ is created under the cwd" \
  || no "no nested .workflow-dev/ is created under the cwd"
assert_contains 'checkpoints: 1' "$( cd "$GREPO/.workflow-dev/context" && bash "$SCRIPT" --story WD-SUB )" "--story from a subdirectory reads the toplevel ledger"

# --- 6n: never a frozen cost — cost-state only while it is up to date (WD-0049)
# Claude Code writes cost-state on lifecycle events, not per turn, so a live
# session's is usually stale; a checkpoint then adds the priced tail to it.
EST_PROJ="$TMP/estproj"
mkdir -p "$EST_PROJ"
snap_est() { # $1 story, $2 transcript; prints stdout+stderr
  ( cd "$EST_PROJ" && env -u OPENCODE -u OPENCODE_TERMINAL -u OPENCODE_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
      CLAUDECODE=1 bash "$SCRIPT" --snapshot "$1" --stage test --transcript "$2" 2>&1 )
}
# usage line: $1 id, $2 model, $3 input, $4 output, $5 cache_read, $6 cache_create (all 1h), $7 speed
use_line() { printf '{"type":"assistant","timestamp":"2026-10-08T00:00:%s","message":{"id":"%s","model":"%s","usage":{"input_tokens":%s,"output_tokens":%s,"cache_read_input_tokens":%s,"cache_creation_input_tokens":%s,"cache_creation":{"ephemeral_1h_input_tokens":%s,"ephemeral_5m_input_tokens":0},"speed":"%s"}}}\n' "${8:-10}" "$1" "$2" "$3" "$4" "$5" "$6" "$6" "${7:-standard}"; }

EST_STALE="$TMP/est-stale.jsonl"
{ use_line e1 claude-opus-5-5 10 10 0 0 standard 01
  printf '%s\n' '{"type":"cost-state","totalCostUSD":1.0,"modelUsage":{"claude-opus-5-5":{"costUSD":1.0}}}'
  use_line e2 claude-opus-5-5 1000 1000 0 1000 standard 20; } > "$EST_STALE"
EST_OUT=$(snap_est WD-EST "$EST_STALE")
assert_contains '"cost_usd": 1.032' "$EST_OUT" "a stale cost-state plus the priced tail (4+20+8 per 1000 tokens, 1h write)"
assert_contains '"cost_basis": "estimated"' "$EST_OUT" "a stale cost-state gives cost_basis estimated"
assert_contains '"stale": true' "$EST_OUT" "a stale cost-state is marked stale"
assert_contains '(estimated)' "$EST_OUT" "the summary line marks an estimated step"

EST_NONE="$TMP/est-none.jsonl"
use_line n1 claude-opus-5-5 1000000 0 0 0 > "$EST_NONE"
EST_N=$(snap_est WD-ESTN "$EST_NONE")
assert_contains '"cost_usd": 4' "$EST_N" "no cost-state: the whole run is priced from the table"
case "$EST_N" in *'"stale"'*) no "no cost-state is not marked stale" ;; *) ok "no cost-state is not marked stale" ;; esac

EST_FAST="$TMP/est-fast.jsonl"
use_line f1 claude-opus-5-5 1000000 0 0 0 fast > "$EST_FAST"
assert_contains '"cost_usd": 8' "$(snap_est WD-ESTF "$EST_FAST")" "a fast-mode message is priced with the model's multiplier"

EST_DATED="$TMP/est-dated.jsonl"
use_line d1 claude-haiku-4-5-20251001 1000000 0 0 0 > "$EST_DATED"
assert_contains '"cost_usd": 1' "$(snap_est WD-ESTD "$EST_DATED")" "a dated model id falls back to its undated price"

EST_UNK="$TMP/est-unknown.jsonl"
{ use_line u1 claude-opus-5-5 1000000 0 0 0; use_line u2 claude-imaginary-9 5 5 0 0; } > "$EST_UNK"
EST_U=$(snap_est WD-ESTU "$EST_UNK")
assert_contains '"cost_usd": null' "$EST_U" "a model with no price leaves the total null, never a guess"
assert_contains 'no price for claude-imaginary-9' "$EST_U" "the unpriced model is named on stderr"

# Up to date: the last cost-state comes after every message → its total, exact.
assert_contains '"cost_basis": "cost-state"' "$SNAP_CL" "an up-to-date cost-state gives cost_basis cost-state"

# Agents are priced per cub; the durable subagents/ copy is found by toolUseId
# when the tool_result names no output_file (a foreground call).
EST_AG="$TMP/est-agents.jsonl"
mkdir -p "$TMP/est-agents/subagents"
use_line s1 claude-sonnet-5-5 1000000 0 0 0 > "$TMP/est-agents/subagents/agent-abc.jsonl"
printf '%s\n' '{"agentType":"wd-judge","toolUseId":"tu_fg"}' > "$TMP/est-agents/subagents/agent-abc.meta.json"
{ use_line a1 claude-opus-5-5 1000000 0 0 0
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu_fg","name":"Agent","input":{"subagent_type":"wd-judge"}}]}}'
  printf '%s\n' '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu_fg","content":"done"}]}}'; } > "$EST_AG"
EST_A=$(snap_est WD-ESTA "$EST_AG")
assert_contains '"cost_usd": 6' "$EST_A" "a foreground sub-agent's durable side-chain is priced into the total"
[[ "$(jq -c '.checkpoints[0].agents | map_values(.cost_usd)' "$EST_PROJ/.workflow-dev/context/.usage/WD-ESTA.json")" == '{"orchestrator":4,"wd-judge":2}' ]] \
  && ok "each agent cub carries its own estimated cost" \
  || no "each agent cub carries its own estimated cost"
printf '%s\n' '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu_gone","content":[{"type":"text","text":"output_file: /nonexistent/gone.output"}]}]}}' \
  '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu_gone","name":"Agent","input":{"subagent_type":"wd-operator"}}]}}' >> "$EST_AG"
# A side-chain with nothing to read (no output_file, no durable copy): its
# spend is unknown, so the estimate is null — recorded, never a guess.
EST_G=$(snap_est WD-ESTG "$EST_AG")
assert_contains '"cost_usd": null' "$EST_G" "a side-chain with nothing to read leaves the estimate null"
assert_contains 'no side-chain found for wd-operator' "$EST_G" "the missing side-chain is named on stderr"

# An exact cost-state lower than the estimate before it is a correction, not a
# reset: the story total is the exact figure, not both added up.
EST_SW="$TMP/est-switch.jsonl"
use_line w1 claude-opus-5-5 1000000 0 0 0 > "$EST_SW"
snap_est WD-ESTW "$EST_SW" >/dev/null
printf '%s\n' '{"type":"cost-state","totalCostUSD":3.9,"modelUsage":{"claude-opus-5-5":{"costUSD":3.9}}}' >> "$EST_SW"
snap_est WD-ESTW "$EST_SW" >/dev/null
EST_REP=$( cd "$EST_PROJ" && bash "$SCRIPT" --story WD-ESTW )
assert_contains 'total: $3.9 ' "$EST_REP" "an exact cost-state below an earlier estimate corrects it, no reset"
assert_contains 'estimated: 1' "$EST_REP" "--story counts the estimated checkpoints"

# A side-chain with a truncated last line (an agent caught mid-write) is
# unreadable: no checkpoint — never a $0 one with empty models/agents — and a
# later complete one is not read as a reset.
EST_TR="$TMP/est-trunc.jsonl"
mkdir -p "$TMP/est-trunc/subagents"
{ use_line t1 claude-sonnet-5-5 10 0 0 0; printf '{"type":"assistant","message":{"id":"t2"'; } > "$TMP/est-trunc/subagents/agent-tr.jsonl"
printf '%s\n' '{"agentType":"wd-operator","toolUseId":"tu_tr"}' > "$TMP/est-trunc/subagents/agent-tr.meta.json"
{ use_line m1 claude-opus-5-5 1000000 0 0 0
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu_tr","name":"Agent","input":{"subagent_type":"wd-operator"}}]}}'; } > "$EST_TR"
EST_T=$(snap_est WD-ESTT "$EST_TR")
assert_contains 'checkpoint NOT recorded' "$EST_T" "a truncated side-chain refuses the checkpoint"
[[ ! -e "$EST_PROJ/.workflow-dev/context/.usage/WD-ESTT.json" ]] \
  && ok "a truncated side-chain never records a \$0 checkpoint" \
  || no "a truncated side-chain never records a \$0 checkpoint"
# The write completes: the next checkpoint is the whole run, once.
{ use_line t1 claude-sonnet-5-5 10 0 0 0; use_line t2 claude-sonnet-5-5 1000000 0 0 0; } > "$TMP/est-trunc/subagents/agent-tr.jsonl"
snap_est WD-ESTT "$EST_TR" >/dev/null
[[ "$(jq -r '[.checkpoints[].delta] | add | . * 100000 | round' "$EST_PROJ/.workflow-dev/context/.usage/WD-ESTT.json")" == "600002" ]] \
  && ok "after a refused checkpoint the run is counted once" \
  || no "after a refused checkpoint the run is counted once"

# A whole-run estimate, then a cost-state below it with a small tail: the
# second reading is a correction, not a reset — the run is not counted twice.
EST_C2="$TMP/est-correct.jsonl"
use_line c1 claude-opus-5-5 1000000 0 0 0 > "$EST_C2"
snap_est WD-ESTC "$EST_C2" >/dev/null
{ printf '%s\n' '{"type":"cost-state","totalCostUSD":3.96,"modelUsage":{"claude-opus-5-5":{"costUSD":3.96}}}'
  use_line c2 claude-opus-5-5 1000 0 0 0 standard 30; } >> "$EST_C2"
snap_est WD-ESTC "$EST_C2" >/dev/null
assert_contains 'total: $3.964 ' "$( cd "$EST_PROJ" && bash "$SCRIPT" --story WD-ESTC )" "an estimate built on a lower cost-state corrects the earlier estimate, no reset"

# A run's cost never falls within its transcript; a lower cost-state written
# later is another process's stale view (seen: 211 after 342 under remote
# control). The highest one stays the reading — no fake reset, no lost spend.
EST_MX="$TMP/est-mixed.jsonl"
{ use_line x1 claude-opus-5-5 10 0 0 0 standard 01
  printf '%s\n' '{"type":"cost-state","totalCostUSD":5,"modelUsage":{"claude-opus-5-5":{"costUSD":5}}}'; } > "$EST_MX"
snap_est WD-ESTX "$EST_MX" >/dev/null
use_line x2 claude-opus-5-5 250000 0 0 0 standard 20 >> "$EST_MX"
snap_est WD-ESTX "$EST_MX" >/dev/null
printf '%s\n' '{"type":"cost-state","totalCostUSD":1,"modelUsage":{"claude-opus-5-5":{"costUSD":1}}}' >> "$EST_MX"
snap_est WD-ESTX "$EST_MX" >/dev/null
assert_contains 'total: $6 ' "$( cd "$EST_PROJ" && bash "$SCRIPT" --story WD-ESTX )" "a lower cost-state written later is ignored, not read as a reset"

# The same transcript named from two directories is one source, not two runs.
GR2="$TMP/gitrepo2"
mkdir -p "$GR2/.workflow-dev/context"
git -C "$GR2" init -q
use_line r1 claude-opus-5-5 250000 0 0 0 > "$GR2/main.jsonl"
for d in "$GR2" "$GR2/.workflow-dev/context"; do
  ( cd "$d" && env -u OPENCODE -u OPENCODE_TERMINAL -u OPENCODE_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
      CLAUDECODE=1 bash "$SCRIPT" --snapshot WD-SRC --stage "s$RANDOM" --transcript "$( [[ "$d" == "$GR2" ]] && echo main.jsonl || echo ../../main.jsonl )" >/dev/null 2>&1 )
done
assert_contains 'total: $1 ' "$( cd "$GR2" && bash "$SCRIPT" --story WD-SRC )" "a transcript named by two relative paths is one source"

# A session launched in a subdirectory finds its own transcript before a
# newer one at the toplevel (no CLAUDE_CODE_SESSION_ID).
GR3="$TMP/gitrepo3"; FAKEH3="$TMP/fakehome-sub"
mkdir -p "$GR3/pkg"
git -C "$GR3" init -q
SL_ROOT="$( cd "$GR3" && pwd -P | sed 's#/#-#g' )"; SL_PKG="$( cd "$GR3/pkg" && pwd -P | sed 's#/#-#g' )"
mkdir -p "$FAKEH3/.claude/projects/$SL_ROOT" "$FAKEH3/.claude/projects/$SL_PKG"
tx_line pkg 321 > "$FAKEH3/.claude/projects/$SL_PKG/a.jsonl"
touch -t "$(date -v-2M +%Y%m%d%H%M 2>/dev/null || date -d '-2 min' +%Y%m%d%H%M)" "$FAKEH3/.claude/projects/$SL_PKG/a.jsonl"
tx_line root 654 > "$FAKEH3/.claude/projects/$SL_ROOT/b.jsonl"
SUBL=$( cd "$GR3/pkg" && HOME="$FAKEH3" env -u OPENCODE -u OPENCODE_TERMINAL -u OPENCODE_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
    CLAUDECODE=1 bash "$SCRIPT" --snapshot WD-SUBL --stage t 2>/dev/null )
assert_contains '"input": 321' "$SUBL" "a session launched in a subdirectory resolves its own transcript first"

# Lower cost-states (0.5, then 2) after an exact 5: the base stays 5, and the
# estimate prices only the tail after it.
EST_RV="$TMP/est-reset-est.jsonl"
{ use_line v1 claude-opus-5-5 10 0 0 0 standard 01
  printf '%s\n' '{"type":"cost-state","totalCostUSD":5,"modelUsage":{"claude-opus-5-5":{"costUSD":5}}}'; } > "$EST_RV"
snap_est WD-ESTV "$EST_RV" >/dev/null
{ printf '%s\n' '{"type":"cost-state","totalCostUSD":0.5,"modelUsage":{"claude-opus-5-5":{"costUSD":0.5}}}'
  use_line v2 claude-opus-5-5 75000 0 0 0 standard 20; } >> "$EST_RV"
snap_est WD-ESTV "$EST_RV" >/dev/null
printf '%s\n' '{"type":"cost-state","totalCostUSD":2,"modelUsage":{"claude-opus-5-5":{"costUSD":2}}}' >> "$EST_RV"
snap_est WD-ESTV "$EST_RV" >/dev/null
assert_contains 'total: $5.3 ' "$( cd "$EST_PROJ" && bash "$SCRIPT" --story WD-ESTV )" "the highest cost-state stays the base under later, lower ones"

# CDPATH must not leak into the recorded source path.
GR4="$TMP/gitrepo4"
mkdir -p "$GR4/a/b"
git -C "$GR4" init -q
use_line p1 claude-opus-5-5 250000 0 0 0 > "$GR4/main.jsonl"
( cd "$GR4/a" && CDPATH="$GR4:." env -u OPENCODE -u OPENCODE_TERMINAL -u OPENCODE_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
    CLAUDECODE=1 bash "$SCRIPT" --snapshot WD-CDP --stage t --transcript b/../../main.jsonl >/dev/null 2>&1 )
[[ "$(jq -r '.checkpoints[0].source' "$GR4/.workflow-dev/context/.usage/WD-CDP.json" 2>/dev/null)" == "$( cd "$GR4" && pwd -P )/main.jsonl" ]] \
  && ok "CDPATH does not leak into the source path" \
  || no "CDPATH does not leak into the source path"

# A transcript that cannot be opened is no source — never a $0 checkpoint.
NOF=$(snap_est WD-NOF "$TMP/does-not-exist.jsonl")
[[ ! -e "$EST_PROJ/.workflow-dev/context/.usage/WD-NOF.json" ]] \
  && ok "a missing transcript records nothing" \
  || no "a missing transcript records nothing"

# A side-chain read at one checkpoint and gone at the next (its /tmp file
# deleted, no durable copy) would drop tokens — a fake reset that counts the
# run twice. The checkpoint is refused, loudly; the total stays right.
EST_GN="$TMP/est-gone.jsonl"; GN_SIDE="$TMP/gone-side.output"
use_line g1 claude-haiku-4-5 1000 0 0 0 > "$GN_SIDE"
{ use_line g0 claude-opus-5-5 1000 0 0 0 standard 01
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu_g","name":"Agent","input":{"subagent_type":"wd-operator"}}]}}'
  printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu_g","content":[{"type":"text","text":"output_file: %s"}]}]}}\n' "$GN_SIDE"
  printf '%s\n' '{"type":"cost-state","totalCostUSD":5,"modelUsage":{"claude-opus-5-5":{"costUSD":5}}}'; } > "$EST_GN"
snap_est WD-ESTGN "$EST_GN" >/dev/null
rm -f "$GN_SIDE"
printf '%s\n' '{"type":"cost-state","totalCostUSD":6,"modelUsage":{"claude-opus-5-5":{"costUSD":6}}}' >> "$EST_GN"
GN_OUT=$(snap_est WD-ESTGN "$EST_GN")
GN_RC=$?
assert_contains 'was read before and is gone now — checkpoint NOT recorded' "$GN_OUT" "a side-chain that vanished refuses the checkpoint, naming it"
[[ $GN_RC -ne 0 ]] && ok "a vanished side-chain exits non-zero" || no "a vanished side-chain exits non-zero"
assert_contains 'total: $5 ' "$( cd "$EST_PROJ" && bash "$SCRIPT" --story WD-ESTGN )" "a vanished side-chain never double-counts the run"

# A call that never had anything to read, next to a read one of the same
# type, still records: only a call seen before and gone now is refused.
EST_NV="$TMP/est-never.jsonl"; NV_SIDE="$TMP/never-side.output"
use_line n1 claude-haiku-4-5 1000 0 0 0 > "$NV_SIDE"
{ use_line n0 claude-opus-5-5 1000 0 0 0 standard 01
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu_n1","name":"Agent","input":{"subagent_type":"wd-operator"}}]}}'
  printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu_n1","content":[{"type":"text","text":"output_file: %s"}]}]}}\n' "$NV_SIDE"
  printf '%s\n' '{"type":"cost-state","totalCostUSD":5,"modelUsage":{"claude-opus-5-5":{"costUSD":5}}}'; } > "$EST_NV"
snap_est WD-ESTNV "$EST_NV" >/dev/null
{ printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu_n2","name":"Agent","input":{"subagent_type":"wd-operator"}}]}}'
  printf '%s\n' '{"type":"cost-state","totalCostUSD":6,"modelUsage":{"claude-opus-5-5":{"costUSD":6}}}'; } >> "$EST_NV"
snap_est WD-ESTNV "$EST_NV" >/dev/null
assert_contains 'checkpoints: 2' "$( cd "$EST_PROJ" && bash "$SCRIPT" --story WD-ESTNV )" "a never-readable call next to a read one of the same type still records"

# A cost-state of 0 (a process seconds old) is no reading: the run is priced.
EST_Z="$TMP/est-zero.jsonl"
{ use_line z1 claude-opus-5-5 1000000 0 0 0 standard 01
  printf '%s\n' '{"type":"cost-state","totalCostUSD":0,"modelUsage":{}}'; } > "$EST_Z"
assert_contains '"cost_usd": 4' "$(snap_est WD-ESTZ "$EST_Z")" "a cost-state of 0 is ignored, the run is priced"

# Sub-agent output: Claude Code logs a placeholder (~8) at stream start. The
# final message is repaired from the task notification's subagent_tokens
# (context + output of the last call); any placeholder left marks the cub's
# cost as a lower bound.
EST_SO="$TMP/est-subout.jsonl"
mkdir -p "$TMP/est-subout/subagents"
{ use_line q1 claude-opus-5-5 10 8 0 0 standard 05
  use_line q2 claude-opus-5-5 10 8 1000 100 standard 06; } > "$TMP/est-subout/subagents/agent-aq1.jsonl"
printf '%s\n' '{"agentType":"wd-judge","toolUseId":"tu_q"}' > "$TMP/est-subout/subagents/agent-aq1.meta.json"
{ use_line m1 claude-opus-5-5 1000000 0 0 0 standard 01
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu_q","name":"Agent","input":{"subagent_type":"wd-judge"}}]}}'
  printf '%s\n' '{"type":"queue-operation","operation":"enqueue","timestamp":"2026-10-08T00:00:30Z","content":"<task-notification>\n<task-id>aq1</task-id>\n<tool-use-id>tu_q</tool-use-id>\n<usage><subagent_tokens>3110</subagent_tokens></usage>"}'; } > "$EST_SO"
EST_Q=$(snap_est WD-ESTQ "$EST_SO")
QF="$EST_PROJ/.workflow-dev/context/.usage/WD-ESTQ.json"
[[ "$(jq -r '.checkpoints[0].agents["wd-judge"].tokens.output' "$QF")" == "2008" ]] \
  && ok "the final sub-agent message's output is repaired from subagent_tokens (3110 - 1110 = 2000, + 8)" \
  || no "the final sub-agent message's output is repaired from subagent_tokens (got $(jq -r '.checkpoints[0].agents["wd-judge"].tokens.output' "$QF"))"
[[ "$(jq -r '.checkpoints[0].agents["wd-judge"].output_partial' "$QF")" == "true" ]] \
  && ok "a placeholder left in a side-chain marks the cub as a lower bound" \
  || no "a placeholder left in a side-chain marks the cub as a lower bound"
assert_contains 'a lower bound' "$EST_Q" "the summary line says the estimate is a lower bound"
assert_contains 'wd-judge: ≥$' "$( cd "$EST_PROJ" && bash "$SCRIPT" --story WD-ESTQ )" "--story marks a lower-bound cub with ≥"
[[ "$(jq -c '.checkpoints[0].agents["wd-judge"].models' "$QF")" == '["claude-opus-5-5"]' ]] \
  && ok "a cub lists each model once" || no "a cub lists each model once"

# A resumed agent: its first notification repairs the message it ended on,
# and keeps repairing it after the agent writes again — the output never
# falls back to the placeholder (which the ledger would read as a reset).
{ use_line q3 claude-opus-5-5 6100 8 0 0 standard 40; } >> "$TMP/est-subout/subagents/agent-aq1.jsonl"
snap_est WD-ESTQ "$EST_SO" >/dev/null
[[ "$(jq -r '.checkpoints | last | .agents["wd-judge"].tokens.output' "$QF")" == "2016" && "$(jq -r '.checkpoints | last | .segment' "$QF")" == "1" ]] \
  && ok "a resumed agent keeps its earlier repair (no fake reset)" \
  || no "a resumed agent keeps its earlier repair (got $(jq -c '.checkpoints | last | [.agents["wd-judge"].tokens.output, .segment]' "$QF"))"

# A notification quoted in a tool_result (a grep of a transcript) is text,
# not an event: another agent's figure on the same line is never taken.
EST_QQ="$TMP/est-quoted.jsonl"
mkdir -p "$TMP/est-quoted/subagents"
{ use_line k1 claude-opus-5-5 10 8 1000 100 standard 05; } > "$TMP/est-quoted/subagents/agent-ak1.jsonl"
printf '%s\n' '{"agentType":"wd-judge","toolUseId":"tu_k"}' > "$TMP/est-quoted/subagents/agent-ak1.meta.json"
{ use_line m1 claude-opus-5-5 10 0 0 0 standard 01
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu_k","name":"Agent","input":{"subagent_type":"wd-judge"}}]}}'
  printf '%s\n' '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu_other","content":"<task-id>ak1</task-id> <subagent_tokens>3110</subagent_tokens> <task-id>zz9</task-id> <subagent_tokens>90000</subagent_tokens>"}]}}'; } > "$EST_QQ"
snap_est WD-ESTK "$EST_QQ" >/dev/null
[[ "$(jq -r '.checkpoints[0].agents["wd-judge"].tokens.output' "$EST_PROJ/.workflow-dev/context/.usage/WD-ESTK.json")" == "8" ]] \
  && ok "a notification quoted in a tool_result is not read as one" \
  || no "a notification quoted in a tool_result is not read as one"

# The agent id comes from the call's own tool_result, never from its prompt.
EST_AP="$TMP/est-aid.jsonl"
mkdir -p "$TMP/est-aid/subagents"
use_line b1 claude-opus-5-5 100 0 0 0 > "$TMP/est-aid/subagents/agent-bbb.jsonl"
use_line a1 claude-opus-5-5 50000 0 0 0 > "$TMP/est-aid/subagents/agent-aaa.jsonl"
{ printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu_b2","name":"Agent","input":{"subagent_type":"y","prompt":"double-check what agentId: aaa found"}}]}}'
  printf '%s\n' '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu_b2","content":"Async agent launched. agentId: bbb"}]}}'; } > "$EST_AP"
snap_est WD-ESTP "$EST_AP" >/dev/null
[[ "$(jq -r '.checkpoints[0].agents.y.tokens.input' "$EST_PROJ/.workflow-dev/context/.usage/WD-ESTP.json")" == "100" ]] \
  && ok "an agentId quoted in a prompt is not taken for the call's own" \
  || no "an agentId quoted in a prompt is not taken for the call's own"

# A cost-state rewritten with the same total after a newer turn does not
# include that turn: the reading's position is where the total first appeared.
EST_RW="$TMP/est-rewrite.jsonl"
{ use_line w1 claude-opus-5-5 10 0 0 0 standard 01
  printf '%s\n' '{"type":"cost-state","totalCostUSD":5,"modelUsage":{"claude-opus-5-5":{"costUSD":5}}}'
  use_line w2 claude-opus-5-5 250000 0 0 0 standard 20
  printf '%s\n' '{"type":"cost-state","totalCostUSD":5,"modelUsage":{"claude-opus-5-5":{"costUSD":5}}}'; } > "$EST_RW"
EST_R=$(snap_est WD-ESTRW "$EST_RW")
assert_contains '"cost_usd": 6' "$EST_R" "a same-total cost-state rewritten after a turn still prices that turn"
assert_contains '"cost_basis": "estimated"' "$EST_R" "a same-total rewrite is not taken as up to date"

# Reconcile: a session whose last checkpoint was an estimate, and whose
# transcript later gets an exact cost-state, is settled by the next snapshot
# of the story from ANOTHER session — appended as `reconcile`, never edited.
RC_A="$TMP/rc-a.jsonl"; RC_B="$TMP/rc-b.jsonl"
use_line ra1 claude-opus-5-5 1000000 0 0 0 standard 01 > "$RC_A"          # estimate: $4
use_line rb1 claude-opus-5-5 250000 0 0 0 standard 01 > "$RC_B"           # estimate: $1
snap_est WD-RC "$RC_A" >/dev/null
printf '%s\n' '{"type":"cost-state","totalCostUSD":4.2,"modelUsage":{"claude-opus-5-5":{"costUSD":4.2}}}' >> "$RC_A"
RC_OUT=$(snap_est WD-RC "$RC_B")
RCF="$EST_PROJ/.workflow-dev/context/.usage/WD-RC.json"
assert_contains 'stage reconcile' "$RC_OUT" "a snapshot reconciles the story's other estimated session"
[[ "$(jq -r '[.checkpoints[] | select(.stage == "reconcile")] | length' "$RCF")" == "1" \
   && "$(jq -r '.checkpoints[0].cost_usd' "$RCF")" == "4" ]] \
  && ok "reconcile appends a checkpoint and leaves the earlier one as it was" \
  || no "reconcile appends a checkpoint and leaves the earlier one as it was"
assert_contains 'total: $5.2 ' "$( cd "$EST_PROJ" && bash "$SCRIPT" --story WD-RC )" "after reconcile the story total is the exact figure plus the other session"
( cd "$EST_PROJ" && env -u CLAUDE_CODE_SESSION_ID CLAUDECODE=1 bash "$SCRIPT" --reconcile WD-RC >/dev/null 2>&1 )
[[ "$(jq -r '[.checkpoints[] | select(.stage == "reconcile")] | length' "$RCF")" == "1" ]] \
  && ok "--reconcile is idempotent (an exact session is not reconciled again)" \
  || no "--reconcile is idempotent"

# The dashboard API: .usage/.index.json, one summary per story.
IDX="$EST_PROJ/.workflow-dev/context/.usage/.index.json"
[[ "$(jq -r '.schema' "$IDX" 2>/dev/null)" == "workflow-dev.usage/1" ]] && ok "the index carries its schema version" || no "the index carries its schema version"
[[ "$(jq -r '.stories["WD-RC"].total_usd' "$IDX")" == "5.2" && "$(jq -r '.stories["WD-RC"].sessions' "$IDX")" == "2" ]] \
  && ok "the index total matches --story" || no "the index total matches --story (got $(jq -c '.stories["WD-RC"] | [.total_usd, .sessions]' "$IDX"))"
[[ "$(jq -r '.stories["WD-RC"].lower_bound' "$IDX")" == "true" && "$(jq -r '.stories["WD-RC"].estimated' "$IDX")" == "true" ]] \
  && ok "the index flags a story whose latest reading of a session is an estimate" || no "the index flags estimates"
[[ "$(jq -r '.last_story' "$IDX")" == "WD-RC" ]] && ok "the index names the last story written" || no "the index names the last story written"
assert_contains 'invalid story id' "$( cd "$EST_PROJ" && bash "$SCRIPT" --story .index )" "the index can never be read as a story"

# Reconcile never takes spend the session did AFTER the story's checkpoint
# (it may belong to another story): no new work since → reconcile; new work →
# the estimate stays.
RC_C="$TMP/rc-c.jsonl"; RC_D="$TMP/rc-d.jsonl"
use_line rc1 claude-opus-5-5 1000000 0 0 0 standard 01 > "$RC_C"           # S1 estimate: $4
use_line rd1 claude-opus-5-5 10 0 0 0 standard 01 > "$RC_D"
snap_est WD-S1 "$RC_C" >/dev/null
use_line rc2 claude-opus-5-5 250000 0 0 0 standard 20 >> "$RC_C"           # the session moves on: $1 for S2
snap_est WD-S2 "$RC_C" >/dev/null
printf '%s\n' '{"type":"cost-state","totalCostUSD":5,"modelUsage":{"claude-opus-5-5":{"costUSD":5}}}' >> "$RC_C"
snap_est WD-S1 "$RC_D" >/dev/null                                           # another session snapshots S1
[[ "$(jq -r '[.checkpoints[] | select(.stage == "reconcile")] | length' "$EST_PROJ/.workflow-dev/context/.usage/WD-S1.json")" == "0" ]] \
  && ok "reconcile skips a session that kept working after the story's checkpoint" \
  || no "reconcile skips a session that kept working after the story's checkpoint"
( cd "$EST_PROJ" && env -u CLAUDE_CODE_SESSION_ID CLAUDECODE=1 bash "$SCRIPT" --reconcile WD-S1 >/dev/null 2>&1 )
assert_contains 'total: $4 ' "$( cd "$EST_PROJ" && bash "$SCRIPT" --story WD-S1 )" "another story's spend is never moved into this one"

# The index: a reconcile never makes an old story the "last" one; a corrupt
# ledger is skipped, not fatal; entries are keyed by file name, like --story.
IDX="$EST_PROJ/.workflow-dev/context/.usage/.index.json"
( cd "$EST_PROJ" && env -u CLAUDE_CODE_SESSION_ID CLAUDECODE=1 bash "$SCRIPT" --reconcile WD-RC >/dev/null 2>&1 )
[[ "$(jq -r '.stories["WD-RC"].last_stage' "$IDX")" != "reconcile" ]] \
  && ok "the index never reports reconcile as a story's last stage" || no "the index never reports reconcile as a story's last stage"
printf '{bad' > "$EST_PROJ/.workflow-dev/context/.usage/WD-BAD.json"
cp "$EST_PROJ/.workflow-dev/context/.usage/WD-S1.json" "$EST_PROJ/.workflow-dev/context/.usage/WD-S1.old.json"
snap_est WD-S1 "$RC_D" >/dev/null
[[ "$(jq -r '.stories["WD-S1"].total_usd' "$IDX")" == "$(jq -r '[.checkpoints[].delta | select(type=="number")] | add * 10000 | round / 10000' "$EST_PROJ/.workflow-dev/context/.usage/WD-S1.json")" \
   && "$(jq -r '.stories | has("WD-BAD")' "$IDX")" == "false" ]] \
  && ok "a corrupt ledger is skipped and the index stays current, keyed by file name" \
  || no "a corrupt ledger is skipped and the index stays current, keyed by file name"
rm -f "$EST_PROJ/.workflow-dev/context/.usage/WD-BAD.json" "$EST_PROJ/.workflow-dev/context/.usage/WD-S1.old.json"

# --reconcile with no value fails at once (it used to loop forever).
( cd "$EST_PROJ" && bash "$SCRIPT" --reconcile >/dev/null 2>&1 ) & RCPID=$!
sleep 3
if kill -0 "$RCPID" 2>/dev/null; then kill "$RCPID" 2>/dev/null; no "--reconcile with no value exits instead of looping"
else wait "$RCPID"; [[ $? -eq 2 ]] && ok "--reconcile with no value exits 2" || no "--reconcile with no value exits 2"; fi

# verified: every session's latest reading is the exact figure → the story's
# spend is verified, announced once, served by the index for a dashboard check.
VF="$TMP/vf.jsonl"
use_line vf1 claude-opus-5-5 1000000 0 0 0 standard 01 > "$VF"
VF1=$(snap_est WD-VF "$VF")
case "$VF1" in *"spend verified"*) no "an estimated story is not announced as verified" ;; *) ok "an estimated story is not announced as verified" ;; esac
[[ "$(jq -r '.stories["WD-VF"].verified' "$IDX")" == "false" ]] && ok "the index serves verified false for an estimate" || no "the index serves verified false for an estimate"
printf '%s\n' '{"type":"cost-state","totalCostUSD":4.1,"modelUsage":{"claude-opus-5-5":{"costUSD":4.1}}}' >> "$VF"
VF2=$(snap_est WD-VF "$VF")
assert_contains 'usage WD-VF · spend verified ✓ $4.1' "$VF2" "the checkpoint that makes a story exact announces it as verified"
[[ "$(jq -r '.stories["WD-VF"].verified' "$IDX")" == "true" && "$(jq -r '.stories["WD-VF"].lower_bound' "$IDX")" == "false" ]] \
  && ok "the index serves verified true (and no lower bound)" || no "the index serves verified true (and no lower bound)"
assert_contains 'verified: yes ✓' "$( cd "$EST_PROJ" && bash "$SCRIPT" --story WD-VF )" "--story says the spend is verified"
VF3=$(cd "$EST_PROJ" && env -u CLAUDE_CODE_SESSION_ID CLAUDECODE=1 bash "$SCRIPT" --reconcile WD-VF 2>&1)
case "$VF3" in *"spend verified"*) no "verified is announced once, not on every write" ;; *) ok "verified is announced once, not on every write" ;; esac
assert_contains 'verified: no' "$( cd "$EST_PROJ" && bash "$SCRIPT" --story WD-RC )" "--story says a story with an estimated session is not verified"

# verified is strict: (C2) an estimate left in an earlier segment, (C3) a
# session shared with another story, (N2) a sub-agent still writing after the
# cost-state — none of these is verified.
VS="$TMP/vs.jsonl"
{ use_line s1 claude-opus-5-5 10 0 0 0 standard 01
  printf '%s\n' '{"type":"cost-state","totalCostUSD":2,"modelUsage":{"claude-opus-5-5":{"costUSD":2}}}'
  use_line s2 claude-opus-5-5 50000 0 0 0 standard 05; } > "$VS"
snap_est WD-VS "$VS" >/dev/null                                             # estimate, segment 1
{ use_line s2 claude-opus-5-5 10 0 0 0 standard 06
  printf '%s\n' '{"type":"cost-state","totalCostUSD":3,"modelUsage":{"claude-opus-5-5":{"costUSD":3}}}'; } >> "$VS"
VS_OUT=$(snap_est WD-VS "$VS")                                              # tokens fell: segment 2, exact
[[ "$(jq -r '.stories["WD-VS"].verified_reason' "$IDX")" == "earlier-estimate" ]] \
  && ok "an estimate left in an earlier segment blocks verified" || no "an estimate left in an earlier segment blocks verified (got $(jq -r '.stories["WD-VS"].verified_reason' "$IDX"))"
case "$VS_OUT" in *"spend verified"*) no "no verified notice with an earlier estimate" ;; *) ok "no verified notice with an earlier estimate" ;; esac

VH="$TMP/vh.jsonl"
{ use_line h1 claude-opus-5-5 10 0 0 0 standard 01
  printf '%s\n' '{"type":"cost-state","totalCostUSD":2,"modelUsage":{"claude-opus-5-5":{"costUSD":2}}}'; } > "$VH"
snap_est WD-VHA "$VH" >/dev/null
printf '%s\n' '{"type":"cost-state","totalCostUSD":6,"modelUsage":{"claude-opus-5-5":{"costUSD":6}}}' >> "$VH"
VH_OUT=$(snap_est WD-VHB "$VH")
[[ "$(jq -r '.stories["WD-VHA"].verified_reason' "$IDX")" == "shared-session" && "$(jq -r '.stories["WD-VHB"].verified' "$IDX")" == "false" ]] \
  && ok "a session shared by two stories verifies neither" || no "a session shared by two stories verifies neither"
assert_contains 'shared with another story' "$( cd "$EST_PROJ" && bash "$SCRIPT" --story WD-VHB )" "--story explains why a shared session is not verified"

VP="$TMP/vp.jsonl"
mkdir -p "$TMP/vp/subagents"
use_line p1 claude-haiku-4-5 1000 0 0 0 standard 30 > "$TMP/vp/subagents/agent-ap1.jsonl"   # written after the cost-state
printf '%s\n' '{"agentType":"wd-operator","toolUseId":"tu_p"}' > "$TMP/vp/subagents/agent-ap1.meta.json"
{ use_line m1 claude-opus-5-5 10 0 0 0 standard 01
  printf '%s\n' '{"type":"assistant","timestamp":"2026-10-08T00:00:02Z","message":{"content":[{"type":"tool_use","id":"tu_p","name":"Agent","input":{"subagent_type":"wd-operator"}}]}}'
  printf '%s\n' '{"type":"cost-state","totalCostUSD":2,"modelUsage":{"claude-opus-5-5":{"costUSD":2}}}'; } > "$VP"
snap_est WD-VP "$VP" >/dev/null
[[ "$(jq -r '.checkpoints[-1].pending_sidechain' "$EST_PROJ/.workflow-dev/context/.usage/WD-VP.json")" == "true" \
   && "$(jq -r '.stories["WD-VP"].verified' "$IDX")" == "false" ]] \
  && ok "a sub-agent writing after the cost-state marks the reading pending, not verified" \
  || no "a sub-agent writing after the cost-state marks the reading pending, not verified"

# (C4) With no readable previous index, the rebuild is a silent baseline; and
# only the story this run touched is ever announced.
VQ="$TMP/vq.jsonl"
{ use_line q1 claude-opus-5-5 10 0 0 0 standard 01
  printf '%s\n' '{"type":"cost-state","totalCostUSD":1,"modelUsage":{"claude-opus-5-5":{"costUSD":1}}}'; } > "$VQ"
rm -f "$IDX"
VQ_OUT=$(snap_est WD-VQ "$VQ")
case "$VQ_OUT" in *"spend verified"*) no "a missing previous index announces nothing (baseline)" ;; *) ok "a missing previous index announces nothing (baseline)" ;; esac
[[ "$(jq -r '.stories["WD-VF"].verified' "$IDX")" == "true" ]] && ok "the baseline still serves verified" || no "the baseline still serves verified"
jq '.stories["WD-VF"].verified = false' "$IDX" > "$IDX.t" && mv "$IDX.t" "$IDX"   # pretend WD-VF was not verified before
VQ2=$(snap_est WD-VQ "$VQ")
case "$VQ2" in *"WD-VF"*) no "a story this run did not touch is never announced" ;; *) ok "a story this run did not touch is never announced" ;; esac

# (C1) OpenCode: a child session with no price makes the total partial.
VODB="$TMP/verified-oc.db"
sqlite3 "$VODB" <<SQL
CREATE TABLE session_v2 (id text primary key, parent_id text, directory text, title text,
  agent text, model text, cost real, tokens_input integer, tokens_output integer,
  tokens_reasoning integer, tokens_cache_read integer, tokens_cache_write integer,
  time_created integer, time_updated integer);
INSERT INTO session_v2 VALUES ('ses_vp',NULL,'$EST_PROJ','R','build','{"id":"m1"}',1.5,10,5,0,0,0,0,1);
INSERT INTO session_v2 VALUES ('ses_vc','ses_vp','$EST_PROJ','C','general','{"id":"m2"}',NULL,5000,500,0,0,0,0,1);
SQL
( cd "$EST_PROJ" && HOME="$TMP/nohome" OPENCODE_TERMINAL=1 OPENCODE_DB="$VODB" OPENCODE_SESSION_ID=ses_vp \
    bash "$SCRIPT" --snapshot WD-VOC --stage init >/dev/null 2>&1 )
[[ "$(jq -r '.stories["WD-VOC"].verified' "$IDX")" == "false" ]] \
  && ok "an OpenCode total with an unpriced child is not verified" || no "an OpenCode total with an unpriced child is not verified"

# The table reproduces real Claude Code charges: modelUsage from a real
# cost-state (WD-0043's session; Claude Code writes 1-hour cache entries).
REAL_MU='{"claude-sonnet-5-5":{"inputTokens":108,"outputTokens":973,"cacheReadInputTokens":308638,"cacheCreationInputTokens":21800,"costUSD":0.1588736},"claude-haiku-4-5-20251001":{"inputTokens":896,"outputTokens":14,"cacheReadInputTokens":0,"cacheCreationInputTokens":0,"costUSD":0.000966},"claude-opus-5-5":{"inputTokens":50,"outputTokens":10750,"cacheReadInputTokens":1926592,"cacheCreationInputTokens":80258,"costUSD":1.2425824}}'
OFF=$(jq -r --argjson mu "$REAL_MU" '
  .models as $t
  | [ $mu | to_entries[]
      | ($t[.key] // $t[(.key | sub("-[0-9]{8}$"; ""))]) as $r
      | ((.value.inputTokens * $r.input + .value.outputTokens * $r.output
          + .value.cacheReadInputTokens * $r.cache_read + .value.cacheCreationInputTokens * $r.cache_write_1h) / 1000000) as $est
      | select((($est - .value.costUSD) | fabs) > (.value.costUSD * 0.01)) | .key ] | join(",")' "$HERE/model-prices.json")
[[ -z "$OFF" ]] && ok "the price table reproduces real cost-state charges within 1%" || no "the price table reproduces real cost-state charges within 1% (off: $OFF)"

# --- 7: jq missing → clear failure, not a wrong number ----------------------
# Empty PATH that still runs bash by absolute path: the jq guard fires before
# any other external tool, so this is portable (unlike assuming /bin has no jq).
mkdir -p "$TMP/emptybin"
env PATH="$TMP/emptybin" "$BASH_ABS" "$SCRIPT" "$MAIN" >/dev/null 2>&1
[[ $? -eq 1 ]] && ok "exits 1 when jq is missing" || no "exits 1 when jq is missing"

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
