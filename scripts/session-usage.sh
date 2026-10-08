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
# run, read from the Claude Code session transcript.
#
# Why this exists (WD-0007, AC 8): the workflow's cost is dominated by
# sub-agents, and nothing else exposes what they cost. The source is read here,
# never guessed at: the session transcript (.jsonl). `message.usage` on the
# main thread; each async Agent writes its own side-chain file (the
# `output_file` named in its tool_result) with the same fields. Cost comes from
# the transcript's last `cost-state` record (`totalCostUSD`), which already
# includes the sub-agents; `modelUsage` splits it per model. An older note here
# said "no cost field, so tokens only" — that was wrong.
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
# Usage: session-usage.sh [--transcript <path> | transcript.jsonl]
#   --transcript <path> / transcript.jsonl — the same explicit
#     path, named or positional; a --transcript with no value exits 2. Without
#     it the Claude source is resolved, in order: this session's own transcript
#     (CLAUDE_CODE_SESSION_ID, under this project's slug, then any project's);
#     else the newest transcript for this project, else a story-tracked one —
#     those two only if written in the last 15 minutes, since an older one is
#     another run, refused rather than reported as this one. The project is
#     the git toplevel (the cwd outside git), so a call from a subdirectory
#     resolves and writes the ledger as if made from the root.
#   --transcripts <path,path,…> — sum these transcripts plus each one's
#     side-chain sub-agents, for a story that spanned several sessions (the
#     transcript path is the session's id).
#   --snapshot <STORY-ID> --stage <stage> — normalize the current run and
#     append a checkpoint to the story's durable ledger
#     (.workflow-dev/context/.usage/<STORY-ID>.json). Prints the normalized
#     object; the one-line tramo/acumulado summary goes to stderr.
#   --story <STORY-ID> — total a story from its ledger ONLY (the source is
#     never touched), across sessions, by stage/session/agent. Checkpoints an
#     older version recorded from OpenCode still count, on a line of their own.
#   --reconcile <STORY-ID> — append an exact `reconcile` checkpoint for each of
#     the story's sessions whose last checkpoint was an estimate and whose
#     transcript now holds an exact cost-state (`--snapshot` does this too, for
#     the story's other sessions). Rebuilds `.usage/.index.json`, the
#     machine-readable summary for dashboards (references/usage-api.md).

set -u

# The plugin root, so the role→model reader (`model-tiering-check.sh
# --role-models`) is asked rather than re-derived here. `cd -P` resolves a
# symlinked checkout; a logical `..` would stop at the link's parent.
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null && pwd -P)"
PLUGIN_ROOT="$(cd -P "$SCRIPT_DIR/.." && pwd -P)"

have_jq() { command -v jq >/dev/null 2>&1; }

# The project is the git toplevel, not the cwd. A skill that `cd`s into
# `.workflow-dev/context/` before calling `--snapshot` otherwise looked for its
# transcript under a slug that does not exist, and would have written the
# ledger to a nested `.workflow-dev/context/.workflow-dev/context/.usage/`
# (WD-0049). Outside a git repo the cwd is the project, as before.
PROJECT_BASE="$(git rev-parse --show-toplevel 2>/dev/null)"
if [[ -n "$PROJECT_BASE" ]]; then
  PROJECT_BASE="$(CDPATH= cd -- "$PROJECT_BASE" >/dev/null && pwd -P)"
else
  PROJECT_BASE="$(pwd -P)"
fi
# The cwd's slug goes first: a session launched in a subdirectory keeps its
# transcripts there, and trying the toplevel first could pick another
# session's newer file. From a directory no session started in (a skill that
# `cd`ed into `.workflow-dev/context/`), that slug is simply empty.
PROJECT_SLUGS=()
if [[ "$(pwd -P)" != "$PROJECT_BASE" ]]; then
  PROJECT_SLUGS+=("$(pwd -P | sed 's#/#-#g')")
fi
PROJECT_SLUGS+=("$(printf '%s' "$PROJECT_BASE" | sed 's#/#-#g')")
g() { printf '%s' "$1" | jq -r "$2"; }   # get a field from an AGG result

TRANSCRIPT_ARG=""
TRANSCRIPTS_ARG=""
SNAPSHOT_STORY=""
SNAPSHOT_STAGE=""
STORY_ARG=""
RECONCILE_STORY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --transcripts) TRANSCRIPTS_ARG="${2:-}"; shift 2 ;;
    --transcript)
      # The named form of the positional path. A missing value is an error,
      # never a silent fall-through to auto-resolution — that would record
      # whichever run resolves instead of the one the caller named.
      if [[ $# -lt 2 || -z "$2" ]]; then
        echo "session-usage.sh: --transcript needs a path" >&2
        exit 2
      fi
      TRANSCRIPT_ARG="$2"; shift 2 ;;
    --snapshot) SNAPSHOT_STORY="${2:-}"; shift 2 ;;
    --stage) SNAPSHOT_STAGE="${2:-}"; shift 2 ;;
    --story) STORY_ARG="${2:-}"; shift 2 ;;
    --reconcile)
      if [[ $# -lt 2 || -z "$2" ]]; then
        echo "session-usage.sh: --reconcile needs a story id" >&2
        exit 2
      fi
      RECONCILE_STORY="$2"; shift 2 ;;
    *) TRANSCRIPT_ARG="$1"; shift ;;
  esac
done

# ---------------------------------------------------------------------------
# Claude Code: transcript (+ per-agent side-chain files)
# ---------------------------------------------------------------------------

resolve_claude() {
  local state_dir="$PROJECT_BASE/.workflow-dev/context/.compaction-state" f p slug sid

  # Identity first: Claude Code exports the session id to the shell, and it is
  # the transcript's file name. With it, a second session open on the same repo
  # can no longer pass its spend off as this one's — "newest" below is only a
  # guess, and was wrong whenever two sessions ran in parallel (WD-0049). It is
  # looked up under this project's slug, then under any project, so a session
  # launched from another directory is still found. An id that could form a
  # path is ignored.
  sid="${CLAUDE_CODE_SESSION_ID:-}"
  if [[ -n "$sid" && "$sid" =~ ^[A-Za-z0-9_-]+$ ]]; then
    for slug in "${PROJECT_SLUGS[@]}"; do
      p="$HOME/.claude/projects/$slug/$sid.jsonl"
      if [[ -f "$p" ]]; then printf '%s\tsession' "$p"; return; fi
    done
    p=$(ls -1 "$HOME"/.claude/projects/*/"$sid.jsonl" 2>/dev/null | head -1)
    if [[ -n "$p" && -f "$p" ]]; then printf '%s\tsession' "$p"; return; fi
  fi

  # The run's own transcript is the newest for this project, and only while it
  # is still being written. Prefer it: a tracked `.compaction-state` path can be
  # fresh yet belong to a run that just finished (or to another story's state
  # file), and letting it win would report that run's totals as this one's
  # (WD-0035) — freshness alone is not identity.
  for slug in "${PROJECT_SLUGS[@]}"; do
    p=$(ls -1t "$HOME/.claude/projects/$slug"/*.jsonl 2>/dev/null | head -1)
    if [[ -n "$p" && -f "$p" && -z "$(find "$p" -mmin +15 2>/dev/null)" ]]; then
      printf '%s\tnewest' "$p"
      return
    fi
  done

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

# The price table (WD-0049): what a message costs when no up-to-date
# `cost-state` covers it. Loaded once; a missing or unreadable table leaves
# every estimate null, never a 0.
PRICES_JSON="$(jq -c . "$SCRIPT_DIR/model-prices.json" 2>/dev/null)"
[[ -n "$PRICES_JSON" ]] || PRICES_JSON='{}'

# Per message, from the table: a rate is looked up by the exact model id, then
# without a `-YYYYMMDD` snapshot suffix. Cache writes are split by TTL (Claude
# Code writes 1-hour entries, priced 2x input, not the 1.25x of 5-minute ones);
# a fast-mode message is priced only when the model carries a multiplier. Any
# unknown leaves the cost null. A model with zero tokens (e.g. `<synthetic>`
# error records) costs 0, since nothing was billed.
AGG='
  def rate($m): ($prices.models // {}) as $t | ($t[$m] // $t[($m | sub("-[0-9]{8}$"; ""))]);
  def ntok: (.message.usage) as $u
    | (($u.input_tokens // 0) + ($u.output_tokens // 0) + ($u.cache_read_input_tokens // 0) + ($u.cache_creation_input_tokens // 0));
  def msgcost: (.message.usage) as $u | rate(.message.model // "") as $r
    | if $r == null then null else
        ( if ($u.speed // "standard") == "fast" then ($r.fast_multiplier // null) else 1 end ) as $k
        | if $k == null then null else
            ($u.cache_creation.ephemeral_1h_input_tokens // 0) as $h
            | ( (($u.cache_creation_input_tokens // 0) - $h) | if . < 0 then 0 else . end ) as $f
            | $k * ( ($u.input_tokens // 0) * $r.input + ($u.output_tokens // 0) * $r.output
                   + ($u.cache_read_input_tokens // 0) * $r.cache_read
                   + $f * $r.cache_write_5m + $h * $r.cache_write_1h ) / 1000000 end end;
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
          cc:     ([ .[].message.usage.cache_creation_input_tokens // 0 ] | add // 0),
          cost:   ( [ .[] | select(ntok > 0) | msgcost ] as $cs
                    | if any($cs[]; . == null) then null else ($cs | add // 0) end )
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

# Like SIDECHAINS_JQ, but keyed by the `subagent_type` — the per-cub key the
# snapshot groups by (AC 13), where the human report only needed a label — and
# carrying the tool_use id, which finds the durable side-chain copy when the
# output_file is gone (`sidechain_file`). Columns: subagent_type, id, path. A call that named no subagent_type ran under the harness's default
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
  # The id sits before the path: an empty last field is safe for `read`, but
  # an empty middle one would collapse (tab is whitespace to IFS).
  | [ $u.stype, $u.id, ( ( $t | capture("output_file: (?<p>[^\\s]+)") | .p ) // "" ) ]
  | @tsv'

claude_report() {
  local TRANSCRIPT="$1"
  echo "Workflow usage (Claude Code)"
  echo "Transcript: $TRANSCRIPT"
  echo
  local MAIN
  MAIN=$(jq -s --argjson prices "$PRICES_JSON" "$AGG" "$TRANSCRIPT")
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
    if [[ -n "$of" && -f "$of" ]]; then A=$(jq -s --argjson prices "$PRICES_JSON" "$AGG" "$of" 2>/dev/null) || A=""; fi
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
  MAIN=$(jq -s --argjson prices "$PRICES_JSON" "$AGG" "$path")
  ROWS=$(jq -s -r "$SIDECHAINS_JQ" "$path")
  local GI=0 GO=0 GCR=0 GCC=0 n=0 A
  while IFS=$'\t' read -r label of; do
    [[ -z "$label$of" ]] && continue
    n=$((n + 1))
    A=""
    if [[ -n "$of" && -f "$of" ]]; then A=$(jq -s --argjson prices "$PRICES_JSON" "$AGG" "$of" 2>/dev/null) || A=""; fi
    if [[ -n "$A" ]]; then
      GI=$((GI + $(g "$A" .input))); GO=$((GO + $(g "$A" .output)))
      GCR=$((GCR + $(g "$A" .cr)));  GCC=$((GCC + $(g "$A" .cc)))
    fi
  done <<< "$ROWS"
  printf '%s %s %s %s %s\n' \
    "$(( $(g "$MAIN" .input) + GI ))" "$(( $(g "$MAIN" .output) + GO ))" \
    "$(( $(g "$MAIN" .cr) + GCR ))" "$(( $(g "$MAIN" .cc) + GCC ))" "$n"
}

# Sum an explicit set of transcripts plus each one's side-chain sub-agents, for
# attributing cost to a story that spanned several sessions. (There is no
# per-session row to point at, so the transcript path is the identifier.)
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
# Snapshot: one normalized checkpoint of the current run
# ---------------------------------------------------------------------------

# The normalized object. `cost_usd` is a number, or null when the source
# carries no price — never an invented 0. The extra `agents` map (per
# agent/role: cost, tokens, models) is what lets `--story` keep rendering the
# breakdown after the source itself is gone; it is stored, not recomputed.
#
# `source` is the transcript path, which pairs a checkpoint with the previous
# one for the same run. A ledger written by an older version can also hold
# checkpoints whose `source` is an OpenCode `ses_…` id (`harness: "opencode"`);
# they never collide with a path, so they still sum with no special case.

# A sub-agent's side-chain file. The tool_result's `output_file` is a /tmp
# symlink that does not outlive a reboot; Claude Code also keeps the file
# durably next to the transcript, as `<session>/subagents/agent-<id>.jsonl`
# with a `.meta.json` naming the Agent call's `toolUseId`. That copy is the
# fallback, and the only source for a foreground call, which names no
# output_file at all (WD-0049). Prints nothing when neither is readable.
# The main transcript's task notifications, one TSV row each: agent id,
# tool_use id, time, <subagent_tokens>. Read only from the harness's own
# `queue-operation` enqueue records — a notification quoted in a tool_result
# or a prompt (a grep of a transcript, a brief) is text, not an event, and
# matching it once took another agent's figure (WD-0049).
NOTES_JQ='
  select(.type == "queue-operation" and .operation == "enqueue" and ((.content // null) | type) == "string")
  | (.timestamp // "") as $t
  | .content | split("<task-notification>")[1:][]
  | [ ((capture("<task-id>(?<a>[A-Za-z0-9]+)</task-id>")? // {}).a // ""),
      ((capture("<tool-use-id>(?<u>[A-Za-z0-9_-]+)</tool-use-id>")? // {}).u // ""),
      $t,
      ((capture("<subagent_tokens>(?<n>[0-9]+)</subagent_tokens>")? // {}).n // "") ]
  | select(.[0] != "") | @tsv'

# tool_use id → agent id, from each call's own tool_result (`agentId: <id>`),
# then from its notification. Never from any line that merely mentions the id:
# the call's own prompt can quote another agent's id (WD-0049).
AIDMAP_JQ='
  select(.type == "user") | .message.content? // empty | .[]?
  | select(.type? == "tool_result")
  | .tool_use_id as $u
  | (if (.content | type) == "string" then .content else ([ .content[]? | (.text? // "") ] | join("\n")) end)
  | ((capture("agentId: (?<a>[A-Za-z0-9]+)")? // {}).a // "") as $a
  | select($a != "") | [ $u, $a ] | @tsv'

# A side-chain's records, with its messages' output repaired. Claude Code logs
# a sub-agent message's `usage` when the response starts, so `output_tokens` is
# a placeholder (~8) never updated — 60 of 75 side-chain messages in one real
# session; the main transcript does not have this. The one real figure left is
# each task notification's `<subagent_tokens>`: the context of the call that
# ended that run plus its output. Each notification repairs the last message
# written before it (a resumed agent notifies again, for a later message), as
# a later copy of the record (AGG keeps the last copy per message id). Only an
# increase below the 128K output ceiling is taken. Fails when the file does
# not parse. Uses NOTES (from NOTES_JQ) of the transcript being snapshotted.
sidechain_stream() { # $1 side-chain file
  local lines aid notes
  lines=$(jq -c . "$1" 2>/dev/null) || return 1
  printf '%s\n' "$lines"
  aid=$(basename -- "$1"); aid=${aid#agent-}; aid=${aid%.jsonl}; aid=${aid%.output}
  [[ "$aid" =~ ^[A-Za-z0-9]+$ ]] || return 0
  notes=$(printf '%s\n' "$NOTES" | awk -F'\t' -v a="$aid" '$1 == a && $4 != "" { printf "%s{\"t\":\"%s\",\"n\":%s}", (n++ ? "," : "["), $3, $4 } END { if (n) print "]" }')
  [[ -n "$notes" ]] || return 0
  printf '%s\n' "$lines" | jq -s -c --argjson notes "$notes" '
    [ .[] | select(.message.usage and (.message.id // "") != "") ] as $m
    | [ $notes[] as $x
        | ( [ $m[] | select($x.t == "" or ((.timestamp // "") <= $x.t)) ] | last ) as $r
        | select($r != null)
        | ($r.message.usage) as $u
        | ( $x.n - (($u.input_tokens // 0) + ($u.cache_creation_input_tokens // 0) + ($u.cache_read_input_tokens // 0)) ) as $o
        | select($o > ($u.output_tokens // 0) and $o < 128000)
        | ($r | .message.usage.output_tokens = $o) ]
    | group_by(.message.id) | map(max_by(.message.usage.output_tokens))[]' 2>/dev/null
  return 0
}

sidechain_file() { # $1 transcript, $2 tool_use id, $3 output_file (may be empty)
  local dir m
  if [[ -n "$3" && -f "$3" ]]; then printf '%s' "$3"; return; fi
  [[ "$2" =~ ^[A-Za-z0-9_-]+$ ]] || return 0
  dir="${1%.jsonl}/subagents"
  m=$(grep -lF "\"toolUseId\":\"$2\"" "$dir"/*.meta.json 2>/dev/null | head -1)
  if [[ -n "$m" && -f "${m%.meta.json}.jsonl" ]]; then printf '%s' "${m%.meta.json}.jsonl"; return 0; fi
  # Older Claude Code wrote no `toolUseId` in the meta; the transcript still
  # names the agent: `agentId: <id>` in this call's tool_result, or `<task-id>`
  # in the notification that carries this call's `<tool-use-id>` (AIDMAP and
  # NOTES, read from those records only).
  # The output_file's own name is the agent id too, even once it is gone.
  m=""
  [[ -z "$3" ]] || { m=$(basename -- "$3"); m=${m%.output}; }
  [[ "$m" =~ ^[A-Za-z0-9]+$ ]] || m=$(printf '%s\n' "$AIDMAP" | awk -F'\t' -v u="$2" '$1 == u { print $2; exit }')
  [[ "$m" =~ ^[A-Za-z0-9]+$ ]] || m=$(printf '%s\n' "$NOTES" | awk -F'\t' -v u="$2" '$2 == u { print $1; exit }')
  [[ "$m" =~ ^[A-Za-z0-9]+$ ]] || return 0
  if [[ -f "$dir/agent-$m.jsonl" ]]; then printf '%s' "$dir/agent-$m.jsonl"; return 0; fi
  # A resumed session keeps writing the transcript it continued, but its
  # agents land under the new session's own directory, a sibling in the same
  # project — so look there too, by the (unique) agent id.
  m=$(ls -1 "$(dirname -- "$1")"/*/subagents/"agent-$m.jsonl" 2>/dev/null | head -1)
  if [[ -n "$m" && -f "$m" ]]; then printf '%s' "$m"; fi
}

# Claude Code: the cost is the last `cost-state` record (`totalCostUSD`,
# `modelUsage`, sub-agents included) as-is ONLY while it is up to date — no
# assistant message with usage after it in the transcript
# (`cost_basis: "cost-state"`). Claude Code writes that record on session
# lifecycle events (idle, /clear, exit, reload), not per turn, so a live
# session's is usually stale or absent; taking it anyway froze the checkpoint
# at an old total (WD-0049). Otherwise (`cost_basis: "estimated"`, plus
# `stale: true` when a cost-state existed) the cost is that stale total (0
# without one) plus the tail written after it, priced per message with
# scripts/model-prices.json. The estimate is null — never a guess — when a
# model has no price or a side-chain is unreadable, and the reason goes to
# stderr. Tokens (main transcript plus every readable side-chain) come from
# `message.usage`, deduped by `message.id` like `claude_totals`.
snapshot_claude() {
  local path="$1" cost mu tsv rows bymodel models mainjson agents as_of
  local basis stale order cs_line msg_line missing="" absent="" read_ids="" absent_ids="" missing_main="" stream ph id f stype all part

  # Which cost-state is the reading: the HIGHEST, not the last. A run's cost
  # never falls within its transcript — a resumed session restores the total
  # — yet two kinds of record do fall: one of exactly 0, seen written by a
  # process 25 s old after $5 of spend, and an older figure (211 after 342)
  # written by a second process on the same session (remote control). Either,
  # taken as the reading, would fake a reset or drop real spend (WD-0049).
  # One record per line, so the line order is the write order; `cost-state`
  # carries no timestamp, so its position is the only clock it has.
  order=$(jq -r 'if .type == "cost-state" and (.totalCostUSD // 0) > 0 then "c\t\(.totalCostUSD)"
                 elif .type == "assistant" and (.message.usage != null) then "a"
                 else "-" end' "$path" 2>/dev/null)
  # And its FIRST occurrence: Claude Code rewrites the same total after newer
  # messages it does not include yet (seen: 70.07 written again after a $3.06
  # turn, the next record 73.13). Taking the later copy as the position called
  # the run up to date and dropped that turn (WD-0049).
  read -r cs_line cost <<< "$(printf '%s\n' "$order" | awk -F'\t' '$1 == "c" && ($2 + 0) > max { max = $2 + 0; ln = NR; v = $2 } END { if (ln) print ln, v }')"
  [[ -n "$cost" ]] || cost=null
  mu='{}'
  [[ -z "$cs_line" ]] || mu=$(sed -n "${cs_line}p" "$path" | jq -c '.modelUsage // {}' 2>/dev/null)
  [[ -n "$mu" ]] || mu='{}'
  msg_line=$(printf '%s\n' "$order" | grep -n '^a$' | tail -1 | cut -d: -f1)
  stale=false
  if [[ -n "$cs_line" && "$cost" != "null" && ( -z "$msg_line" || "$cs_line" -gt "$msg_line" ) ]]; then
    basis="cost-state"
  else
    basis="estimated"
    [[ -n "$cs_line" ]] && stale=true
  fi

  # An unreadable or unparsable transcript yields no snapshot (`unavailable`),
  # never zeros — jq still prints the AGG of nothing when it cannot open a file.
  mainjson=$(jq -s --argjson prices "$PRICES_JSON" "$AGG" "$path" 2>/dev/null) || return 1
  [[ -n "$mainjson" ]] || return 1

  # The tail: what ran after the last cost-state, the only part an estimate has
  # to price. Everything before it is already in `totalCostUSD` — including
  # the calls Claude Code makes outside the transcript (compaction, titles),
  # which an estimate from tokens cannot see (in a real session they were ~15%
  # of the spend). The main transcript's tail is cut by position; a side-chain
  # lives in its own file, so its tail is cut by time — after the newest
  # timestamp written before the cost-state. With no cost-state, everything is
  # tail. Known limit: a background agent still writing between that timestamp
  # and the cost-state is priced again in the tail (a small overshoot), and
  # one still running after an up-to-date cost-state lands in the next
  # checkpoint instead of this one — the story total is unaffected.
  local cs_time="" maintail
  if [[ -n "$cs_line" ]]; then
    cs_time=$(head -n $((cs_line - 1)) "$path" | jq -r '.timestamp // empty' 2>/dev/null | tail -1)
    maintail=$(tail -n +$((cs_line + 1)) "$path" | jq -s --argjson prices "$PRICES_JSON" "$AGG" 2>/dev/null | jq -c '.byModel' 2>/dev/null)
  else
    maintail=$(printf '%s' "$mainjson" | jq -c '.byModel')
  fi
  # A tail that could not be read is unknown, not empty: it nulls the estimate.
  [[ -n "$maintail" ]] || { maintail='[]'; missing_main=1; }

  # One row per Agent call: subagent_type, the AGG byModel of its whole
  # side-chain, and of its tail — both null when it cannot be read.
  tsv=$(jq -s -r "$SIDECHAINS3_JQ" "$path")
  NOTES=$(jq -r "$NOTES_JQ" "$path" 2>/dev/null)
  AIDMAP=$(jq -r "$AIDMAP_JQ" "$path" 2>/dev/null)
  rows=$(
    while IFS=$'\t' read -r stype id f; do
      [[ -z "$stype" ]] && continue
      f=$(sidechain_file "$path" "$id" "$f")
      if [[ -n "$f" ]]; then
        # Each stage is checked by its output, not a pipeline's exit code: the
        # last jq of a pipeline exits 0 on empty input, so a side-chain with a
        # truncated line (an agent caught mid-write) used to yield an empty
        # field — invalid JSON downstream, and a fabricated $0 (WD-0049).
        all=""; part=""; ph=0
        if stream=$(sidechain_stream "$f"); then
          all=$(printf '%s\n' "$stream" | jq -s --argjson prices "$PRICES_JSON" "$AGG" 2>/dev/null | jq -c '.byModel' 2>/dev/null)
          part=$(printf '%s\n' "$stream" | jq -c --arg t "$cs_time" 'select($t == "" or ((.timestamp // "") > $t))' 2>/dev/null \
                | jq -s --argjson prices "$PRICES_JSON" "$AGG" 2>/dev/null | jq -c '.byModel' 2>/dev/null)
          # Messages still carrying the placeholder output after the repair:
          # this cub's output — and so its cost — is a lower bound.
          ph=$(printf '%s\n' "$stream" | jq -s '[ .[] | select(.message.usage and (.message.id // "") != "") ]
                | group_by(.message.id) | map(.[-1].message.usage.output_tokens // 0) | map(select(. <= 10)) | length' 2>/dev/null)
          [[ "$ph" =~ ^[0-9]+$ ]] || ph=0
        fi
        if [[ -z "$all" ]]; then part=""; fi
        printf '%s\t%s\t%s\t%s\t%s\n' "$stype" "${all:-null}" "${part:-null}" "$id" "$([[ "$ph" -gt 0 ]] && echo 1 || echo 0)"
      else
        # No side-chain to read at all (none named, none kept): its spend is
        # unknown — `none`, which nulls the estimate but still records.
        printf '%s\t%s\t%s\t%s\t%s\n' "$stype" "none" "none" "$id" 0
      fi
    done <<< "$tsv"
  )
  # `missing`: a side-chain that exists but cannot be parsed (an agent caught
  # mid-write). `absent`: one there is nothing to read for.
  missing=$(printf '%s\n' "$rows" | awk -F'\t' '$1 != "" && ($2 == "null" || $3 == "null") { print $1 }' | sort -u | paste -sd, -)
  absent=$(printf '%s\n' "$rows" | awk -F'\t' '$1 != "" && $2 == "none" { print $1 }' | sort -u | paste -sd, -)
  # The Agent calls (tool_use ids) whose side-chain was read, and those with
  # nothing to read — so the ledger can tell a call it saw before going dark
  # from one it never could see.
  read_ids=$(printf '%s\n' "$rows" | awk -F'\t' '$1 != "" && $2 != "none" && $2 != "null" { print $4 }' | paste -sd, -)
  absent_ids=$(printf '%s\n' "$rows" | awk -F'\t' '$1 != "" && $2 == "none" { print $4 }' | paste -sd, -)

  # Per model: the tokens of the whole run, and the estimated cost of the tail.
  bymodel=$(
    {
      printf '{"part":"all","bm":%s}\n' "$(printf '%s' "$mainjson" | jq -c '.byModel')"
      printf '{"part":"tail","bm":%s}\n' "$maintail"
      printf '%s\n' "$rows" | awk -F'\t' '$1 != "" && $2 != "null" && $2 != "none" { print "{\"part\":\"all\",\"bm\":" $2 "}" }'
      printf '%s\n' "$rows" | awk -F'\t' '$1 != "" && $3 != "null" && $3 != "none" { print "{\"part\":\"tail\",\"bm\":" $3 "}" }'
    } | jq -s '
        def sumnull: if any(.[]; . == null) then null else (add // 0) end;
        [ .[] | select(.part == "all")  | .bm[] ] as $all
        | [ .[] | select(.part == "tail") | .bm[] | select((.input + .output + .cr + .cc) > 0) ] as $tail
        | ( $all | group_by(.model) | map({ key: .[0].model,
              value: { tokens: { input: (map(.input)|add // 0), output: (map(.output)|add // 0),
                reasoning: 0, cache_read: (map(.cr)|add // 0), cache_write: (map(.cc)|add // 0) } } })
          | from_entries ) as $tok
        | ( $tail | group_by(.model) | map({ key: .[0].model, value: (map(.cost) | sumnull) }) | from_entries ) as $tc
        | reduce (($tok + $tc) | keys[]) as $k ({};
            .[$k] = { tokens: ($tok[$k].tokens // {input:0,output:0,reasoning:0,cache_read:0,cache_write:0}),
                      tail: (if $tc | has($k) then $tc[$k] else 0 end) } )'
  )
  [[ -n "$bymodel" ]] || bymodel='{}'

  # A model's cost: exact from an up-to-date cost-state; otherwise the stale
  # cost-state's figure (0 without one) plus the tail's estimate. A model seen
  # only in cost-state (a call outside the transcript) keeps that figure.
  models=$(jq -n --argjson mu "$mu" --argjson bm "$bymodel" --arg basis "$basis" '
    ( $bm | with_entries(.key as $k | .value = { tokens: .value.tokens,
          cost_usd: (if $basis == "cost-state" then ($mu[$k].costUSD // null)
                     elif .value.tail == null then null
                     else (($mu[$k].costUSD // 0) + .value.tail) end) }) )
    | reduce (($mu // {}) | keys[]) as $k (.;
        if has($k) then . else .[$k] = { cost_usd: ($mu[$k].costUSD // null),
          tokens: {input:0,output:0,reasoning:0,cache_read:0,cache_write:0} } end)')

  # A side-chain (or the tail) that cannot be read makes the snapshot
  # incomplete: its tokens would be missing, the ledger would read the drop as
  # a reset and count the whole run again. So no snapshot at all — the
  # checkpoint is not recorded, loudly. It is transient for an agent caught
  # mid-write; the durable `subagents/` copy keeps it rare otherwise (WD-0049).
  if [[ -n "$missing" || -n "$missing_main" ]]; then
    [[ -z "$missing" ]] || printf 'usage: side-chain of %s unreadable — checkpoint NOT recorded\n' "$missing" >&2
    [[ -z "$missing_main" ]] || printf 'usage: transcript tail unreadable — checkpoint NOT recorded\n' >&2
    return 2
  fi

  [[ -z "$absent" ]] || printf 'usage: no side-chain found for %s — its spend is unknown\n' "$absent" >&2
  # An up-to-date cost-state is checked against the main thread only; a
  # background sub-agent still writing after it is spend the figure lacks.
  # The cost stays exact for what it covers, but the checkpoint is marked
  # `pending_sidechain` — never verified, and reconciled later (WD-0049).
  local pending=false
  if [[ "$basis" == "cost-state" ]] && printf '%s\n' "$rows" | awk -F'\t' '$1 != "" && $3 != "null" && $3 != "none" { print $3 }' \
       | jq -s -e '[ .[][] | (.input + .output + .cr + .cc) ] | add // 0 | . > 0' >/dev/null 2>&1; then
    pending=true
  fi
  local cs_base="$cost"
  if [[ "$basis" == "estimated" ]]; then
    cost=$(jq -n --argjson bm "$bymodel" --argjson base "$cost" \
      '[ $bm[] | .tail ] | if any(.[]; . == null) then null else (($base // 0) + (add // 0)) end')
    [[ -z "$absent" ]] || cost=null
    local unpriced
    unpriced=$(jq -rn --argjson bm "$bymodel" '[ $bm | to_entries[] | select(.value.tail == null) | .key ] | join(", ")')
    [[ -z "$unpriced" ]] || printf 'usage: no price for %s in model-prices.json — cost left unknown\n' "$unpriced" >&2
  fi

  # One cub per subagent_type (a repeated type accumulates), plus the
  # orchestrator. Each cub is priced from its own tokens with the table — there
  # is no per-agent figure in cost-state — and an unreadable side-chain leaves
  # its cub's cost and tokens unknown rather than zero.
  agents=$(
    {
      printf '%s\t%s\n' "orchestrator" "$(printf '%s' "$mainjson" | jq -c '.byModel')"
      printf '%s\n' "$rows"
    } | jq -R -s '
        [ split("\n")[] | select(length>0) | split("\t") ]
        | reduce .[] as $r ({};
            ($r[1] | if . == "none" then null else fromjson end) as $raw
            | ($raw // []) as $bm
            | ($bm | { input: (map(.input)|add // 0), output: (map(.output)|add // 0),
                  cache_read: (map(.cr)|add // 0), cache_write: (map(.cc)|add // 0) }) as $tk
            | ( if $raw == null then null
                else ($bm | map(.cost) | if any(.[]; . == null) then null else (add // 0) end) end ) as $bc
            # A repeated type keeps the accumulator as it is (`.`) and adds to
            # its own entry below. Returning `.[$r[0]]` here replaced the whole
            # map with that one entry — `orchestrator` vanished and the
            # checkpoint then failed in ledger_record (WD-0049).
            | (if has($r[0]) then . else
                 .[$r[0]] = { cost_usd: 0, tokens: {input:0,output:0,reasoning:0,cache_read:0,cache_write:0}, models: [], output_partial: false } end)
            | .[$r[0]].output_partial = (.[$r[0]].output_partial or (($r[4] // "0") == "1"))
            | .[$r[0]].cost_usd = ( if .[$r[0]].cost_usd == null or $bc == null then null else .[$r[0]].cost_usd + $bc end )
            | .[$r[0]].tokens.input += $tk.input
            | .[$r[0]].tokens.output += $tk.output
            | .[$r[0]].tokens.cache_read += $tk.cache_read
            | .[$r[0]].tokens.cache_write += $tk.cache_write
            | .[$r[0]].models = ((.[$r[0]].models + ($bm | map(.model))) | unique) )'
  )
  [[ -n "$agents" ]] || agents='{}'

  as_of=$(printf '%s' "$mainjson" | jq -r '.last // ""')
  [[ "$as_of" != "null" ]] || as_of=""

  # The tokens are the main transcript plus every readable side-chain — the
  # same set the estimate prices.
  jq -n --arg src "$path" --argjson cost "$cost" --argjson models "$models" \
    --argjson agents "$agents" --arg asof "$as_of" --arg basis "$basis" --argjson stale "$stale" \
    --argjson csbase "$cs_base" --arg readids "$read_ids" --arg absentids "$absent_ids" --argjson pending "$pending" '
    { source: $src, harness: "claude", cost_usd: $cost, cost_basis: $basis }
    + (if $pending then { pending_sidechain: true } else {} end)
    # The Agent calls whose side-chain was read / had nothing to read: a call
    # read before and absent now means missing tokens, which ledger_record
    # must not take for a reset.
    # An estimated total that includes a sub-agent with placeholder output is a
    # lower bound; an exact cost-state total is not affected.
    + (if $basis == "estimated" and any($agents[]; .output_partial == true) then { output_partial: true } else {} end)
    + (if $readids == "" then {} else { sidechains_read: ($readids | split(",")) } end)
    + (if $absentids == "" then {} else { sidechains_absent: ($absentids | split(",")) } end)
    # The stale cost-state the estimate was built on: an exact reading the
    # ledger compares to detect a reset (a fallen counter) under an estimate.
    + (if $stale then { stale: true, cost_state_usd: $csbase } else {} end)
    + { tokens: ( [ $models[].tokens ] | { input: (map(.input)|add // 0), output: (map(.output)|add // 0),
                    reasoning: 0, cache_read: (map(.cache_read)|add // 0), cache_write: (map(.cache_write)|add // 0) } ),
        models: $models, agents: $agents, as_of: $asof }'
}

# ---------------------------------------------------------------------------
# Ledger: a durable per-story store of checkpoints (survives the source)
# ---------------------------------------------------------------------------

# `.workflow-dev/context/.usage/<STORY>.json`, one doc per story. A checkpoint
# is a photo of the accumulated total at an instant: it stores the absolute
# (`abs`) and the `delta` against the previous checkpoint of the SAME `source`
# (the same transcript). The story total is the sum
# of the deltas — computed from the ledger, never from a source that may be
# gone. The previous checkpoint IS the "before", so nothing has to be
# remembered between reads, and pairing is by `source`, not by run.
USAGE_DIR="$PROJECT_BASE/.workflow-dev/context/.usage"

# A story id names a file under `.usage/`, so it must not carry a path
# separator or be `.`/`..` — otherwise `--snapshot`/`--story` could read or write
# outside the store. The workflow only ever passes `WD-NNNN`, but the script is
# a CLI and must not trust its argument.
valid_story_id() {
  # A leading dot is refused too: `.index.json` (the dashboard API, below)
  # shares the directory and must never be read or written as a story.
  case "$1" in
    ""|.*|*/*) return 1 ;;
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

  # A sub-agent whose side-chain was read at an earlier checkpoint of this
  # source and has nothing to read now (its /tmp output_file gone, no durable
  # copy) would make the tokens fall — read as a reset, counting the whole run
  # again. Refuse that checkpoint, loudly, instead (WD-0049).
  local lost
  lost=$(jq -rn --argjson doc "$existing" --argjson e "$snap" '
    ( [ ($doc.checkpoints // [])[] | select(.source == $e.source) ] | last ) as $p
    | if $p == null then "" else
        [ ($e.sidechains_absent // [])[] as $id
          | select(($p.sidechains_read // []) | index($id)) | $id ] | join(",") end' 2>/dev/null)
  if [[ -n "$lost" ]]; then
    printf 'usage: side-chain of Agent call %s was read before and is gone now — checkpoint NOT recorded\n' "$lost" >&2
    return 1
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
    # Only an EXACT reading can reveal a falling price: the cost itself, or —
    # for an estimate built on a stale cost-state — that cost-state. A whole-
    # run estimate has none. An estimate in between must neither fake a fall
    # (it can overshoot) nor hide one (WD-0049).
    | def exact: if (.cost_basis // "") == "estimated" then (.cost_state_usd // null) else .cost_usd end;
      ( $same | map(select(exact != null)) | last ) as $lastp
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
        # A price that fell below the last exact reading is a reset too (AC 8)
        # — compared exact to exact (see `exact` above). An estimate that
        # overshoots a later exact figure is a correction, not a new run; a
        # reset there would count the whole run twice (WD-0049).
        | ( ($e | exact) as $x | $x != null and $lastp != null and $x < ($lastp | exact) ) as $costfall
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
                  models: ($cur.models // []) }
              + (if $cur.output_partial == true then { output_partial: true } else {} end) ) ) as $ad
        | ( $e + { segment: $segment, delta: $delta, token_delta: $td, agent_deltas: $ad } ) as $new
        | { action: "appended",
            doc: ($doc + { story: $story, checkpoints: (cps + [$new]) }),
            entry: $new }
      end')
  # A failed computation must be loud: with no check, an error here (a jq
  # failure on an unexpected snapshot shape) wrote nothing, printed a corrupt
  # summary line, and still exited 0 — the checkpoint vanished silently
  # (WD-0049).
  if [[ $? -ne 0 ]] || ! printf '%s' "$result" | jq -e '.action' >/dev/null 2>&1; then
    printf 'usage: could not compute the checkpoint for %s — checkpoint NOT recorded\n' "$story" >&2
    return 1
  fi

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

  local tramo total nst unpriced estimated basis
  tramo=$(printf '%s' "$result" | jq -r '.entry.delta // "?"')
  basis=$(printf '%s' "$result" | jq -r '.entry.cost_basis // ""')
  estimated=$(printf '%s' "$doc" | jq -r '[.checkpoints[] | select(.cost_basis == "estimated")] | length')
  total=$(printf '%s' "$doc" | jq -r '[.checkpoints[].delta | select(type=="number")] | add // 0')
  nst=$(( $(printf '%s' "$doc" | jq -r '.checkpoints | length') ))
  unpriced=$(printf '%s' "$doc" | jq -r '[.checkpoints[] | select(.cost_usd == null)] | length')

  local atom accum
  atom=$([[ "$tramo" == "?" ]] && printf 'unknown' || awk -v t="$tramo" 'BEGIN{printf "$%.4f", t}')
  [[ "$tramo" == "?" || "$basis" != "estimated" ]] || atom="≈$atom (estimated)"
  [[ "$(printf '%s' "$result" | jq -r '.entry.output_partial // false')" != "true" ]] || atom="$atom, a lower bound"
  accum=$(awk -v t="$total" 'BEGIN{printf "$%.4f", t}')
  printf 'usage %s · stage %s · this step %s · story total %s over %s checkpoint(s), %s without price, %s estimated\n' \
    "$story" "$stage" "$atom" "$accum" "$nst" "$unpriced" "$estimated" >&2
}

# Reconcile (WD-0049): a checkpoint taken mid-session is often an estimate,
# and the exact figure only lands later, when Claude Code writes its next
# cost-state (idle, /clear, exit) — after the story's last checkpoint for that
# session, which then never sees it. For each Claude source of the story whose
# latest checkpoint is not exact and whose transcript still exists, take a
# snapshot now; if that one is exact, APPEND it as a `reconcile` checkpoint.
# The ledger stays append-only: the correction is that entry's delta (negative
# when the estimate was high), never an edit. An estimate again is skipped —
# it adds a line, not accuracy. Skips the source just recorded ($2).
#
# Only when the session did NO new work after that checkpoint — same last
# message, same input and cache tokens (output may still rise: a late task
# notification repairs a sub-agent's output). Otherwise the exact figure also
# holds whatever the session did next, perhaps for another story, and moving
# it here would count it twice (WD-0049). Then the estimate simply stays.
reconcile_story() { # $1 story, $2 source to skip (may be empty)
  local file="$USAGE_DIR/$1.json" src last snap err
  valid_story_id "$1" && [[ -f "$file" ]] || return 0
  while IFS= read -r src; do
    [[ -n "$src" && "$src" != "$2" && -f "$src" ]] || continue
    snap=$(snapshot_claude "$src" 2>/dev/null) || continue
    [[ "$(printf '%s' "$snap" | jq -r 'if .pending_sidechain then "" else (.cost_basis // "") end')" == "cost-state" ]] || continue
    last=$(jq -c --arg s "$src" '[ (.checkpoints // [])[] | select(.source == $s) ] | last' "$file" 2>/dev/null)
    # The main thread is what moves on to other work; a sub-agent this story
    # launched may still have been writing, and its spend is this story's.
    jq -en --argjson p "$last" --argjson n "$snap" '
      ($p.agents.orchestrator.tokens // $p.tokens) as $a | ($n.agents.orchestrator.tokens // $n.tokens) as $b
      | $p.as_of == $n.as_of
        and $a.input == $b.input and $a.cache_read == $b.cache_read and $a.cache_write == $b.cache_write' >/dev/null 2>&1 || continue
    if ! err=$(ledger_record "$1" reconcile "$snap" 2>&1); then
      printf 'usage: %s — reconcile of %s skipped: %s\n' "$1" "$(basename -- "$src")" "${err#usage: }" >&2
    else
      printf '%s\n' "$err" >&2
    fi
  done < <(jq -r '(.checkpoints // []) | group_by(.source) | map(last) | .[]
                  | select(.harness == "claude" and ((.cost_basis // "") != "cost-state" or .pending_sidechain == true)) | .source' "$file" 2>/dev/null)
  return 0
}

# The dashboard API (WD-0049): `.usage/.index.json`, rebuilt from every story
# ledger after each write. One small JSON file a status line can read on every
# refresh — no jq, no script, no plugin path needed. Its shape is a contract,
# documented in references/usage-api.md; change it only with a new `schema`.
write_index() { # $1 = space-separated story ids touched by this run (announced)
  [[ -d "$USAGE_DIR" ]] || return 0
  local touched="${1:-}"
  local f id tmp docs=""
  # Keyed by FILE NAME, the same id `--story` reads; a ledger that does not
  # parse is skipped (ledger_record leaves a corrupt one for the human), so
  # one bad file never freezes every other story's entry.
  for f in "$USAGE_DIR"/*.json; do
    [[ -f "$f" ]] || continue
    id=$(basename -- "$f" .json)
    valid_story_id "$id" || continue
    docs+=$(jq -c --arg id "$id" 'select((.checkpoints | type) == "array") | { id: $id, checkpoints }' "$f" 2>/dev/null)$'\n'
  done
  # No readable previous index (first run after an upgrade, or a damaged one):
  # this write is the baseline, and nothing is announced — otherwise every
  # story that is already exact would be announced at once, mid-way through
  # some other story's work.
  local before=""
  [[ -f "$USAGE_DIR/.index.json" ]] && before=$(jq -c '[ (.stories // {}) | to_entries[] | select(.value.verified == true) | .key ]' "$USAGE_DIR/.index.json" 2>/dev/null)
  tmp=$(mktemp "$USAGE_DIR/.index.XXXXXX") || return 1
  if printf '%s' "$docs" | jq -s --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
      def r4: . * 10000 | round / 10000;
      # One reading the harness itself priced, whole: a Claude Code
      # cost-state with no sub-agent still writing after it; and no model with
      # tokens left without a price. A legacy OpenCode checkpoint (recorded
      # before OpenCode support was removed) was the exact row of its store,
      # so it still counts as exact — a story verified before the upgrade
      # stays verified after it.
      def exactck: .cost_usd != null
        and ((.harness == "claude" and .cost_basis == "cost-state" and (.pending_sidechain // false) == false)
             or .harness == "opencode")
        and ([ (.models // {})[] | select((((.tokens // {}) | [.[]?] | add) // 0) > 0 and .cost_usd == null) ] | length) == 0;
      . as $docs
      # A session recorded under two stories: the split between them is not
      # what the harness measured, so neither story can be verified.
      | ( [ $docs[] | .id as $id | (.checkpoints | map(.source) | unique)[] | { s: ., id: $id } ]
          | group_by(.s) | map(select((map(.id) | unique | length) > 1) | .[0].s) ) as $shared
      | ( $docs | map(
            .checkpoints as $c
            | ( $c | group_by(.source) | map(last) ) as $latest
            # A reconcile is bookkeeping, not work: it never makes a story the
            # "last" one, nor its stage the last stage.
            | ( [ $c[] | select(.stage != "reconcile") ] | last // ($c | last) ) as $w
            | { key: .id, value: {
                total_usd: ([ $c[].delta | select(type == "number") ] | add // 0 | r4),
                estimated: any($latest[]; .cost_basis == "estimated"),
                # verified: the total holds only figures the harness recorded, so
                # its error against what the harness accounts is 0. Every
                # session latest reading exact, and the last priced reading of
                # EVERY segment exact too (an estimate in an earlier segment is
                # still in the sum), and no session shared with another story.
                verified_reason: (
                  ( [ $c | group_by(.source)[] | group_by(.segment // 1)[]
                      | [ .[] | select(.cost_usd != null) ] | last ] ) as $segs
                  | if ($c | length) == 0 then "no-checkpoints"
                    elif any($latest[]; .cost_usd == null) or any($segs[]; . == null) then "unpriced"
                    elif any($latest[]; exactck | not) then "estimated"
                    elif any($segs[]; exactck | not) then "earlier-estimate"
                    elif any($c[]; .source as $s | $shared | index($s)) then "shared-session"
                    else null end ),
                lower_bound: any($latest[]; .cost_basis == "estimated" or .cost_usd == null or .output_partial == true),
                checkpoints_exact: true,
                checkpoints: ($c | length),
                unpriced_checkpoints: ([ $c[] | select(.cost_usd == null) ] | length),
                sessions: ($c | map(.source) | unique | length),
                last_stage: $w.stage,
                last_recorded_at: $w.recorded_at,
                tokens: { input: ([ $c[].token_delta.input // 0 ] | add // 0),
                          output: ([ $c[].token_delta.output // 0 ] | add // 0),
                          reasoning: ([ $c[].token_delta.reasoning // 0 ] | add // 0),
                          cache_read: ([ $c[].token_delta.cache_read // 0 ] | add // 0),
                          cache_write: ([ $c[].token_delta.cache_write // 0 ] | add // 0) },
                by_agent: ( [ $c[].agent_deltas // {} | to_entries[] ] | group_by(.key)
                  | map({ key: .[0].key, value: {
                      cost_usd: ([ .[].value.cost_usd | select(. != null) ] | if length == 0 then null else (add | r4) end),
                      lower_bound: any(.[]; .value.output_partial == true) } })
                  | from_entries ) } } )
          | from_entries
          | with_entries(.value |= (del(.checkpoints_exact) | .verified = (.verified_reason == null)))
          ) as $stories
      | { schema: "workflow-dev.usage/1", updated_at: $at,
          last_story: ( [ $stories | to_entries[] | select(.value.last_recorded_at != null) ]
                        | max_by(.value.last_recorded_at) | .key? // null ),
          stories: $stories }' > "$tmp" 2>/dev/null && mv "$tmp" "$USAGE_DIR/.index.json"; then
    chmod 600 "$USAGE_DIR/.index.json" 2>/dev/null
    # Say it once, when a story THIS RUN touched becomes verified.
    [[ -n "$before" && -n "$touched" ]] || return 0
    jq -r --argjson before "$before" --arg touched " $touched " '
      .stories | to_entries[] | .key as $k
      | select(.value.verified == true and ($before | index($k) | not) and ($touched | contains(" " + $k + " ")))
      | "usage \(.key) · spend verified ✓ $\(.value.total_usd) — every session matches the exact figure the harness recorded"' \
      "$USAGE_DIR/.index.json" >&2 2>/dev/null
    return 0
  fi
  rm -f "$tmp" 2>/dev/null
  printf 'usage: could not rebuild %s/.index.json\n' "$USAGE_DIR" >&2
  return 1
}

# Totalise a story from the ledger ONLY — never touching the source, so a
# deleted transcript changes nothing. Sums every checkpoint (legacy OpenCode
# ones included, and named on their own line), breaks the spend down by stage,
# session and agent/role (the cubs are whatever
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

  # verified needs every ledger (a session shared with another story), so it
  # is read from the index, rebuilt here — one rule, never two that disagree.
  local vinfo
  write_index "" >/dev/null 2>&1
  vinfo=$(jq -c --arg s "$story" '.stories[$s] // {} | { verified: (.verified // false), reason: (.verified_reason // "unknown") }' "$USAGE_DIR/.index.json" 2>/dev/null)
  [[ -n "$vinfo" ]] || vinfo='{"verified":false,"reason":"unknown"}'

  jq -r --argjson v "$vinfo" '
    (.checkpoints // []) as $c
    | ( [ $c[].delta | select(type=="number") ] | add // 0 ) as $total
    | "  total: $\($total * 10000 | round / 10000)   checkpoints: \($c | length)   runs without price: \([ $c[] | select(.cost_usd == null) ] | length)   estimated: \([ $c[] | select(.cost_basis == "estimated") ] | length) (\([ $c[] | select(.stale == true) ] | length) after a stale cost-state, \([ $c[] | select(.output_partial == true) ] | length) lower bounds)",
      ( if $v.verified then "  verified: yes ✓ — every session matches the exact figure the harness recorded"
        else "  verified: no — " + ({ "unpriced": "a session or model has no price yet",
              "estimated": "a session latest reading is an estimate; it settles once the session closes right after its last checkpoint",
              "earlier-estimate": "an estimate from before a reset is still in the total",
              "shared-session": "a session is shared with another story, so the split is not measured",
              "no-checkpoints": "nothing recorded" }[$v.reason] // $v.reason) end ),
      ("  tokens: input \([ $c[].token_delta.input // 0 ] | add // 0)  output \([ $c[].token_delta.output // 0 ] | add // 0)  reasoning \([ $c[].token_delta.reasoning // 0 ] | add // 0)  cache_read \([ $c[].token_delta.cache_read // 0 ] | add // 0)  cache_write \([ $c[].token_delta.cache_write // 0 ] | add // 0)"),
      # Checkpoints an older version recorded from OpenCode stay in the total;
      # this line only says how much of it they are. Printed only when some exist.
      ( [ $c[] | select(.harness == "opencode") | (.delta // 0) ] as $legacy
        | if ($legacy | length) > 0
          then "  legacy OpenCode (recorded before OpenCode support was removed): $\(($legacy | add // 0) * 10000 | round / 10000)"
          else empty end ),
      "  by stage:",
      ( [ $c[] | { s: .stage, d: (.delta // 0) } ] | group_by(.s)[] | "    \(.[0].s): $\(([.[].d] | add // 0) * 10000 | round / 10000)" ),
      "  by session:",
      ( [ $c[] | { src: .source, d: (.delta // 0) } ] | group_by(.src)[] | "    \(.[0].src): $\(([.[].d] | add // 0) * 10000 | round / 10000)" ),
      "  by agent/role (observed — derived from what ran, never a fixed list):",
      ( [ $c[].agent_deltas // {} | to_entries[] | { k: .key, d: .value.cost_usd, m: (.value.models // []), p: (.value.output_partial // false) } ]
        | group_by(.k)[]
        | ( [ .[].d | select(. != null) ] ) as $ds
        | "    \(.[0].k): " + (if ($ds | length) == 0 then "unpriced" else (if any(.[]; .p) then "≥" else "" end) + "$\(($ds | add) * 10000 | round / 10000)" end) + "  models \([.[].m[]] | unique | join(", "))" ),
      ( if any($c[]; .output_partial == true) or any($c[].agent_deltas // {} | .[]; .output_partial == true)
        then "  ≥ = lower bound: Claude Code logs a sub-agent message'"'"'s output before it is written; only the final one is recoverable"
        else empty end ),
      "  last step:",
      ( $c | last | "    stage \(.stage)  +" + (if .delta == null then "unpriced" else "$\(.delta * 10000 | round / 10000)" + (if .cost_basis == "estimated" then " (estimated)" else "" end) end) + "  " + ( [ (.agent_deltas // {}) | to_entries[] | "\(.key) " + (if .value.cost_usd == null then "unpriced" else "+$\(.value.cost_usd * 10000 | round / 10000)" end) ] | join("; ") ) )
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
        opt-out) printf '    %s → default (a default model was chosen for this repo or story)\n' "$role" ;;
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
# (the project root inside a live session) `--transcripts` was silently ignored
# and the report described the wrong run. That is the cause of the two
# `session-usage.test.sh` assertions failing from the project root and passing
# from `/tmp`: from `/tmp` no transcript resolves, so the explicit selector was
# finally reached.

# A snapshot is its own entry point: it resolves the current run's transcript,
# normalizes it, and never falls through to the human reports below. When the
# run cannot be resolved it answers `unavailable` rather than a misleading zero.
if [[ -n "$SNAPSHOT_STORY" ]]; then
  if ! have_jq; then
    echo '{"status":"unavailable","reason":"jq required"}'
    exit 0
  fi
  SNAP=""
  SNAP_TX=""
  SNAP_ERR=0
  if [[ -n "$TRANSCRIPT_ARG" ]]; then
    [[ -f "$TRANSCRIPT_ARG" ]] && SNAP_TX="$TRANSCRIPT_ARG"
  else
    SNAP_R="$(resolve_claude)"
    [[ "$SNAP_R" == *$'\t'* ]] && SNAP_TX="${SNAP_R%%$'\t'*}"
  fi
  # The path is the checkpoint's `source`, which pairs it with the previous
  # one: make it absolute and physical, or the same transcript named from
  # two directories would count as two runs (WD-0049).
  if [[ -n "$SNAP_TX" ]]; then
    # `CDPATH=`: with CDPATH set, `cd` echoes the directory and the path
    # would carry it.
    SNAP_TX="$(CDPATH= cd -- "$(dirname -- "$SNAP_TX")" >/dev/null && pwd -P)/$(basename -- "$SNAP_TX")"
    SNAP=$(snapshot_claude "$SNAP_TX") || SNAP_ERR=$?
  fi
  # 2 = the run resolved but is incomplete right now (an unreadable
  # side-chain): said on stderr already, and not the same as no source at all.
  if [[ "$SNAP_ERR" -eq 2 ]]; then
    echo '{"status":"not-recorded"}'
    exit 1
  fi
  if [[ -z "$SNAP" ]]; then
    echo '{"status":"unavailable"}'
    exit 0
  fi
  # A checkpoint that was not recorded exits non-zero (after still printing
  # the snapshot), so a caller can tell; the skills treat this as best-effort.
  SNAP_RC=0
  ledger_record "$SNAPSHOT_STORY" "${SNAPSHOT_STAGE:-manual}" "$SNAP" || SNAP_RC=1
  # Best-effort: settle the story's other sessions, then refresh the API.
  # Neither changes this checkpoint's exit code.
  reconcile_story "$SNAPSHOT_STORY" "$SNAP_TX"
  write_index "$SNAPSHOT_STORY" || true
  printf '%s\n' "$SNAP" | jq '{ source, harness, cost_usd } + (if .cost_basis then { cost_basis } else {} end)
    + (if .stale then { stale } else {} end) + { tokens, models, as_of }'
  exit "$SNAP_RC"
fi

# `--reconcile` settles a story's estimated sessions against the exact figure
# their transcripts hold now (see reconcile_story), then refreshes the API.
if [[ -n "$RECONCILE_STORY" ]]; then
  if ! have_jq; then echo "session-usage.sh --reconcile needs jq." >&2; exit 1; fi
  if ! valid_story_id "$RECONCILE_STORY"; then echo "usage: invalid story id" >&2; exit 1; fi
  reconcile_story "$RECONCILE_STORY" ""
  write_index "$RECONCILE_STORY" || true
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

# No explicit selector: resolve the current run implicitly.
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

echo "No usage source found: no Claude Code transcript for this project." >&2
exit 0
