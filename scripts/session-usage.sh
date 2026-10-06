#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# session-usage.sh — report the token usage, cost, and wall-time of a workflow
# run, read from whichever harness ran it.
#
# Why this exists (WD-0007, AC 8): the workflow's cost is dominated by
# sub-agents, and nothing else exposes what they cost. Two harnesses, two
# sources — both read here, never guessed at:
#
#   * Claude Code — the session transcript (.jsonl). `message.usage` on the
#     main thread; each async Agent writes its own side-chain file (the
#     `output_file` named in its tool_result) with the same fields. Cost comes
#     from the transcript's last `cost-state` record (`totalCostUSD`), which
#     already includes the sub-agents; `modelUsage` splits it per model. An
#     older note here said "no cost field, so tokens only" — that was wrong.
#   * OpenCode — its SQLite store (`session_v2`). One row per session with
#     `cost` and `tokens_*`; a sub-agent is a child session (`parent_id`), so
#     per-sub-agent attribution (and cost) is exact, and no side-chain files to
#     lose. Read via `sqlite3`.
#
# IMPORTANT — the Claude transcript repeats usage per content block. The
# harness writes one JSONL record per assistant *content block* (thinking /
# text / tool_use), each carrying the *same* `message.id` and a byte-identical
# `usage` object (verified: 1096 usage records vs 602 distinct `message.id` in
# a real transcript). Summing records as-is overcounts a call 1–3×,
# non-uniformly, so the aggregation de-duplicates by `message.id` first.
#
# Best-effort by design, but never a wrong number: an unavailable source is
# reported as such, and a stale "newest transcript" guess is refused rather
# than reported as this run's. See REPO.md's "fail toward doing nothing rather
# than a false positive".
#
# Usage: session-usage.sh [--session <id>] [transcript.jsonl]
#   transcript.jsonl (Claude Code) — explicit path; without it the Claude
#     source is resolved (the newest transcript for this project, else a
#     story-tracked one when the project has none), each only if it was written
#     in the last 15 minutes — an older one is another run, and is refused
#     rather than reported as this one.
#   --session <id> — OpenCode only; without it, the current session
#     (OPENCODE_SESSION_ID, only when it validates for this directory) is used,
#     else the newest session for the current directory.
#   --sessions <id,id,…> — OpenCode: sum exactly these sessions. A session can
#     mix several stories, so this is the per-story attribution path: the story
#     records each sub-agent's session id and this totals just those.
#   --transcripts <path,path,…> — Claude Code: sum these transcripts plus each
#     one's side-chain sub-agents. The analogue of --sessions, for a story that
#     spanned several Claude sessions (the transcript path is the id there).
#   --snapshot <STORY-ID> --stage <stage> — normalize the current run (both
#     harnesses) and append a checkpoint to the story's durable ledger
#     (.workflow-dev/context/.usage/<STORY-ID>.json). Prints the normalized
#     object; the one-line tramo/acumulado summary goes to stderr.
#   --story <STORY-ID> — total a story from its ledger ONLY (the source is
#     never touched), across sessions and harnesses, by stage/session/agent.
#   OPENCODE_DB env var overrides the OpenCode database path (testing).

set -u

# The plugin root, so the one harness-detector (`list-models.sh --print-harness`)
# can be asked rather than re-deriving its signals here — a second copy could
# disagree with setup-models about which harness this is. `cd -P` resolves the
# OpenCode symlink; a logical `..` would stop at its parent.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PLUGIN_ROOT="$(cd -P "$SCRIPT_DIR/.." && pwd -P)"

have_jq() { command -v jq >/dev/null 2>&1; }
have_sqlite3() { command -v sqlite3 >/dev/null 2>&1; }
g() { printf '%s' "$1" | jq -r "$2"; }   # get a field from an AGG result
sqlq() { printf '%s' "${1//\'/\'\'}"; }  # quote a value for a SQL literal

TRANSCRIPT_ARG=""
SESSION_ARG=""
SESSIONS_ARG=""
TRANSCRIPTS_ARG=""
SNAPSHOT_STORY=""
SNAPSHOT_STAGE=""
STORY_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --session) SESSION_ARG="${2:-}"; shift 2 ;;
    --sessions) SESSIONS_ARG="${2:-}"; shift 2 ;;
    --transcripts) TRANSCRIPTS_ARG="${2:-}"; shift 2 ;;
    --snapshot) SNAPSHOT_STORY="${2:-}"; shift 2 ;;
    --stage) SNAPSHOT_STAGE="${2:-}"; shift 2 ;;
    --story) STORY_ARG="${2:-}"; shift 2 ;;
    *) TRANSCRIPT_ARG="$1"; shift ;;
  esac
done

# ---------------------------------------------------------------------------
# Claude Code: transcript (+ per-agent side-chain files)
# ---------------------------------------------------------------------------

resolve_claude() {
  local state_dir=".workflow-dev/context/.compaction-state" f p slug
  slug=$(pwd -P | sed 's#/#-#g')

  # The run's own transcript is the newest for this project, and only while it
  # is still being written. Prefer it: a tracked `.compaction-state` path can be
  # fresh yet belong to a run that just finished (or to another story's state
  # file), and letting it win would report that run's totals as this one's
  # (WD-0035) — freshness alone is not identity.
  p=$(ls -1t "$HOME/.claude/projects/$slug"/*.jsonl 2>/dev/null | head -1)
  if [[ -n "$p" && -f "$p" && -z "$(find "$p" -mmin +15 2>/dev/null)" ]]; then
    printf '%s\tnewest' "$p"
    return
  fi

  # No fresh transcript under this project: the tracked path is the fallback —
  # e.g. the session ran from a different cwd, so the slug lookup misses it —
  # and still only while its transcript is being written. Both state shapes are
  # read; the current one names it `claudePath`, the older one `transcriptPath`.
  if [[ -d "$state_dir" ]] && have_jq; then
    f=$(ls -1t "$state_dir"/*.json 2>/dev/null | head -1)
    if [[ -n "$f" ]]; then
      p=$(jq -r 'if (.claudePath // "") == "" then (.transcriptPath // "") else .claudePath end' "$f" 2>/dev/null)
      if [[ -n "$p" && -f "$p" && -z "$(find "$p" -mmin +15 2>/dev/null)" ]]; then printf '%s\ttracked' "$p"; fi
    fi
  fi
}

AGG='
  [ .[] | select(.message.usage) ] as $raw
  | ( reduce $raw[] as $r ({};
        if ($r.message.id // "") == "" then . else .[$r.message.id] = $r end) ) as $byid
  | ( [ $raw[] | select((.message.id // "") == "") ] ) as $noid
  | ( [ $byid[] ] + $noid ) as $m
  | {
      turns: ($m | length),
      input:  ([ $m[].message.usage.input_tokens // 0 ]  | add // 0),
      output: ([ $m[].message.usage.output_tokens // 0 ] | add // 0),
      cr:     ([ $m[].message.usage.cache_read_input_tokens // 0 ]     | add // 0),
      cc:     ([ $m[].message.usage.cache_creation_input_tokens // 0 ] | add // 0),
      first:  ($m | map(.timestamp) | map(select(. != null)) | min),
      last:   ($m | map(.timestamp) | map(select(. != null)) | max),
      byModel: ($m | group_by(.message.model) | map({
          model: (.[0].message.model // "unknown"),
          turns: length,
          input:  ([ .[].message.usage.input_tokens // 0 ]  | add // 0),
          output: ([ .[].message.usage.output_tokens // 0 ] | add // 0),
          cr:     ([ .[].message.usage.cache_read_input_tokens // 0 ]     | add // 0),
          cc:     ([ .[].message.usage.cache_creation_input_tokens // 0 ] | add // 0)
        }))
    }'

norm() { printf '%s' "$1" | cut -c1-19; }
elapsed() {
  [[ -n "$1" && -n "$2" ]] || { printf '?'; return; }
  jq -n --arg a "$(norm "$1")" --arg b "$(norm "$2")" \
    '($a+"Z"|fromdateiso8601) as $x | ($b+"Z"|fromdateiso8601) as $y | ($y-$x)' 2>/dev/null || printf '?'
}

# One row per Agent/Task call: label<TAB>output_file. Shared by the
# single-transcript report and the multi-transcript totals.
SIDECHAINS_JQ='
  . as $all
  | [ $all[] | .message.content? // empty | .[]?
      | select(.type? == "tool_use")
      | select(.name == "Agent" or .name == "Task")
      | { id: .id, label: (.input.description // .input.subagent_type // .name) } ] as $uses
  | [ $all[] | .message.content? // empty | .[]?
      | select(.type? == "tool_result")
      | { id: .tool_use_id,
          txt: (if (.content|type) == "string" then .content
                else ([ .content[]? | (.text? // "") ] | join("\n")) end) } ] as $res
  | $uses[]
  | . as $u
  | ( [ $res[] | select(.id == $u.id) | .txt ][0] // "" ) as $t
  | [ $u.label, ( ( $t | capture("output_file: (?<p>[^\\s]+)") | .p ) // "" ) ]
  | @tsv'

# Like SIDECHAINS_JQ, but the third column is the `subagent_type` — the per-cub
# key the snapshot groups by (AC 13), where the human report only needed a
# label. A call that named no subagent_type ran under the harness's default
# agent: reported as its own `default` cub, never folded into a role it did not
# actually run under.
SIDECHAINS3_JQ='
  . as $all
  | [ $all[] | .message.content? // empty | .[]?
      | select(.type? == "tool_use")
      | select(.name == "Agent" or .name == "Task")
      | { id: .id, stype: (.input.subagent_type // "default") } ] as $uses
  | [ $all[] | .message.content? // empty | .[]?
      | select(.type? == "tool_result")
      | { id: .tool_use_id,
          txt: (if (.content|type) == "string" then .content
                else ([ .content[]? | (.text? // "") ] | join("\n")) end) } ] as $res
  | $uses[]
  | . as $u
  | ( [ $res[] | select(.id == $u.id) | .txt ][0] // "" ) as $t
  | [ $u.stype, ( ( $t | capture("output_file: (?<p>[^\\s]+)") | .p ) // "" ) ]
  | @tsv'

claude_report() {
  local TRANSCRIPT="$1"
  echo "Workflow usage (Claude Code)"
  echo "Transcript: $TRANSCRIPT"
  echo
  local MAIN
  MAIN=$(jq -s "$AGG" "$TRANSCRIPT")
  echo "Main thread"
  printf '  turns: %s   wall: %s -> %s (%ss)\n' \
    "$(g "$MAIN" .turns)" "$(g "$MAIN" .first)" "$(g "$MAIN" .last)" \
    "$(elapsed "$(g "$MAIN" .first)" "$(g "$MAIN" .last)")"
  printf '  %-24s %6s %10s %10s %11s %13s\n' model turns input output cache_read cache_create
  printf '%s' "$MAIN" | jq -r '.byModel[] | "\(.model)\t\(.turns)\t\(.input)\t\(.output)\t\(.cr)\t\(.cc)"' \
    | while IFS=$'\t' read -r m t i o cr cc; do printf '  %-24s %6s %10s %10s %11s %13s\n' "$m" "$t" "$i" "$o" "$cr" "$cc"; done
  printf '%s' "$MAIN" | jq -r '"\(.turns)\t\(.input)\t\(.output)\t\(.cr)\t\(.cc)"' \
    | while IFS=$'\t' read -r t i o cr cc; do printf '  %-24s %6s %10s %10s %11s %13s\n' "TOTAL" "$t" "$i" "$o" "$cr" "$cc"; done
  echo

  local ROWS
  ROWS=$(jq -s -r "$SIDECHAINS_JQ" "$TRANSCRIPT")

  echo "Sub-agents (Agent/Task)"
  printf '  %-3s %-46s %6s %9s %9s %11s %13s %8s\n' "#" label turns input output cache_read cache_create 'wall(s)'
  local n=0 with=0 lost=0 GT=0 GI=0 GO=0 GCR=0 GCC=0
  while IFS=$'\t' read -r label of; do
    [[ -z "$label$of" ]] && continue
    n=$((n+1)); label=${label:0:46}
    local A=""
    if [[ -n "$of" && -f "$of" ]]; then A=$(jq -s "$AGG" "$of" 2>/dev/null) || A=""; fi
    if [[ -n "$A" ]]; then
      local t i o cr cc w
      t=$(g "$A" .turns); i=$(g "$A" .input); o=$(g "$A" .output); cr=$(g "$A" .cr); cc=$(g "$A" .cc)
      w=$(elapsed "$(g "$A" .first)" "$(g "$A" .last)")
      with=$((with+1)); GT=$((GT+t)); GI=$((GI+i)); GO=$((GO+o)); GCR=$((GCR+cr)); GCC=$((GCC+cc))
      printf '  %-3s %-46s %6s %9s %9s %11s %13s %8s\n' "$n" "$label" "$t" "$i" "$o" "$cr" "$cc" "$w"
    else
      lost=$((lost+1))
      if [[ -n "$of" && -f "$of" ]]; then printf '  %-3s %-46s %s\n' "$n" "$label" "- (side-chain unreadable)"
      else printf '  %-3s %-46s %s\n' "$n" "$label" "- (side-chain file unavailable)"; fi
    fi
  done <<< "$ROWS"
  echo "  $n sub-agent(s): $with with usage, $lost unavailable"
  echo
  printf 'Grand total (main + sub-agents)\n'
  printf '  input: %s  output: %s  cache_read: %s  cache_create: %s\n' \
    "$(( $(g "$MAIN" .input) + GI ))" "$(( $(g "$MAIN" .output) + GO ))" \
    "$(( $(g "$MAIN" .cr) + GCR ))" "$(( $(g "$MAIN" .cc) + GCC ))"
  [[ "$lost" -gt 0 ]] && printf '  (lower bound — excludes %s sub-agent(s) whose usage is unavailable)\n' "$lost"
}

# A transcript's totals INCLUDING its side-chain sub-agents: "in out cr cc n".
claude_totals() {
  local path="$1" MAIN ROWS
  MAIN=$(jq -s "$AGG" "$path")
  ROWS=$(jq -s -r "$SIDECHAINS_JQ" "$path")
  local GI=0 GO=0 GCR=0 GCC=0 n=0 A
  while IFS=$'\t' read -r label of; do
    [[ -z "$label$of" ]] && continue
    n=$((n + 1))
    A=""
    if [[ -n "$of" && -f "$of" ]]; then A=$(jq -s "$AGG" "$of" 2>/dev/null) || A=""; fi
    if [[ -n "$A" ]]; then
      GI=$((GI + $(g "$A" .input))); GO=$((GO + $(g "$A" .output)))
      GCR=$((GCR + $(g "$A" .cr)));  GCC=$((GCC + $(g "$A" .cc)))
    fi
  done <<< "$ROWS"
  printf '%s %s %s %s %s\n' \
    "$(( $(g "$MAIN" .input) + GI ))" "$(( $(g "$MAIN" .output) + GO ))" \
    "$(( $(g "$MAIN" .cr) + GCR ))" "$(( $(g "$MAIN" .cc) + GCC ))" "$n"
}

# Sum an explicit set of transcripts plus each one's side-chain sub-agents —
# the Claude Code analogue of OpenCode's `--sessions`, for attributing cost to
# a story that spanned several Claude sessions. (Claude Code has no per-session
# row to point at, so the transcript path is the identifier.)
transcripts_report() {
  local list="$1" path in out cr cc s
  echo "Workflow usage (Claude Code — explicit transcripts)"
  printf '  %-40s %9s %9s %11s %13s %8s\n' transcript input output cache_read cache_create 'sub-agts'
  local TI=0 TO=0 TCR=0 TCC=0 TS=0
  local OLDIFS="$IFS"; IFS=','
  for path in $list; do
    [[ -z "$path" ]] && continue
    if [[ ! -f "$path" ]]; then printf '  %-40s %s\n' "$(basename "$path")" "(not found)"; continue; fi
    IFS=$' \t' read -r in out cr cc s <<< "$(claude_totals "$path")"
    TI=$((TI + in)); TO=$((TO + out)); TCR=$((TCR + cr)); TCC=$((TCC + cc)); TS=$((TS + s))
    printf '  %-40s %9s %9s %11s %13s %8s\n' "$(basename "$path" | cut -c1-40)" "$in" "$out" "$cr" "$cc" "$s"
  done
  IFS="$OLDIFS"
  printf '  %-40s %9s %9s %11s %13s %8s\n' TOTAL "$TI" "$TO" "$TCR" "$TCC" "$TS"
}

# ---------------------------------------------------------------------------
# OpenCode: SQLite (session_v2)
# ---------------------------------------------------------------------------

# Explicit session list — the per-story attribution path: the story context
# records the session id of each sub-agent it spawned, and this sums exactly
# those, so cost is attributable to a story even when it spans sessions or
# harnesses (a session alone can mix several stories).
sessions_report() {
  local db="$1" list="$2" id row
  echo "Workflow usage (OpenCode — explicit sessions)"
  echo "Database: $db"
  printf '  %-46s %9s %8s %10s %11s %9s\n' session input output reasoning cache_read cost
  local TI=0 TO=0 TR=0 TCR=0 TC=0
  local OLDIFS="$IFS"; IFS=','
  for id in $list; do
    [[ -z "$id" ]] && continue
    row=$(sqlite3 -separator "$(printf '\t')" "$db" \
      "SELECT substr(id,1,44), tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, round(cost,4) FROM session_v2 WHERE id='$(sqlq "$id")';")
    if [[ -z "$row" ]]; then printf '  %-46s %s\n' "$id" "(not found)"; continue; fi
    local sid i o r cr c
    IFS=$'\t' read -r sid i o r cr c <<< "$row"
    TI=$((TI + i)); TO=$((TO + o)); TR=$((TR + r)); TCR=$((TCR + cr))
    TC=$(awk -v a="$TC" -v b="$c" 'BEGIN{printf "%.4f", a+b}')
    printf '  %-46s %9s %8s %10s %11s %9s\n' "$sid" "$i" "$o" "$r" "$cr" "$c"
  done
  IFS="$OLDIFS"
  printf '  %-46s %9s %8s %10s %11s %9s\n' TOTAL "$TI" "$TO" "$TR" "$TCR" "$TC"
}

# Which session is "this run"? The harness hands every shell command its own id
# in OPENCODE_SESSION_ID, so trust that when it is a top-level session of this
# directory — a stray value (another project's session, a sub-agent's child)
# must not point the default report at another run; otherwise the newest
# top-level session for the directory. Same rule as the save point's
# `resolve_opencode_session` (WD-0008), applied to the report (WD-0035).
opencode_default_session() {
  local db="$1" dir="$2" sid=""
  local clause="lower(rtrim(directory,'/'))=lower(rtrim('$(sqlq "$dir")','/'))"
  if [[ -n "${OPENCODE_SESSION_ID:-}" ]]; then
    # The id can be a sub-agent's child session (at any depth); walk up to the
    # run it belongs to before validating. A value that is not this directory's
    # top-level session is refused, not guessed at. `depth < 64` bounds the walk
    # so a corrupt parent cycle terminates instead of looping forever.
    sid=$(sqlite3 "$db" "SELECT id FROM session_v2 WHERE parent_id IS NULL AND ($clause) AND id = (WITH RECURSIVE up(id,parent_id,depth) AS (SELECT id,parent_id,0 FROM session_v2 WHERE id='$(sqlq "$OPENCODE_SESSION_ID")' UNION ALL SELECT s.id,s.parent_id,up.depth+1 FROM session_v2 s JOIN up ON s.id=up.parent_id WHERE up.depth < 64) SELECT id FROM up WHERE parent_id IS NULL LIMIT 1) LIMIT 1;")
  fi
  [[ -n "$sid" ]] || sid=$(sqlite3 "$db" "SELECT id FROM session_v2 WHERE ($clause) AND parent_id IS NULL ORDER BY time_updated DESC, id DESC LIMIT 1;")
  printf '%s' "$sid"
}

opencode_report() {
  local db="$1" dir="${PWD}" sid
  if [[ -n "$SESSION_ARG" ]]; then
    sid=$(sqlite3 "$db" "SELECT id FROM session_v2 WHERE id='$(sqlq "$SESSION_ARG")' LIMIT 1;")
    if [[ -z "$sid" ]]; then echo "No such session: $SESSION_ARG" >&2; exit 1; fi
  else
    # `directory` is stored as typed when the session started; a case-only
    # difference ($PWD can be lowercase where the DB has Projects) must still
    # match — SQLite's = is case-sensitive, so compare case-folded. The second
    # call retries with the physical path, in case a symlinked component
    # (/tmp → /private/tmp) changed the spelling the store recorded.
    sid=$(opencode_default_session "$db" "$dir")
    if [[ -z "$sid" ]]; then
      dir=$(pwd -P)
      sid=$(opencode_default_session "$db" "$dir")
    fi
  fi
  if [[ -z "$sid" ]]; then
    echo "No OpenCode session found for $PWD. Pass --session <id>." >&2
    exit 0
  fi

  local FMT="substr(id,1,12), coalesce(title,''), coalesce(agent,''), coalesce(json_extract(model,'\$.id'),''), \
             round(cost,4), tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, tokens_cache_write, \
             strftime('%Y-%m-%dT%H:%M:%SZ', time_created/1000, 'unixepoch'), \
             strftime('%Y-%m-%dT%H:%M:%SZ', time_updated/1000, 'unixepoch'), \
             COALESCE((SELECT (MAX(time_created)-MIN(time_created))/1000 FROM session_message WHERE session_id=session_v2.id), 0)"

  echo "Workflow usage (OpenCode)"
  echo "Database: $db"
  local row
  row=$(sqlite3 -separator "$(printf '\t')" "$db" "SELECT $FMT FROM session_v2 WHERE id='$(sqlq "$sid")';")
  IFS=$'\t' read -r s_id s_title s_agent s_model s_cost s_in s_out s_re s_cr s_cw s_c0 s_c1 s_wall <<< "$row"
  echo "Session: $sid  model: ${s_model:-?}  agent: ${s_agent:-?}"
  printf '  wall: %s -> %s (%ss)\n' "$s_c0" "$s_c1" "$s_wall"
  printf '  tokens: input %s  output %s  reasoning %s  cache_read %s  cache_write %s\n' "$s_in" "$s_out" "$s_re" "$s_cr" "$s_cw"
  printf '  cost: $%s\n' "$s_cost"
  echo

  echo "Sub-agents (child sessions)"
  printf '  %-3s %-38s %-8s %8s %7s %7s %10s %10s %8s %7s\n' \
    "#" title agent input output reasoning cache_read cache_write cost 'wall(s)'
  local n=0 TCOST=0 TIN=0 TOUT=0 TRE=0 TCR=0 TCW=0
  while IFS=$'\t' read -r c_id c_title c_agent c_model c_cost c_in c_out c_re c_cr c_cw c_t0 c_t1 c_wall; do
    [[ -z "$c_id" ]] && continue
    n=$((n+1))
    TCOST=$(awk -v a="$TCOST" -v b="$c_cost" 'BEGIN{printf "%.4f", a+b}')
    TIN=$((TIN + c_in)); TOUT=$((TOUT + c_out)); TRE=$((TRE + c_re)); TCR=$((TCR + c_cr)); TCW=$((TCW + c_cw))
    printf '  %-3s %-38s %-8s %8s %7s %7s %10s %10s %8s %7s\n' \
      "$n" "${c_title:0:38}" "${c_agent:0:8}" "$c_in" "$c_out" "$c_re" "$c_cr" "$c_cw" "$c_cost" "$c_wall"
  done < <(sqlite3 -separator "$(printf '\t')" "$db" "SELECT $FMT FROM session_v2 WHERE parent_id='$(sqlq "$sid")' ORDER BY time_updated;")
  echo "  $n sub-agent(s)"
  echo

  local GC; GC=$(awk -v a="$s_cost" -v b="$TCOST" 'BEGIN{printf "%.4f", a+b}')
  printf 'Grand total (session + sub-agents)\n'
  printf '  input: %s  output: %s  reasoning: %s  cache_read: %s  cache_write: %s\n' \
    "$((s_in + TIN))" "$((s_out + TOUT))" "$((s_re + TRE))" "$((s_cr + TCR))" "$((s_cw + TCW))"
  printf '  cost: $%s\n' "$GC"
}

# ---------------------------------------------------------------------------
# Snapshot: one normalized checkpoint of the current run (both harnesses)
# ---------------------------------------------------------------------------

# The common object both adapters emit. `cost_usd` is a number, or null when
# the source carries no price — never an invented 0. The extra `agents` map
# (per agent/role: cost, tokens, models) is what lets `--story` keep rendering
# the breakdown after the source itself is gone; it is stored, not recomputed.
#
# `source` is the ses_… id (OpenCode) or the transcript path (Claude); the two
# never collide, so a story that spans both harnesses sums with no special
# case, and the per-`source` `prev` checkpoint stays harness-agnostic.

# Ask the one owner of harness detection — never re-derive the signals.
detect_harness_for_usage() {
  "$PLUGIN_ROOT"/scripts/list-models.sh --print-harness 2>/dev/null || printf ''
}

# OpenCode: the resolved top-level session plus its WHOLE recursive tree — the
# human report sums only direct children, which undercounts a grandchild. Every
# row in the tree is counted once; its own row is the `orchestrator` cub, each
# descendant is grouped by its `agent` column.
snapshot_opencode() {
  local db="$1" sid="$2" tree
  # `depth < 64` bounds the recursion: a corrupt parent cycle would otherwise
  # loop forever (UNION ALL does not dedupe a growing depth). Real trees are 1–2.
  tree="WITH RECURSIVE tree(id,depth) AS (SELECT id,0 FROM session_v2 WHERE id='$(sqlq "$sid")' UNION ALL SELECT s.id,t.depth+1 FROM session_v2 s JOIN tree t ON s.parent_id=t.id WHERE t.depth < 64)"
  {
    sqlite3 -separator "$(printf '\t')" "$db" "$tree SELECT 'total','',round(sum(cost),6),coalesce(sum(tokens_input),0),coalesce(sum(tokens_output),0),coalesce(sum(tokens_reasoning),0),coalesce(sum(tokens_cache_read),0),coalesce(sum(tokens_cache_write),0),coalesce(strftime('%Y-%m-%dT%H:%M:%SZ',max(time_updated)/1000,'unixepoch'),'') FROM session_v2 WHERE id IN (SELECT id FROM tree);"
    sqlite3 -separator "$(printf '\t')" "$db" "$tree SELECT 'model',coalesce(nullif(json_extract(model,'\$.id'),''),'unknown'),round(sum(cost),6),coalesce(sum(tokens_input),0),coalesce(sum(tokens_output),0),coalesce(sum(tokens_reasoning),0),coalesce(sum(tokens_cache_read),0),coalesce(sum(tokens_cache_write),0),'' FROM session_v2 WHERE id IN (SELECT id FROM tree) GROUP BY 2;"
    sqlite3 -separator "$(printf '\t')" "$db" "$tree SELECT 'agent',coalesce(nullif(agent,''),'unknown'),round(sum(cost),6),coalesce(sum(tokens_input),0),coalesce(sum(tokens_output),0),coalesce(sum(tokens_reasoning),0),coalesce(sum(tokens_cache_read),0),coalesce(sum(tokens_cache_write),0),coalesce(group_concat(DISTINCT nullif(json_extract(model,'\$.id'),'')),'') FROM session_v2 WHERE id IN (SELECT id FROM tree) AND id <> '$(sqlq "$sid")' GROUP BY 2;"
    sqlite3 -separator "$(printf '\t')" "$db" "SELECT 'orch','',round(sum(cost),6),coalesce(sum(tokens_input),0),coalesce(sum(tokens_output),0),coalesce(sum(tokens_reasoning),0),coalesce(sum(tokens_cache_read),0),coalesce(sum(tokens_cache_write),0),coalesce(group_concat(DISTINCT nullif(json_extract(model,'\$.id'),'')),'') FROM session_v2 WHERE id='$(sqlq "$sid")';"
  } | jq -R -s --arg src "$sid" '
    # A NULL `cost` prints as an empty field: a source with no price stays
    # null, never a fabricated 0 (AC 6).
    def num: if . == "" or . == null then null else tonumber end;
    [ split("\n")[] | select(length>0) | split("\t") ] as $rows
    | ($rows | map(select(.[0]=="total"))[0]) as $t
    | ($rows | map(select(.[0]=="orch"))[0]) as $o
    | ( reduce ($rows[] | select(.[0]=="model")) as $r ({};
          .[$r[1]] = { cost_usd: ($r[2]|num),
            tokens: { input:($r[3]|tonumber), output:($r[4]|tonumber), reasoning:($r[5]|tonumber), cache_read:($r[6]|tonumber), cache_write:($r[7]|tonumber) } }) ) as $models
    | ( reduce ($rows[] | select(.[0]=="agent")) as $r ({};
          .[$r[1]] = { cost_usd: ($r[2]|num),
            tokens: { input:($r[3]|tonumber), output:($r[4]|tonumber), reasoning:($r[5]|tonumber), cache_read:($r[6]|tonumber), cache_write:($r[7]|tonumber) },
            models: (($r[8] // "") | if . == "" then [] else split(",") end) }) ) as $child
    | ( $child | .orchestrator = { cost_usd: ($o[2]|num),
          tokens: { input:($o[3]|tonumber), output:($o[4]|tonumber), reasoning:($o[5]|tonumber), cache_read:($o[6]|tonumber), cache_write:($o[7]|tonumber) },
          models: (($o[8] // "") | if . == "" then [] else split(",") end) } ) as $agents
    | { source: $src, harness: "opencode", cost_usd: ($t[2]|num),
        tokens: { input:($t[3]|tonumber), output:($t[4]|tonumber), reasoning:($t[5]|tonumber), cache_read:($t[6]|tonumber), cache_write:($t[7]|tonumber) },
        models: $models, agents: $agents, as_of: $t[8] }'
}

# Claude Code: cost and the sub-agent-inclusive total come from the last
# `cost-state` record (`totalCostUSD`, `modelUsage`); tokens come from
# `message.usage` (deduped by `message.id`, same rule as `claude_totals`) on the
# main transcript plus each readable side-chain. `cost_usd` is null when no
# `cost-state` has been written yet — the freshness of that record is why a
# checkpoint belongs at a turn boundary.
snapshot_claude() {
  local path="$1" in out cr cc n cost mu tsv bymodel models mainjson agents as_of
  read -r in out cr cc n <<< "$(claude_totals "$path")"

  cost=$(jq -c 'select(.type=="cost-state") | .totalCostUSD' "$path" 2>/dev/null | tail -1)
  [[ -n "$cost" ]] || cost=null
  mu=$(jq -c 'select(.type=="cost-state") | .modelUsage' "$path" 2>/dev/null | tail -1)
  [[ -n "$mu" ]] || mu='{}'

  tsv=$(jq -s -r "$SIDECHAINS3_JQ" "$path")

  bymodel=$(
    {
      jq -s "$AGG" "$path"
      local f
      while IFS=$'\t' read -r _ f; do
        [[ -z "$f" ]] && continue
        if [[ -f "$f" ]]; then jq -s "$AGG" "$f" 2>/dev/null || echo null; else echo null; fi
      done <<< "$tsv"
    } | jq -s '
        [ .[] | select(. != null) | .byModel[] ] as $m
        | ( $m | group_by(.model) | map({ key: .[0].model,
              value: { tokens: { input: (map(.input)|add // 0), output: (map(.output)|add // 0),
                reasoning: 0, cache_read: (map(.cr)|add // 0), cache_write: (map(.cc)|add // 0) } } })
          | from_entries )'
  )
  [[ -n "$bymodel" ]] || bymodel='{}'

  models=$(jq -n --argjson mu "$mu" --argjson bm "$bymodel" '
    ( $bm | with_entries(.value.cost_usd = ($mu[.key].costUSD // null)) )
    | reduce (($mu // {}) | keys[]) as $k (.;
        if has($k) then . else .[$k] = { cost_usd: ($mu[$k].costUSD // null),
          tokens: {input:0,output:0,reasoning:0,cache_read:0,cache_write:0} } end)')

  mainjson=$(jq -s "$AGG" "$path")

  # One cub per subagent_type (a repeated type accumulates), plus the
  # orchestrator. Claude Code writes no per-agent price, so an agent cub's cost
  # is null — only the run total is priced.
  agents=$(
    {
      printf '%s\t%s\n' "orchestrator" "$(printf '%s' "$mainjson" | jq -c '.byModel')"
      while IFS=$'\t' read -r stype f; do
        [[ -z "$stype" ]] && continue
        if [[ -n "$f" && -f "$f" ]]; then
          printf '%s\t%s\n' "$stype" "$(jq -s "$AGG" "$f" 2>/dev/null | jq -c '.byModel')"
        else
          printf '%s\t%s\n' "$stype" "[]"
        fi
      done <<< "$tsv"
    } | jq -R -s '
        [ split("\n")[] | select(length>0) | split("\t") ]
        | reduce .[] as $r ({};
            ($r[1] | fromjson) as $bm
            | ($bm | { input: (map(.input)|add // 0), output: (map(.output)|add // 0),
                  cache_read: (map(.cr)|add // 0), cache_write: (map(.cc)|add // 0) }) as $tk
            | (if has($r[0]) then .[$r[0]] else
                 .[$r[0]] = { cost_usd: null, tokens: {input:0,output:0,reasoning:0,cache_read:0,cache_write:0}, models: [] } end)
            | .[$r[0]].tokens.input += $tk.input
            | .[$r[0]].tokens.output += $tk.output
            | .[$r[0]].tokens.cache_read += $tk.cache_read
            | .[$r[0]].tokens.cache_write += $tk.cache_write
            | .[$r[0]].models += ($bm | map(.model)) )'
  )
  [[ -n "$agents" ]] || agents='{}'

  as_of=$(printf '%s' "$mainjson" | jq -r '.last // ""')
  [[ "$as_of" != "null" ]] || as_of=""

  jq -n --arg src "$path" --argjson cost "$cost" --argjson models "$models" \
    --argjson agents "$agents" --argjson inp "$in" --argjson outp "$out" \
    --argjson cr "$cr" --argjson cc "$cc" --arg asof "$as_of" '
    { source: $src, harness: "claude", cost_usd: $cost,
      tokens: { input: $inp, output: $outp, reasoning: 0, cache_read: $cr, cache_write: $cc },
      models: $models, agents: $agents, as_of: $asof }'
}

# ---------------------------------------------------------------------------
# Ledger: a durable per-story store of checkpoints (survives the source)
# ---------------------------------------------------------------------------

# `.workflow-dev/context/.usage/<STORY>.json`, one doc per story. A checkpoint
# is a photo of the accumulated total at an instant: it stores the absolute
# (`abs`) and the `delta` against the previous checkpoint of the SAME `source`
# (same OpenCode session / same Claude transcript). The story total is the sum
# of the deltas — computed from the ledger, never from a source that may be
# gone. The previous checkpoint IS the "before", so nothing has to be
# remembered between reads, and pairing is by `source`, not by run.
USAGE_DIR=".workflow-dev/context/.usage"

# A story id names a file under `.usage/`, so it must not carry a path
# separator or be `.`/`..` — otherwise `--snapshot`/`--story` could read or write
# outside the store. The workflow only ever passes `WD-NNNN`, but the script is
# a CLI and must not trust its argument.
valid_story_id() {
  case "$1" in
    ""|.|..|*/*) return 1 ;;
    *) return 0 ;;
  esac
}

# Record one checkpoint and report the tramo/acumulado. Idempotent on
# `source|stage|run_marker`; a reset (`abs` fell) starts a new segment so the
# accumulated total is never corrupted, and an unpriced checkpoint never moves
# the priced baseline (so priced→unpriced→priced does not double-count). Prints
# a one-line human summary to stderr; stdout stays free for the caller's output.
ledger_record() {
  local story="$1" stage="$2" snap="$3"
  if ! valid_story_id "$story"; then
    printf 'usage: refusing an invalid story id %q (must be a bare name)\n' "$story" >&2
    return 1
  fi
  mkdir -p -m 700 "$USAGE_DIR" 2>/dev/null
  local file="$USAGE_DIR/$story.json"
  local existing
  if [[ -f "$file" ]]; then
    existing=$(cat "$file")
    if ! printf '%s' "$existing" | jq -e . >/dev/null 2>&1; then
      # Fail toward doing nothing: a corrupt ledger is never silently replaced
      # — that would destroy recorded spend and report the reduced total as
      # authoritative. Refuse, and leave the file for the human.
      printf 'usage: %s is not valid JSON — refusing to overwrite it; checkpoint NOT recorded\n' "$file" >&2
      return 1
    fi
  else
    existing='{"story":"'"$story"'","checkpoints":[]}'
  fi

  local entry mark
  mark=$(printf '%s' "$snap" | jq -r '[.cost_usd, .tokens.input, .tokens.output, .tokens.reasoning, .tokens.cache_read, .tokens.cache_write] | @csv' | shasum | cut -c1-12)
  entry=$(printf '%s' "$snap" | jq -c --arg stage "$stage" --arg mark "$mark" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '. + { stage: $stage, run_marker: $mark, recorded_at: $at }')

  local result
  result=$(jq -n --argjson doc "$existing" --argjson e "$entry" --arg story "$story" '
    def cps: ($doc.checkpoints // []);
    ( cps | map(select(.source == $e.source)) ) as $same
    | ( cps | map(select(.source == $e.source)) | last ) as $prev
    # The last checkpoint of this source that CARRIED a price (any segment) —
    # used only to detect a falling price.
    | ( $same | map(select(.cost_usd != null)) | last ) as $lastp
    # A duplicate is an UNCHANGED state since the immediately previous
    # checkpoint of this source — NOT a match anywhere in history: a reset can
    # land on a byte-identical tuple of an older checkpoint, and matching it
    # there would silently swallow the reset instead of opening a new segment.
    | ( if $prev != null and $prev.stage == $e.stage and $prev.run_marker == $e.run_marker
        then $prev else null end ) as $dupe
    | if $dupe != null then
        { action: "duplicate", doc: $doc, entry: $dupe }
      else
        # A falling token counter is itself an unambiguous reset, even when the
        # source carries no price — otherwise the token delta goes negative.
        ( $prev != null and (
              $e.tokens.input       < $prev.tokens.input or
              $e.tokens.output      < $prev.tokens.output or
              $e.tokens.reasoning   < $prev.tokens.reasoning or
              $e.tokens.cache_read  < $prev.tokens.cache_read or
              $e.tokens.cache_write < $prev.tokens.cache_write ) ) as $treset
        # A price that fell below the last priced reading is a reset too (AC 8).
        | ( $e.cost_usd != null and $lastp != null and $e.cost_usd < $lastp.cost_usd ) as $costfall
        | ( $treset or $costfall ) as $reset
        | ( if $reset then (($prev.segment // 0) + 1)
            elif $prev == null then 1
            else ($prev.segment // 1) end ) as $segment
        # The delta baseline is the last priced checkpoint WITHIN THE CURRENT
        # SEGMENT: a resume after an unpriced checkpoint continues the segment
        # (so the delta is real), but a resume after a reset starts a new one
        # with no baseline (so the delta is the whole `abs`, not a delta across
        # the reset).
        | ( $same | map(select(.cost_usd != null and (.segment // 1) == $segment)) | last ) as $prevp
        | ( if $e.cost_usd == null then null
            elif $prevp == null then $e.cost_usd
            else ($e.cost_usd - $prevp.cost_usd) end ) as $delta
        # Token deltas use the immediately preceding checkpoint (tokens exist
        # whether or not the source is priced). They restart only when the
        # tokens themselves fell — a cost-only reset (AC 8) must not inflate
        # the token total.
        | ( if $prev == null or $treset then $e.tokens
            else { input: ($e.tokens.input - $prev.tokens.input),
                   output: ($e.tokens.output - $prev.tokens.output),
                   reasoning: ($e.tokens.reasoning - $prev.tokens.reasoning),
                   cache_read: ($e.tokens.cache_read - $prev.tokens.cache_read),
                   cache_write: ($e.tokens.cache_write - $prev.tokens.cache_write) } end ) as $td
        | ( $e.agents // {} ) as $ag
        | ( if $prevp == null then {} else ($prevp.agents // {}) end ) as $pcost
        | ( if $treset or $prev == null then {} else ($prev.agents // {}) end ) as $ptok
        | ( reduce ($ag | keys[]) as $k ({};
              ($ag[$k]) as $cur
              | ($pcost[$k] // null) as $oc
              | ($ptok[$k] // null) as $ot
              | .[$k] = {
                  cost_usd: ( if $cur.cost_usd == null then null
                              elif ($oc == null or $oc.cost_usd == null) then $cur.cost_usd
                              else ($cur.cost_usd - $oc.cost_usd) end ),
                  tokens: ( if $ot == null then $cur.tokens
                            else { input: ($cur.tokens.input - $ot.tokens.input),
                                   output: ($cur.tokens.output - $ot.tokens.output),
                                   reasoning: ($cur.tokens.reasoning - $ot.tokens.reasoning),
                                   cache_read: ($cur.tokens.cache_read - $ot.tokens.cache_read),
                                   cache_write: ($cur.tokens.cache_write - $ot.tokens.cache_write) } end ),
                  models: ($cur.models // []) } ) ) as $ad
        | ( $e + { segment: $segment, delta: $delta, token_delta: $td, agent_deltas: $ad } ) as $new
        | { action: "appended",
            doc: ($doc + { story: $story, checkpoints: (cps + [$new]) }),
            entry: $new }
      end')

  local action doc
  action=$(printf '%s' "$result" | jq -r '.action')
  doc=$(printf '%s' "$result" | jq -c '.doc')
  if [[ "$action" == "appended" ]]; then
    local tmp=""
    if ! tmp=$(mktemp "$USAGE_DIR/.$story.XXXXXX") || ! printf '%s' "$doc" | jq '.' > "$tmp" || ! mv "$tmp" "$file"; then
      rm -f "$tmp" 2>/dev/null
      printf 'usage: could not write the ledger at %s — checkpoint NOT recorded\n' "$file" >&2
      return 1
    fi
    chmod 600 "$file" 2>/dev/null
  fi

  local tramo total nst unpriced
  tramo=$(printf '%s' "$result" | jq -r '.entry.delta // "?"')
  total=$(printf '%s' "$doc" | jq -r '[.checkpoints[].delta | select(type=="number")] | add // 0')
  nst=$(( $(printf '%s' "$doc" | jq -r '.checkpoints | length') ))
  unpriced=$(printf '%s' "$doc" | jq -r '[.checkpoints[] | select(.cost_usd == null)] | length')

  local atom accum
  atom=$([[ "$tramo" == "?" ]] && printf 'unknown' || printf '$%s' "$tramo")
  accum=$(awk -v t="$total" 'BEGIN{printf "$%.4f", t}')
  printf 'usage %s · stage %s · this step %s · story total %s over %s checkpoint(s), %s without price\n' \
    "$story" "$stage" "$atom" "$accum" "$nst" "$unpriced" >&2
}

# Totalise a story from the ledger ONLY — never touching the source, so a
# deleted session row or transcript changes nothing. Sums both harnesses, breaks
# the spend down by stage, session and agent/role (the cubs are whatever
# actually ran), shows the configured role→model binding, marks config-vs-
# observed discrepancies, and states how many runs carried no price.
ledger_report() {
  local story="$1"
  if ! valid_story_id "$story"; then
    echo "Story usage: unavailable — invalid story id"
    return 0
  fi
  if ! have_jq; then
    echo "Story usage: unavailable — jq is required" >&2
    return 1
  fi
  local file="$USAGE_DIR/$story.json"
  if [[ ! -f "$file" ]]; then
    echo "Story usage: unavailable — no checkpoints recorded for $story in $USAGE_DIR"
    return 0
  fi
  echo "Story usage: $story"
  printf '  ledger: %s\n' "$file"

  jq -r '
    (.checkpoints // []) as $c
    | ( [ $c[].delta | select(type=="number") ] | add // 0 ) as $total
    | "  total: $\($total * 10000 | round / 10000)   checkpoints: \($c | length)   runs without price: \([ $c[] | select(.cost_usd == null) ] | length)",
      ("  tokens: input \([ $c[].token_delta.input // 0 ] | add // 0)  output \([ $c[].token_delta.output // 0 ] | add // 0)  reasoning \([ $c[].token_delta.reasoning // 0 ] | add // 0)  cache_read \([ $c[].token_delta.cache_read // 0 ] | add // 0)  cache_write \([ $c[].token_delta.cache_write // 0 ] | add // 0)"),
      "  by harness:",
      ( [ $c[] | { h: .harness, d: (.delta // 0) } ] | group_by(.h)[] | "    \(.[0].h): $\(([.[].d] | add // 0) * 10000 | round / 10000)" ),
      "  by stage:",
      ( [ $c[] | { s: .stage, d: (.delta // 0) } ] | group_by(.s)[] | "    \(.[0].s): $\(([.[].d] | add // 0) * 10000 | round / 10000)" ),
      "  by session:",
      ( [ $c[] | { src: .source, d: (.delta // 0) } ] | group_by(.src)[] | "    \(.[0].src): $\(([.[].d] | add // 0) * 10000 | round / 10000)" ),
      "  by agent/role (observed — derived from what ran, never a fixed list):",
      ( [ $c[].agent_deltas // {} | to_entries[] | { k: .key, d: .value.cost_usd, m: (.value.models // []) } ]
        | group_by(.k)[]
        | ( [ .[].d | select(. != null) ] ) as $ds
        | "    \(.[0].k): " + (if ($ds | length) == 0 then "unpriced" else "$\(($ds | add) * 10000 | round / 10000)" end) + "  models \([.[].m[]] | unique | join(", "))" ),
      "  last step:",
      ( $c | last | "    stage \(.stage)  +" + (if .delta == null then "unpriced" else "$\(.delta * 10000 | round / 10000)" end) + "  " + ( [ (.agent_deltas // {}) | to_entries[] | "\(.key) " + (if .value.cost_usd == null then "unpriced" else "+$\(.value.cost_usd * 10000 | round / 10000)" end) ] | join("; ") ) )
  ' "$file"

  # The configured role→model binding is WD-0025's reader (extended into
  # model-tiering-check.sh so there is exactly one parser), rendered here.
  local binding configured observed
  binding=$("$PLUGIN_ROOT"/scripts/model-tiering-check.sh --role-models 2>/dev/null)
  echo "  configured binding (role → model):"
  if [[ -z "$binding" ]]; then
    echo "    (no roles: the registry is unreadable, or has no role headings)"
  else
    while IFS=$'\t' read -r role state model; do
      [[ -z "$role" ]] && continue
      case "$state" in
        bound)   printf '    %s → %s (bound)\n' "$role" "$model" ;;
        opt-out) printf '    %s → default (tiering opted out)\n' "$role" ;;
        default) printf '    %s → default (role ungenerated, stale, or with no model)\n' "$role" ;;
        *)       printf '    %s → unreadable (no harness signal)\n' "$role" ;;
      esac
    done <<< "$binding"
  fi

  echo "  discrepancies (configured vs observed):"
  observed=$(jq -r '[.checkpoints[].agent_deltas // {} | keys[]] | unique | .[]' "$file")
  configured=$(printf '%s' "$binding" | cut -f1)
  local any=0 cub role
  while IFS= read -r cub; do
    [[ -z "$cub" || "$cub" == "orchestrator" ]] && continue
    if ! printf '%s\n' "$configured" | grep -Fxq "$cub"; then
      printf '    ! spend observed under "%s", which is not a configured role\n' "$cub"
      any=1
    fi
  done <<< "$observed"
  while IFS= read -r role; do
    [[ -z "$role" ]] && continue
    if ! printf '%s\n' "$observed" | grep -Fxq "$role"; then
      printf '    - role "%s" configured but no spend observed under it\n' "$role"
      any=1
    fi
  done <<< "$configured"
  [[ "$any" -eq 1 ]] || echo "    none"

  echo "  change a role's model with /workflow-dev:setup-models"
}

# ---------------------------------------------------------------------------
# Resolve a source, then report
# ---------------------------------------------------------------------------

# An explicit selector names its own source and must win over the implicit
# resolution below. These branches used to sit *after* `resolve_claude` and the
# `claude_report` that exits, so whenever a Claude transcript was resolvable
# (the project root inside a live session) `--transcripts` / `--sessions` /
# `--session` were silently ignored and the report described the wrong run.
# That is the cause of the two `session-usage.test.sh` assertions failing from
# the project root and passing from `/tmp`: from `/tmp` no transcript resolves,
# so the explicit selector was finally reached.
OPENCODE_DB_PATH="${OPENCODE_DB:-$HOME/.local/share/opencode/opencode.db}"

# A snapshot is its own entry point: it resolves the current run, normalizes it,
# and never falls through to the human reports below. It dispatches on the one
# harness detector; when the run cannot be resolved it answers `unavailable`
# rather than a misleading zero.
if [[ -n "$SNAPSHOT_STORY" ]]; then
  if ! have_jq; then
    echo '{"status":"unavailable","reason":"jq required"}'
    exit 0
  fi
  SNAP=""
  SNAP_TX=""
  case "$(detect_harness_for_usage)" in
    opencode)
      if have_sqlite3 && [[ -f "$OPENCODE_DB_PATH" ]]; then
        SNAP_SID=""
        if [[ -n "$SESSION_ARG" ]]; then
          SNAP_SID=$(sqlite3 "$OPENCODE_DB_PATH" "SELECT id FROM session_v2 WHERE id='$(sqlq "$SESSION_ARG")' LIMIT 1;")
        else
          SNAP_SID=$(opencode_default_session "$OPENCODE_DB_PATH" "$PWD")
          [[ -n "$SNAP_SID" ]] || SNAP_SID=$(opencode_default_session "$OPENCODE_DB_PATH" "$(pwd -P)")
        fi
        [[ -n "$SNAP_SID" ]] && SNAP=$(snapshot_opencode "$OPENCODE_DB_PATH" "$SNAP_SID")
      fi
      ;;
    claude)
      if [[ -n "$TRANSCRIPT_ARG" ]]; then
        [[ -f "$TRANSCRIPT_ARG" ]] && SNAP_TX="$TRANSCRIPT_ARG"
      else
        SNAP_R="$(resolve_claude)"
        [[ "$SNAP_R" == *$'\t'* ]] && SNAP_TX="${SNAP_R%%$'\t'*}"
      fi
      [[ -n "$SNAP_TX" ]] && SNAP=$(snapshot_claude "$SNAP_TX")
      ;;
  esac
  if [[ -z "$SNAP" ]]; then
    echo '{"status":"unavailable"}'
    exit 0
  fi
  ledger_record "$SNAPSHOT_STORY" "${SNAPSHOT_STAGE:-manual}" "$SNAP"
  printf '%s\n' "$SNAP" | jq '{ source, harness, cost_usd, tokens, models, as_of }'
  exit 0
fi

# `--story` totals from the ledger alone — the source is never consulted, so a
# deleted session row or transcript cannot change the answer.
if [[ -n "$STORY_ARG" ]]; then
  ledger_report "$STORY_ARG"
  exit 0
fi

if [[ -n "$TRANSCRIPT_ARG" ]]; then
  if [[ ! -f "$TRANSCRIPT_ARG" ]]; then echo "Not a file: $TRANSCRIPT_ARG" >&2; exit 1; fi
  have_jq || { echo "session-usage.sh needs jq for the Claude Code transcript path." >&2; exit 1; }
  claude_report "$TRANSCRIPT_ARG"
  exit 0
fi

if [[ -n "$TRANSCRIPTS_ARG" ]]; then
  have_jq || { echo "session-usage.sh --transcripts needs jq." >&2; exit 1; }
  transcripts_report "$TRANSCRIPTS_ARG"
  exit 0
fi

if [[ -n "$SESSIONS_ARG" ]]; then
  if have_sqlite3 && [[ -f "$OPENCODE_DB_PATH" ]]; then
    sessions_report "$OPENCODE_DB_PATH" "$SESSIONS_ARG"
    exit 0
  fi
  echo "session-usage.sh --sessions needs sqlite3 and the OpenCode database ($OPENCODE_DB_PATH)." >&2
  exit 1
fi

if [[ -n "$SESSION_ARG" ]]; then
  if have_sqlite3 && [[ -f "$OPENCODE_DB_PATH" ]]; then
    opencode_report "$OPENCODE_DB_PATH"
    exit 0
  fi
  echo "session-usage.sh --session needs sqlite3 and the OpenCode database ($OPENCODE_DB_PATH)." >&2
  exit 1
fi

# No explicit selector: resolve the current run implicitly, Claude Code first.
# A resolvable but stale source is refused here, not reported as this run's.
SOURCE=""
TRANSCRIPT=""
RESOLVED=$(resolve_claude)
if [[ "$RESOLVED" == *$'\t'* ]]; then
  TRANSCRIPT="${RESOLVED%%$'\t'*}"; SOURCE="${RESOLVED##*$'\t'}"
fi

if [[ -n "$SOURCE" ]]; then
  have_jq || { echo "session-usage.sh needs jq for the Claude Code transcript path." >&2; exit 1; }
  case "$SOURCE" in
    newest)  echo "Note: transcript auto-resolved to the newest for this project; pass a path explicitly to be sure it is this run." >&2 ;;
    tracked) echo "Note: transcript resolved from a story-tracked path; pass a path explicitly to be sure it is this run." >&2 ;;
  esac
  claude_report "$TRANSCRIPT"
  exit 0
fi

if have_sqlite3 && [[ -f "$OPENCODE_DB_PATH" ]]; then
  opencode_report "$OPENCODE_DB_PATH"
  exit 0
fi

echo "No usage source found: no Claude Code transcript and no OpenCode database ($OPENCODE_DB_PATH)." >&2
exit 0
