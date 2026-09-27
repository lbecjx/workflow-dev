#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# session-usage.sh — report the token usage and wall-time of a workflow run,
# read from the harness's own session transcript.
#
# Why this exists (WD-0007, AC 8): the workflow's cost is dominated by
# sub-agents, and nothing else exposes what they cost. The session transcript
# carries `message.usage` on the main thread; each async Agent additionally
# writes its own side-chain file — the `output_file` named in its tool_result —
# carrying the same `usage` fields. This script sums the main thread, then
# walks every Agent/Task call to its side-chain file and sums that too, labeled
# by the call's description, so one validation run's cost is visible per
# sub-agent.
#
# IMPORTANT — usage is repeated per content block. The harness writes one
# JSONL record per assistant *content block* (thinking / text / tool_use), and
# every one of those records carries the *same* `message.id` and a byte-
# identical `usage` object (verified: 1096 usage records vs 602 distinct
# `message.id` in a real transcript). Summing the records as-is overcounts a
# single API call 1–3×, non-uniformly. So the aggregation de-duplicates by
# `message.id` first (keeping the last record per id), and only then sums.
# Records with no `message.id` are kept individually (nothing to dedupe on).
#
# Best-effort by design: side-chain files live under the OS temp dir and are
# purged eventually, and the transcript format is the harness's, not ours.
# Anything unreadable is reported as unavailable — never as zero, since a
# printed 0 reads as "this sub-agent was free", which is worse than "unknown".
#
# Known limitation: only the main transcript is scanned for Agent/Task calls,
# so a sub-agent that launches its own sub-agent is one level deep — the nested
# agent's tokens are not attributed (they are absent from the totals, not
# mis-attributed). Walking side-chains recursively is deliberately out of
# scope until the format proves stable enough to justify it.
#
# Requires `jq`. The usage counts are nested JSON (`iterations[]` repeats the
# same counts), so a grep/sed fallback would silently mis-sum them; a clearly
# missing dependency is preferable to a plausible wrong number (see
# REPO.md's "fail toward doing nothing rather than a false positive").
#
# Usage: session-usage.sh [transcript.jsonl]
#   No argument → resolve the transcript: the current story's tracked
#   transcript (`.workflow-dev/context/.compaction-state/*.json`, newest) if
#   present, else the newest transcript for this project under
#   `~/.claude/projects/<physical-cwd-with-slashes-as-dashes>/`.

set -u

if ! command -v jq >/dev/null 2>&1; then
  echo "session-usage.sh requires jq (nested JSON usage; no reliable text fallback)." >&2
  exit 1
fi

resolve_transcript() {
  local state_dir=".workflow-dev/context/.compaction-state" f p slug
  if [[ -d "$state_dir" ]]; then
    f=$(ls -1t "$state_dir"/*.json 2>/dev/null | head -1)
    if [[ -n "$f" ]]; then
      p=$(jq -r '.transcriptPath // empty' "$f" 2>/dev/null)
      if [[ -n "$p" && -f "$p" ]]; then printf '%s' "$p"; return; fi
    fi
  fi
  # Physical path: the harness names project dirs from the resolved cwd, so a
  # symlinked component (/tmp -> /private/tmp) makes the logical `pwd` miss.
  slug=$(pwd -P | sed 's#/#-#g')
  ls -1t "$HOME/.claude/projects/$slug"/*.jsonl 2>/dev/null | head -1
}

# Aggregate usage of one transcript/side-chain. De-dupes by message.id (see
# the header): `reduce` builds an id→record map (last wins), no-id records are
# kept as-is, and the two sets are summed.
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

norm() { printf '%s' "$1" | cut -c1-19; }   # seconds precision, drops trailing Z or .fffZ

elapsed() {
  [[ -n "$1" && -n "$2" ]] || { printf '?'; return; }
  jq -n --arg a "$(norm "$1")" --arg b "$(norm "$2")" \
    '($a+"Z"|fromdateiso8601) as $x | ($b+"Z"|fromdateiso8601) as $y | ($y-$x)' 2>/dev/null || printf '?'
}

g() { printf '%s' "$1" | jq -r "$2"; }       # get a field from an AGG result

# An explicit path that isn't a file is a caller mistake, not a reason to
# report some other session's numbers — say so and stop (see header).
if [[ $# -ge 1 && -n "$1" ]]; then
  if [[ ! -f "$1" ]]; then
    echo "Not a file: $1" >&2
    exit 1
  fi
  TRANSCRIPT="$1"
else
  TRANSCRIPT=$(resolve_transcript)
fi

if [[ -z "$TRANSCRIPT" || ! -f "$TRANSCRIPT" ]]; then
  echo "No transcript found. Pass one explicitly: session-usage.sh <transcript.jsonl>" >&2
  exit 0
fi

echo "Workflow usage"
echo "Transcript: $TRANSCRIPT"
echo

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

# One row per Agent/Task call: label<TAB>output_file. Joined from the main
# transcript: tool_use blocks give the label; the matching tool_result names
# the side-chain file. `capture` yields empty on no match (a synchronous call
# with no output_file), which `// ""` turns into an empty path → that row is
# reported unavailable, not as zero.
ROWS=$(jq -s -r '
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
  | @tsv' "$TRANSCRIPT")

echo "Sub-agents (Agent/Task)"
printf '  %-3s %-46s %6s %9s %9s %11s %13s %8s\n' "#" label turns input output cache_read cache_create 'wall(s)'
n=0; with=0; lost=0
GT=0; GI=0; GO=0; GCR=0; GCC=0
while IFS=$'\t' read -r label of; do
  [[ -z "$label$of" ]] && continue
  n=$((n+1))
  label=${label:0:46}
  A=""
  if [[ -n "$of" && -f "$of" ]]; then
    A=$(jq -s "$AGG" "$of" 2>/dev/null) || A=""
  fi
  if [[ -n "$A" ]]; then
    t=$(g "$A" .turns); i=$(g "$A" .input); o=$(g "$A" .output); cr=$(g "$A" .cr); cc=$(g "$A" .cc)
    w=$(elapsed "$(g "$A" .first)" "$(g "$A" .last)")
    with=$((with+1)); GT=$((GT+t)); GI=$((GI+i)); GO=$((GO+o)); GCR=$((GCR+cr)); GCC=$((GCC+cc))
    printf '  %-3s %-46s %6s %9s %9s %11s %13s %8s\n' "$n" "$label" "$t" "$i" "$o" "$cr" "$cc" "$w"
  else
    lost=$((lost+1))
    if [[ -n "$of" && -f "$of" ]]; then
      printf '  %-3s %-46s %s\n' "$n" "$label" "- (side-chain unreadable)"
    else
      printf '  %-3s %-46s %s\n' "$n" "$label" "- (side-chain file unavailable)"
    fi
  fi
done <<< "$ROWS"
echo "  $n sub-agent(s): $with with usage, $lost unavailable"
echo

printf 'Grand total (main + sub-agents)\n'
printf '  input: %s  output: %s  cache_read: %s  cache_create: %s\n' \
  "$(( $(g "$MAIN" .input) + GI ))" "$(( $(g "$MAIN" .output) + GO ))" \
  "$(( $(g "$MAIN" .cr) + GCR ))" "$(( $(g "$MAIN" .cc) + GCC ))"
if [[ "$lost" -gt 0 ]]; then
  printf '  (lower bound — excludes %s sub-agent(s) whose usage is unavailable)\n' "$lost"
fi
