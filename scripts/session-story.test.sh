#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Tests for session-story.sh: session_stories, the stories a transcript worked
# on, and the status reader it filters them with. The fixture lines mimic real
# Claude Code transcript lines, with "type":"assistant" after the content block.
#
#   bash scripts/session-story.test.sh

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=session-story.sh
source "$HERE/session-story.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok() { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }

CTX="$TMP/repo/.workflow-dev/context"
T="$TMP/session.jsonl"

fresh() { rm -rf "$TMP/repo"; mkdir -p "$CTX"; : > "$T"; }
story() { printf '# %s\n\n### Implementation Status: %s\n' "$1" "${2:-In Progress}" > "$CTX/$1.md"; }
# One assistant tool call: $1 tool name, $2 its input object.
call() {
  printf '{"parentUuid":"p","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_x","name":"%s","input":%s}]},"type":"assistant","uuid":"u"}\n' "$1" "$2" >> "$T"
}
# A tool result: the user side of the transcript.
result() {
  printf '{"parentUuid":"p","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_x","content":"%s"}]},"type":"user","uuid":"u"}\n' "$1" >> "$T"
}
stories() { session_stories "$T" "$CTX" | tr '\n' ' ' | sed 's/ $//'; }
check() { # check <label> <expected> <got>
  [[ "$3" == "$2" ]] && ok "$1" || no "$1 (want: '$2', got: '$3')"
}

P="$TMP/repo/.workflow-dev/context"

# --- the signals that attach a story ----------------------------------------
fresh; story WD-0001
call Read "{\"file_path\":\"$P/WD-0001.md\"}"
check "a Read alone (a sibling read for reference) does not attach the story" "" "$(stories)"

fresh; story WD-0001
call Edit "{\"file_path\":\"$P/WD-0001.md\",\"old_string\":\"a\",\"new_string\":\"b\"}"
check "an Edit attaches the story" "WD-0001" "$(stories)"

fresh; story WD-0001
call Write "{\"file_path\":\"$P/WD-0001.md\",\"content\":\"x\"}"
check "a Write of the context file attaches the story" "WD-0001" "$(stories)"

fresh; story WD-0001
call Skill '{"args":"WD-0001","skill":"workflow-dev:resume"}'
check "args before skill in the JSON still attach the story" "WD-0001" "$(stories)"

fresh; story WD-0001
call Skill '{"skill":"workflow-dev:resume","args":"WD-0001"}'
check "a workflow-dev skill whose args name the code attaches the story" "WD-0001" "$(stories)"

fresh; story WD-0001
call Skill '{"skill":"workflow-dev:init","args":"local-backlog/wd-0001-some-slug.md"}'
check "the code inside a backlog path in the args, any case" "WD-0001" "$(stories)"

# --- what does not attach one -----------------------------------------------
fresh; story WD-0001
call Skill '{"skill":"local-backlog:update-status","args":"WD-0001 \"In Progress\""}'
check "another plugin's skill naming the code does not attach it" "" "$(stories)"

fresh; story WD-0001
call Bash '{"command":"grep -n Decision .workflow-dev/context/WD-0001.md","description":"x"}'
check "a Bash command reading the context file for reference does not attach it" "" "$(stories)"

fresh; story WD-0001; story WD-0002
call Write "{\"file_path\":\"$P/WD-0001.md\"}"
call Skill '{"skill":"workflow-dev:summarize-changes","args":"PR for WD-0001; follows up WD-0002"}'
call Skill '{"skill":"workflow-dev:plan","args":"WD-0001 then WD-0002"}'
check "a code in a skill's free text does not attach it" "WD-0001" "$(stories)"

fresh; story WD-0001; story WD-0002
call Write "{\"file_path\":\"$P/WD-0001.md\",\"content\":\"bug: it marked \\\"$P/WD-0002.md\\\" and .workflow-dev/context/WD-0002.md\"}"
check "another story's path inside a Write's content does not attach it" "WD-0001" "$(stories)"

fresh; story WD-0001
result "$P/WD-0001.md"
check "a tool result naming the path does not attach it" "" "$(stories)"

fresh; story WD-0001
printf '{"message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"%s/WD-0001.md"}}]},"type":"user"}\n' "$P" >> "$T"
check "a tool_use outside an assistant line does not attach it" "" "$(stories)"

fresh; story WD-0001
printf '{"message":{"content":[{"type":"text","text":"see %s/WD-0001.md"}]},"type":"assistant"}\n' "$P" >> "$T"
check "assistant prose naming the path does not attach it" "" "$(stories)"

fresh; story WD-21; story WD-215
call Write "{\"file_path\":\"$P/WD-215.md\"}"
call Skill '{"skill":"workflow-dev:plan","args":"WD-215"}'
check "WD-21 is not WD-215" "WD-215" "$(stories)"

fresh; story WD-0001
printf '# REPO\n\n### Implementation Status: In Progress\n' > "$CTX/REPO.md"
call Write "{\"file_path\":\"$P/REPO.md\"}"
check "REPO.md is never a story" "" "$(stories)"

fresh; story WD-0001
call Write "{\"file_path\":\"$P/pr-drafts/WD-0001.md\",\"content\":\"x\"}"
check "a PR draft of the story is not its context file" "" "$(stories)"

fresh; story WD-0001
call Write "{\"file_path\":\"/elsewhere/checkout/.workflow-dev/context/WD-0001.md\"}"
check "the same file name in another checkout does not attach it" "" "$(stories)"

fresh
call Write "{\"file_path\":\"$P/WD-0009.md\"}"
check "a story with no context file is not listed" "" "$(stories)"

# --- the status filter --------------------------------------------------------
fresh; story WD-0001 Done; story WD-0002 "Won't Do"
call Write "{\"file_path\":\"$P/WD-0001.md\"}"
call Write "{\"file_path\":\"$P/WD-0002.md\"}"
check "Done and Won't Do stories are never listed" "" "$(stories)"

fresh
cat > "$CTX/WD-0001.md" <<'MD'
# WD-0001

### Implementation Status: Done

Set to **In Progress** at creation, always — a context file existing at all means work has begun.
MD
call Write "{\"file_path\":\"$P/WD-0001.md\"}"
check "a Done story with the template paragraph is not listed" "" "$(stories)"

fresh; story WD-0001 "Done (was In Progress until the merge)"
call Write "{\"file_path\":\"$P/WD-0001.md\"}"
check "a status that only mentions In Progress is not In Progress" "" "$(stories)"

fresh
printf '# WD-0001\n\n## Implementation Status\n\n**Status:** In Progress\n' > "$CTX/WD-0001.md"
call Write "{\"file_path\":\"$P/WD-0001.md\"}"
check "the bare heading plus Status line form is read" "WD-0001" "$(stories)"

fresh; story WD-0001 Done; story WD-0002
call Edit "{\"file_path\":\"$P/WD-0001.md\",\"old_string\":\"In Progress\",\"new_string\":\"Done\"}"
call Write "{\"file_path\":\"$P/WD-0002.md\",\"content\":\"x\"}"
check "a story closed in the session drops out, the next one stays" "WD-0002" "$(stories)"

fresh; story WD-0002; story WD-0001
call Write "{\"file_path\":\"$P/WD-0002.md\"}"
call Write "{\"file_path\":\"$P/WD-0001.md\"}"
check "two worked stories, sorted" "WD-0001 WD-0002" "$(stories)"

# --- spellings of a written path ----------------------------------------------
fresh; story WD-0001
call Write "{\"file_path\":\"$P/../context/WD-0001.md\",\"content\":\"x\"}"
check "an unnormalized path to the file still attaches it" "WD-0001" "$(stories)"

fresh; story WD-0001
ln -s "$TMP/repo" "$TMP/link"
call Edit "{\"file_path\":\"$TMP/link/.workflow-dev/context/WD-0001.md\",\"old_string\":\"a\",\"new_string\":\"b\"}"
check "a path through a symlink still attaches it" "WD-0001" "$(stories)"
rm -f "$TMP/link"

Q="$TMP/q\"d\\x"; mkdir -p "$Q/.workflow-dev/context"
printf '# WD-0001\n\n### Implementation Status: In Progress\n' > "$Q/.workflow-dev/context/WD-0001.md"
QE="${Q//\\/\\\\}"; QE="${QE//\"/\\\"}"
: > "$T"
call Write "{\"file_path\":\"$QE/.workflow-dev/context/WD-0001.md\",\"content\":\"x\"}"
check "a project path holding a quote and a backslash still attaches it" "WD-0001" "$(session_stories "$T" "$Q/.workflow-dev/context" | tr '\n' ' ' | sed 's/ $//')"

# --- several tool_use blocks on one line --------------------------------------
fresh; story WD-0001; story WD-0002
printf '{"message":{"role":"assistant","content":[{"type":"tool_use","name":"Write","input":{"file_path":"%s/WD-0001.md","content":"x"}},{"type":"tool_use","name":"Read","input":{"file_path":"%s/WD-0002.md"}}]},"type":"assistant"}\n' "$P" "$P" >> "$T"
check "a Read beside a Write on one line is still only a Read" "WD-0001" "$(stories)"

fresh; story WD-0001; story WD-0002
printf '{"message":{"role":"assistant","content":[{"type":"tool_use","name":"Skill","input":{"skill":"workflow-dev:plan","args":"x"}},{"type":"tool_use","name":"Skill","input":{"skill":"workflow-dev:summarize-changes","args":"WD-0002 note"}}]},"type":"assistant"}\n' >> "$T"
check "another skill's args on the same line do not attach" "" "$(stories)"

# --- a story skill typed by the human -----------------------------------------
fresh; story WD-0001
printf '{"type":"user","message":{"role":"user","content":"<command-message>workflow-dev:resume</command-message>\\n<command-name>/workflow-dev:resume</command-name>\\n<command-args>WD-0001</command-args>"}}\n' >> "$T"
check "a typed /workflow-dev:resume attaches the story" "WD-0001" "$(stories)"

fresh; story WD-0001
printf '{"type":"user","message":{"role":"user","content":"<command-message>workflow-dev:init</command-message>\\n<command-name>/workflow-dev:init</command-name>\\n<command-args>local-backlog/WD-0001-slug.md</command-args>"}}\n' >> "$T"
check "a typed init with a backlog path attaches the story" "WD-0001" "$(stories)"

fresh; story WD-0001
printf '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"<command-name>/workflow-dev:resume</command-name><command-args>WD-0001</command-args>"}]}}\n' >> "$T"
check "the same text inside a tool result does not attach it" "" "$(stories)"

fresh; story WD-0001
printf '{"type":"user","message":{"role":"user","content":"<command-message>workflow-dev:help</command-message>\\n<command-name>/workflow-dev:help</command-name>\\n<command-args>WD-0001</command-args>"}}\n' >> "$T"
check "a typed skill that does not start story work does not attach it" "" "$(stories)"

# --- a code named later in a backlog slug -------------------------------------
fresh; story WD-0005; story WD-0012
call Skill '{"skill":"workflow-dev:init","args":"local-backlog/wd-0012-follow-up-to-wd-0005-regression.md"}'
check "only the code the slug starts with attaches" "WD-0012" "$(stories)"

# --- degenerate transcripts ---------------------------------------------------
fresh; story WD-0001
check "an empty transcript lists nothing" "" "$(stories)"
OUT="$(session_stories "$TMP/missing.jsonl" "$CTX")"; code=$?
check "a missing transcript lists nothing" "" "$OUT"
check "a missing transcript returns 0" "0" "$code"
OUT="$(session_stories "" "$CTX")"
check "no transcript path lists nothing" "" "$OUT"

# A long session repeats the same skill argument many times. Each distinct
# argument is checked once per story, so the hooks that read the transcript
# stay inside their timeout.
fresh; story WD-0002
for _ in 1 2 3 4 5 6 7 8 9 10; do call Skill '{"skill":"workflow-dev:implement","args":"WD-0001"}'; done
COUNT="$TMP/arg-calls"; : > "$COUNT"
eval "orig_$(declare -f arg_names_code)"
arg_names_code() { printf 'x\n' >> "$COUNT"; orig_arg_names_code "$@"; }
check "a repeated argument does not attach another story" "" "$(stories)"
check "a repeated argument is checked once per story" "1" "$(wc -l < "$COUNT" | tr -d ' ')"
eval "$(declare -f orig_arg_names_code | sed '1s/^orig_//')"

fresh; story WD-0001
printf '\000\001binary\n' >> "$T"
call Write "{\"file_path\":\"$P/WD-0001.md\"}"
check "a transcript with binary bytes is still read" "WD-0001" "$(stories)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
