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
# the last save. Each case gets a fresh throwaway project, because the hook
# stops at the first In Progress story it finds.
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
state() { cat "$STATE_DIR/$1.json" 2>/dev/null; }

printf 'l1\nl2\nl3\n' > "$TRANSCRIPT"

# --- 1: a new story starts tracking the transcript, armed ------------------
fresh; story WD-0001
OUT="$(precompact)"; code=$?
S="$(state WD-0001)"
case "$S" in *"\"claudePath\":\"$TRANSCRIPT\""*) ok "state tracks the hook's transcript" ;; *) no "state tracks the hook's transcript (got: $S)" ;; esac
case "$S" in *'"pendingSave":true'*) ok "a freshly tracked transcript is pending" ;; *) no "a freshly tracked transcript is pending (got: $S)" ;; esac
case "$OUT" in *terminalSequence*) ok "the hook rings the bell (its only output)" ;; *) no "the hook rings the bell (got: $OUT)" ;; esac
[[ "$code" == "0" ]] && ok "exit 0" || no "exit 0 (got $code)"
grep -qxF '.workflow-dev/context/.compaction-state/' "$PROJ/.gitignore" 2>/dev/null \
  && ok "the state directory is gitignored" || no "the state directory is gitignored"

# --- 2: nothing past the last save → not re-armed --------------------------
fresh; story WD-0002; mkdir -p "$STATE_DIR"
printf '{"transcriptPath":"%s","length":3,"dateTime":"2026-10-01T00:00:00Z","pendingSave":false}' "$TRANSCRIPT" > "$STATE_DIR/WD-0002.json"
precompact >/dev/null
case "$(state WD-0002)" in *'"pendingSave":false'*) ok "no new lines since the save → stays unarmed" ;; *) no "no new lines since the save → stays unarmed (got: $(state WD-0002))" ;; esac

# --- 3: new lines past the last save → armed, save point kept --------------
fresh; story WD-0003; mkdir -p "$STATE_DIR"
printf '{"transcriptPath":"%s","length":1,"dateTime":"2026-10-01T00:00:00Z","pendingSave":false}' "$TRANSCRIPT" > "$STATE_DIR/WD-0003.json"
precompact >/dev/null
S="$(state WD-0003)"
case "$S" in *'"pendingSave":true'*) ok "new lines since the save → armed" ;; *) no "new lines since the save → armed (got: $S)" ;; esac
case "$S" in *'"claudeLength":1'*'"dateTime":"2026-10-01T00:00:00Z"'*) ok "the last save point is kept" ;; *) no "the last save point is kept (got: $S)" ;; esac

# --- 3b: the save's own shape is read — a saved position survives a compaction
# save-mark-saved.sh writes `claudePath`/`claudeLength`. Reading only the older
# names once made the hook treat every saved story as a new transcript and reset
# it to 0, so the next save re-read everything already saved.
fresh; story WD-0033; mkdir -p "$STATE_DIR"
printf '{"claudePath":"%s","claudeLength":3,"dateTime":"2026-10-01T00:00:00Z","pendingSave":false}' "$TRANSCRIPT" > "$STATE_DIR/WD-0033.json"
precompact >/dev/null
case "$(state WD-0033)" in *'"claudeLength":3'*'"pendingSave":false'*) ok "a saved position (save's shape) is kept, nothing new → unarmed" ;; *) no "a saved position (save's shape) is kept (got: $(state WD-0033))" ;; esac
printf 'l4\n' >> "$TRANSCRIPT"
precompact >/dev/null
case "$(state WD-0033)" in *'"claudeLength":3'*'"pendingSave":true'*) ok "a saved position (save's shape) is kept, new lines → armed" ;; *) no "a saved position (save's shape) is kept, new lines → armed (got: $(state WD-0033))" ;; esac
printf 'l1\nl2\nl3\n' > "$TRANSCRIPT"

# --- 4: a closed story is left alone ---------------------------------------
fresh; story WD-0004 Done
precompact >/dev/null
[[ -f "$STATE_DIR/WD-0004.json" ]] && no "a Done story gets no state" || ok "a Done story gets no state"

# --- 5: no transcript_path → nothing to measure, nothing stored ------------
fresh; story WD-0005
hook '{"hook_event_name":"PreCompact"}' >/dev/null
[[ -f "$STATE_DIR/WD-0005.json" ]] && no "no transcript → no state written" || ok "no transcript → no state written"

# --- 6: a state file from an older version does not break the hook ---------
fresh; story WD-0006; mkdir -p "$STATE_DIR"
printf '{"current":"opencode","claudePath":"","claudeLength":0,"opencodeSession":"ses_abc","opencodeSeq":4179,"dateTime":"2026-09-27T08:33:52Z","pendingSave":false}' > "$STATE_DIR/WD-0006.json"
OUT="$(precompact)"; code=$?
S="$(state WD-0006)"
[[ "$code" == "0" ]] && ok "legacy state: exit 0" || no "legacy state: exit 0 (got $code)"
case "$S" in *"\"claudePath\":\"$TRANSCRIPT\""*'"pendingSave":true'*) ok "legacy state → tracks the transcript, armed" ;; *) no "legacy state → tracks the transcript, armed (got: $S)" ;; esac
case "$S" in *opencode*) no "legacy fields are not carried forward (got: $S)" ;; *) ok "legacy fields are not carried forward" ;; esac

# --- 7: no .workflow-dev/context at all is silence, not a failure ----------
rm -rf "$PROJ/.workflow-dev"
OUT="$(precompact)"; code=$?
[[ -z "$OUT" && "$code" == "0" ]] && ok "no context dir → silent, exit 0" || no "no context dir → silent, exit 0 (got '$OUT', exit $code)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
exit $((fail == 0 ? 0 : 1))
