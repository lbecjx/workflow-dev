#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code and OpenCode
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Tests for pre-compact-check.sh's `--arm` mode — the harness-with-no-PreCompact
# half. Its whole job is a side effect on a file it does not own: the very same
# JSON carries `opencodeSession`/`opencodeSeq` for the OpenCode save flow, and
# `--arm` deliberately reads none of them. So the assertions that matter are the
# ones about what it must NOT do — lose a field, invent a file, touch a closed
# story, or arm something it cannot rewrite.
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

# A state file in the real OpenCode shape: no transcriptPath, the save flow's
# own fields, and one field this script has never heard of.
seed_state() { # $1 = story, $2 = pendingSave value
  mkdir -p "$STATE_DIR"
  printf '{"current":"opencode","claudePath":"","claudeLength":0,"opencodeSession":"ses_abc","opencodeSeq":4179,"dateTime":"2026-09-27T08:33:52Z","pendingSave":%s,"somethingNew":42}' "$2" > "$STATE_DIR/$1.json"
}
in_progress() { mkdir -p "$PROJ/.workflow-dev/context"; printf '# %s\n\n### Implementation Status: In Progress\n' "$1" > "$PROJ/.workflow-dev/context/$1.md"; }

arm() { ( cd "$PROJ" && bash "$SCRIPT" --arm '{"harness":"opencode"}' ); }
hook() { ( cd "$PROJ" && printf '%s' "$1" | bash "$SCRIPT" ); }
state() { cat "$STATE_DIR/$1.json" 2>/dev/null; }

# --- 1: arming flips the flag, and only the flag ----------------------------
in_progress WD-0001
seed_state WD-0001 false
OUT="$(arm)"
[[ -z "$OUT" ]] && ok "--arm is silent" || no "--arm is silent (got: $OUT)"
S="$(state WD-0001)"
case "$S" in *'"pendingSave":true'*) ok "--arm flips pendingSave to true" ;; *) no "--arm flips pendingSave to true (got: $S)" ;; esac
case "$S" in *'"opencodeSession":"ses_abc"'*) ok "the save flow's session id survives" ;; *) no "the save flow's session id survives (got: $S)" ;; esac
case "$S" in *'"opencodeSeq":4179'*) ok "the save flow's seq survives" ;; *) no "the save flow's seq survives (got: $S)" ;; esac
case "$S" in *'"claudePath":""'*) ok "the other harness's fields survive too" ;; *) no "the other harness's fields survive too (got: $S)" ;; esac
case "$S" in *'"somethingNew":42'*) ok "a field this script has never heard of survives" ;; *) no "a field it has never heard of survives (got: $S)" ;; esac
[[ -f "$STATE_DIR/.pendingSave.XXXXXX" ]] && no "no template file left behind" || ok "no template file left behind"
TMP_LEFTOVERS=$(find "$STATE_DIR" -name '.pendingSave.*' 2>/dev/null | wc -l | tr -d ' ')
[[ "$TMP_LEFTOVERS" == "0" ]] && ok "no mktemp leftovers" || no "no mktemp leftovers (found $TMP_LEFTOVERS)"

# --- 2: a story with no state file is skipped, never invented ---------------
in_progress WD-0002
arm >/dev/null 2>&1
[[ -f "$STATE_DIR/WD-0002.json" ]] && no "--arm never creates a state file" || ok "--arm never creates a state file"

# --- 3: a closed story is left alone ----------------------------------------
mkdir -p "$PROJ/.workflow-dev/context"
printf '# WD-0003\n\n### Implementation Status: Done\n' > "$PROJ/.workflow-dev/context/WD-0003.md"
seed_state WD-0003 false
arm >/dev/null 2>&1
case "$(state WD-0003)" in *'"pendingSave":false'*) ok "a Done story is not armed" ;; *) no "a Done story is not armed (got: $(state WD-0003))" ;; esac

# --- 4: a shape it cannot rewrite is skipped rather than half-done ----------
# The guard and the substitution must agree; a key carrying something the regex
# cannot match has to be skipped, not rewritten to an identical file.
in_progress WD-0004
printf '{"current":"opencode","opencodeSession":"ses_q","pendingSave":"maybe"}' > "$STATE_DIR/WD-0004.json"
arm >/dev/null 2>&1
case "$(state WD-0004)" in *'"pendingSave":"maybe"'*) ok "an unrewritable pendingSave is left untouched" ;; *) no "an unrewritable pendingSave is left untouched (got: $(state WD-0004))" ;; esac

# --- 5: the Claude Code hook path still needs a transcript ------------------
# --arm must not become the hook path's behaviour: without a transcript_path
# there is nothing to measure, so the hook mode does not arm.
in_progress WD-0005
seed_state WD-0005 false
hook '{"hook_event_name":"PreCompact"}' >/dev/null 2>&1
case "$(state WD-0005)" in *'"pendingSave":false'*) ok "hook mode without a transcript stores nothing to arm" ;; *) no "hook mode without a transcript stores nothing to arm (got: $(state WD-0005))" ;; esac

# --- 6: no .workflow-dev/context at all is silence, not a failure -----------
rm -rf "$PROJ/.workflow-dev"
OUT="$(arm)"; code=$?
[[ -z "$OUT" && "$code" == "0" ]] && ok "no context dir → silent, exit 0" || no "no context dir → silent, exit 0 (got '$OUT', exit $code)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
exit $((fail == 0 ? 0 : 1))
