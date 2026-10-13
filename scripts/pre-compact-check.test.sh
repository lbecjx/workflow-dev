#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Tests for pre-compact-check.sh — the PreCompact hook. It never delivers text
# (PreCompact can't); its job is the story's compaction-state JSON: track the
# hook's `transcript_path` and flip `pendingSave` when there is content past
# the last save. It marks only the stories this session worked (an assistant
# tool call in the transcript wrote their context file), and only while they
# are In Progress. Each case gets a fresh throwaway project and its own
# transcript, three lines long so the save-point arithmetic stays readable.
#
# Also pinned (WD-0026): a state file written by an older version — with
# `current`, `opencodeSession`, `opencodeSeq` — must not break the hook. It is
# replaced by the transcript-tracking shape like any state for another file.
#
#   bash scripts/pre-compact-check.test.sh

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/pre-compact-check.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok() { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }

PROJ="$TMP/proj"
STATE_DIR="$PROJ/.workflow-dev/context/.compaction-state"
TRANSCRIPT="$TMP/session.jsonl"

fresh() { rm -rf "$PROJ"; mkdir -p "$PROJ/.workflow-dev/context"; ( cd "$PROJ" && git init -q . ); }
story() { printf '# %s\n\n### Implementation Status: %s\n' "$1" "${2:-In Progress}" > "$PROJ/.workflow-dev/context/$1.md"; }
hook() { ( cd "$PROJ" && printf '%s' "$1" | bash "$SCRIPT" ); }
precompact() { hook "{\"hook_event_name\":\"PreCompact\",\"transcript_path\":\"$TRANSCRIPT\"}"; }
# A story's save point for the hook's transcript (one per session transcript).
key() { printf '%s' "${1:-$TRANSCRIPT}" | shasum | cut -c1-16; }
state() { cat "$STATE_DIR/$1/$(key "${2:-}").json" 2>/dev/null; }
has_state() { [[ -n "$(ls "$STATE_DIR/$1" 2>/dev/null)" ]]; }
# The session's transcript: one Write of each named story's context file, padded
# with plain lines to three lines.
transcript() {
  : > "$TRANSCRIPT"
  local id n=0
  for id in "$@"; do
    printf '{"message":{"role":"assistant","content":[{"type":"tool_use","name":"Write","input":{"file_path":"%s/.workflow-dev/context/%s.md"}}]},"type":"assistant"}\n' "$PROJ" "$id" >> "$TRANSCRIPT"
    n=$((n + 1))
  done
  while (( n < 3 )); do printf 'l%d\n' "$n" >> "$TRANSCRIPT"; n=$((n + 1)); done
}

# --- 1: a new story starts tracking the transcript, armed ------------------
fresh; story WD-0001; transcript WD-0001
OUT="$(precompact)"; code=$?
S="$(state WD-0001)"
case "$S" in *"\"claudePath\":\"$TRANSCRIPT\""*) ok "state tracks the hook's transcript" ;; *) no "state tracks the hook's transcript (got: $S)" ;; esac
case "$S" in *'"pendingSave":true'*) ok "a freshly tracked transcript is pending" ;; *) no "a freshly tracked transcript is pending (got: $S)" ;; esac
case "$OUT" in *terminalSequence*) ok "the hook rings the bell (its only output)" ;; *) no "the hook rings the bell (got: $OUT)" ;; esac
[[ "$code" == "0" ]] && ok "exit 0" || no "exit 0 (got $code)"
grep -qxF '.workflow-dev/context/.compaction-state/' "$PROJ/.gitignore" 2>/dev/null \
  && ok "the state directory is gitignored" || no "the state directory is gitignored"

# --- 2: nothing past the last save → not re-armed --------------------------
fresh; story WD-0002; transcript WD-0002; mkdir -p "$STATE_DIR"
printf '{"transcriptPath":"%s","length":3,"dateTime":"2026-10-01T00:00:00Z","pendingSave":false}' "$TRANSCRIPT" > "$STATE_DIR/WD-0002.json"
precompact >/dev/null
case "$(state WD-0002)" in *'"pendingSave":false'*) ok "no new lines since the save → stays unarmed" ;; *) no "no new lines since the save → stays unarmed (got: $(state WD-0002))" ;; esac

# --- 3: new lines past the last save → armed, save point kept --------------
fresh; story WD-0003; transcript WD-0003; mkdir -p "$STATE_DIR"
printf '{"transcriptPath":"%s","length":1,"dateTime":"2026-10-01T00:00:00Z","pendingSave":false}' "$TRANSCRIPT" > "$STATE_DIR/WD-0003.json"
precompact >/dev/null
S="$(state WD-0003)"
case "$S" in *'"pendingSave":true'*) ok "new lines since the save → armed" ;; *) no "new lines since the save → armed (got: $S)" ;; esac
case "$S" in *'"claudeLength":1'*'"dateTime":"2026-10-01T00:00:00Z"'*) ok "the last save point is kept" ;; *) no "the last save point is kept (got: $S)" ;; esac

# --- 3b: the save's own shape is read — a saved position survives a compaction
# save-mark-saved.sh writes `claudePath`/`claudeLength`. Reading only the older
# names once made the hook treat every saved story as a new transcript and reset
# it to 0, so the next save re-read everything already saved.
fresh; story WD-0033; transcript WD-0033; mkdir -p "$STATE_DIR"
printf '{"claudePath":"%s","claudeLength":3,"dateTime":"2026-10-01T00:00:00Z","pendingSave":false}' "$TRANSCRIPT" > "$STATE_DIR/WD-0033.json"
precompact >/dev/null
case "$(state WD-0033)" in *'"claudeLength":3'*'"pendingSave":false'*) ok "a saved position (save's shape) is kept, nothing new → unarmed" ;; *) no "a saved position (save's shape) is kept (got: $(state WD-0033))" ;; esac
printf 'l4\n' >> "$TRANSCRIPT"
precompact >/dev/null
case "$(state WD-0033)" in *'"claudeLength":3'*'"pendingSave":true'*) ok "a saved position (save's shape) is kept, new lines → armed" ;; *) no "a saved position (save's shape) is kept, new lines → armed (got: $(state WD-0033))" ;; esac

# --- 4: a closed story is left alone ---------------------------------------
fresh; story WD-0004 Done; transcript WD-0004
precompact >/dev/null
has_state WD-0004 && no "a Done story gets no state" || ok "a Done story gets no state"

# --- 5: no transcript_path → nothing to measure, nothing stored ------------
fresh; story WD-0005; transcript WD-0005
hook '{"hook_event_name":"PreCompact"}' >/dev/null
has_state WD-0005 && no "no transcript → no state written" || ok "no transcript → no state written"

# --- 6: a state file from an older version does not break the hook ---------
fresh; story WD-0006; transcript WD-0006; mkdir -p "$STATE_DIR"
printf '{"current":"opencode","claudePath":"","claudeLength":0,"opencodeSession":"ses_abc","opencodeSeq":4179,"dateTime":"2026-09-27T08:33:52Z","pendingSave":false}' > "$STATE_DIR/WD-0006.json"
OUT="$(precompact)"; code=$?
S="$(state WD-0006)"
[[ "$code" == "0" ]] && ok "legacy state: exit 0" || no "legacy state: exit 0 (got $code)"
case "$S" in *"\"claudePath\":\"$TRANSCRIPT\""*'"pendingSave":true'*) ok "legacy state → tracks the transcript, armed" ;; *) no "legacy state → tracks the transcript, armed (got: $S)" ;; esac
case "$S" in *opencode*) no "legacy fields are not carried forward (got: $S)" ;; *) ok "legacy fields are not carried forward" ;; esac

# --- 8: only the story this session worked is marked -----------------------
# The bug this pins: working WD-0080, a compaction marked WD-0052, which the
# session never touched (and which was Done, see 10).
fresh; story WD-0010; story WD-0011; transcript WD-0010
OUT="$(precompact)"
has_state WD-0010 && ok "the worked story is marked" || no "the worked story is marked"
has_state WD-0011 && no "an open story the session never touched gets no state" || ok "an open story the session never touched gets no state"

# --- 9: a story closed in the session drops out, the next one is marked ----
fresh; story WD-0012 Done; story WD-0013; transcript WD-0012 WD-0013
precompact >/dev/null
has_state WD-0012 && no "the story closed in the session gets no state" || ok "the story closed in the session gets no state"
has_state WD-0013 && ok "the story worked after it is marked" || no "the story worked after it is marked"

# --- 10: a Done story with the template paragraph is not In Progress -------
fresh; transcript WD-0014
cat > "$PROJ/.workflow-dev/context/WD-0014.md" <<'MD'
# WD-0014

### Implementation Status: Done

Set to **In Progress** at creation, always — a context file existing at all means work has begun.
MD
OUT="$(precompact)"; code=$?
has_state WD-0014 && no "a Done story with the template paragraph gets no state" || ok "a Done story with the template paragraph gets no state"
[[ -z "$OUT" && "$code" == "0" ]] && ok "nothing marked → no bell, exit 0" || no "nothing marked → no bell, exit 0 (got '$OUT', exit $code)"

# --- 11: a session that worked no story marks nothing ----------------------
fresh; story WD-0015; transcript
OUT="$(precompact)"
has_state WD-0015 && no "no story worked → no state" || ok "no story worked → no state"
[[ -z "$OUT" ]] && ok "no story worked → no output" || no "no story worked → no output (got '$OUT')"
[[ -d "$STATE_DIR" ]] && no "no story worked → no state directory" || ok "no story worked → no state directory"

# --- 12: two worked stories are both marked, with one bell -----------------
fresh; story WD-0016; story WD-0017; transcript WD-0016 WD-0017
OUT="$(precompact)"
has_state WD-0016 && has_state WD-0017 && ok "both worked stories are marked" || no "both worked stories are marked"
[[ "$(printf '%s' "$OUT" | grep -o terminalSequence | wc -l | tr -d ' ')" == 1 ]] && ok "one bell for the compaction" || no "one bell for the compaction (got '$OUT')"

# --- 13: each session keeps its own save point; none is replaced -----------
# Two sessions on one story used to share a single state file, so the later
# compaction replaced the earlier session's position and its unsaved part was
# lost from tracking. Now each transcript has its own.
fresh; story WD-0020; transcript WD-0020
precompact >/dev/null
A_STATE="$(state WD-0020)"
OTHER="$TMP/other-session.jsonl"
printf '{"message":{"role":"assistant","content":[{"type":"tool_use","name":"Edit","input":{"file_path":"%s/.workflow-dev/context/WD-0020.md"}}]},"type":"assistant"}\nx\n' "$PROJ" > "$OTHER"
hook "{\"hook_event_name\":\"PreCompact\",\"transcript_path\":\"$OTHER\"}" >/dev/null
[[ "$(state WD-0020)" == "$A_STATE" ]] && ok "another session's compaction leaves this session's save point as it was" || no "another session's compaction leaves this session's save point (got: $(state WD-0020))"
case "$(state WD-0020 "$OTHER")" in *"\"claudePath\":\"$OTHER\""*'"pendingSave":true'*) ok "the other session gets its own save point" ;; *) no "the other session gets its own save point (got: $(state WD-0020 "$OTHER"))" ;; esac

# --- 14: a single-file state of this transcript moves to the new place -----
fresh; story WD-0021; transcript WD-0021; mkdir -p "$STATE_DIR"
printf '{"claudePath":"%s","claudeLength":2,"dateTime":"2026-10-01T00:00:00Z","pendingSave":false}' "$TRANSCRIPT" > "$STATE_DIR/WD-0021.json"
precompact >/dev/null
[[ -f "$STATE_DIR/WD-0021.json" ]] && no "the single-file state of this transcript is moved" || ok "the single-file state of this transcript is moved"
case "$(state WD-0021)" in *'"claudeLength":2'*'"pendingSave":true'*) ok "its saved position comes along" ;; *) no "its saved position comes along (got: $(state WD-0021))" ;; esac

# --- 15: a single-file state of another transcript stays for its save ------
fresh; story WD-0022; transcript WD-0022; mkdir -p "$STATE_DIR"
printf '{"claudePath":"/tmp/ended-session.jsonl","claudeLength":2,"dateTime":null,"pendingSave":true}' > "$STATE_DIR/WD-0022.json"
precompact >/dev/null
[[ -f "$STATE_DIR/WD-0022.json" ]] && ok "another session's single-file state is kept" || no "another session's single-file state is kept"

# --- 16: a symlinked story folder is never written through -----------------
fresh; story WD-0023; transcript WD-0023; mkdir -p "$STATE_DIR" "$TMP/elsewhere"
ln -s "$TMP/elsewhere" "$STATE_DIR/WD-0023"
precompact >/dev/null
[[ -z "$(ls "$TMP/elsewhere")" ]] && ok "a symlinked story folder is not written through" || no "a symlinked story folder is not written through"
rm -rf "$TMP/elsewhere"

# --- 7: no .workflow-dev/context at all is silence, not a failure ----------
rm -rf "$PROJ/.workflow-dev"
OUT="$(precompact)"; code=$?
[[ -z "$OUT" && "$code" == "0" ]] && ok "no context dir → silent, exit 0" || no "no context dir → silent, exit 0 (got '$OUT', exit $code)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
exit $((fail == 0 ? 0 : 1))
