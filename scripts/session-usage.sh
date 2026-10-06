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
#     `output_file` named in its tool_result) with the same fields. No cost
#     field, so tokens only.
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
#   OPENCODE_DB env var overrides the OpenCode database path (testing).

set -u

have_jq() { command -v jq >/dev/null 2>&1; }
have_sqlite3() { command -v sqlite3 >/dev/null 2>&1; }
g() { printf '%s' "$1" | jq -r "$2"; }   # get a field from an AGG result
sqlq() { printf '%s' "${1//\'/\'\'}"; }  # quote a value for a SQL literal

TRANSCRIPT_ARG=""
SESSION_ARG=""
SESSIONS_ARG=""
TRANSCRIPTS_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --session) SESSION_ARG="${2:-}"; shift 2 ;;
    --sessions) SESSIONS_ARG="${2:-}"; shift 2 ;;
    --transcripts) TRANSCRIPTS_ARG="${2:-}"; shift 2 ;;
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
    # top-level session is refused, not guessed at.
    sid=$(sqlite3 "$db" "SELECT id FROM session_v2 WHERE parent_id IS NULL AND ($clause) AND id = (WITH RECURSIVE up(id,parent_id) AS (SELECT id,parent_id FROM session_v2 WHERE id='$(sqlq "$OPENCODE_SESSION_ID")' UNION ALL SELECT s.id,s.parent_id FROM session_v2 s JOIN up ON s.id=up.parent_id) SELECT id FROM up WHERE parent_id IS NULL LIMIT 1) LIMIT 1;")
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
