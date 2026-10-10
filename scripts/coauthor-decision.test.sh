#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Tests for coauthor-decision.sh: which story the decision is read from, when a
# row means yes (only one shape does), and what a yes lets through. Every case
# that is not an explicit, readable yes from the human must read as no — that is
# what keeps the attribution deny exactly as it was. Runs in a throwaway git
# project, never against this repo's live context.
#
#   bash scripts/coauthor-decision.test.sh

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

pass=0
fail=0
ok() { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }
expect() { [[ "$2" == "$3" ]] && ok "$1" || no "$1 (got: $2, want: $3)"; }

PROJ="$TMP/proj"
CTX="$PROJ/.workflow-dev/context"
mkdir -p "$CTX"
git -C "$PROJ" init -q -b wd-0099-coauthor 2>/dev/null || { git -C "$PROJ" init -q; git -C "$PROJ" checkout -q -b wd-0099-coauthor; }

# A story file: $1 = code, $2 = Implementation Status, $3 = the Decisions rows.
story() {
  printf '# %s: a story\n\n## 2. Working Memory\n\n### Decisions\n| Date | Decision | Decided by |\n|-------|----------|---------------|\n%s\n\n### Discoveries\n- none\n\n## 3. Progress\n\n### Implementation Status: %s\n' \
    "$1" "$3" "$2" > "$CTX/$1.md"
}
reset() { rm -f "$CTX"/*.md; }
decision() { ( cd "$PROJ" && bash -c 'source "$1"; coauthor_decision' _ "$HERE/coauthor-decision.sh" ); }
on_branch() { git -C "$PROJ" checkout -q -B "$1"; }

YES='| 2026-10-10 | Agent co-authorship: yes | Human |'
NO='| 2026-10-10 | Agent co-authorship: no | Human |'

# --- 1: the row --------------------------------------------------------------
reset; story WD-0099 "In Progress" "$YES"
expect "a well-formed yes row decided by Human → yes" "$(decision)" yes
reset; story WD-0099 "In Progress" '| 2026-10-10 | Agent co-authorship: YES | Human |'
expect "YES is not the recorded value → no" "$(decision)" no
reset; story WD-0099 "In Progress" ''
expect "no row → no" "$(decision)" no
reset; story WD-0099 "In Progress" "$NO"
expect "a no row → no" "$(decision)" no
reset; story WD-0099 "In Progress" '| | Agent co-authorship: yes | Human |'
expect "yes row with no date → no" "$(decision)" no
reset; story WD-0099 "In Progress" '| 2026-10-10 | Agent co-authorship: sí | Human |'
expect "value other than yes (sí) → no" "$(decision)" no
reset; story WD-0099 "In Progress" '| 2026-10-10 | Agent co-authorship: maybe | Human |'
expect "value other than yes (maybe) → no" "$(decision)" no
reset; story WD-0099 "In Progress" '| 2026-10-10 | Agent co-authorship: yes | Human | extra |'
expect "a row with an extra cell → no" "$(decision)" no
reset; story WD-0099 "In Progress" "$YES
$NO"
expect "yes and no rows together → no" "$(decision)" no
reset; story WD-0099 "In Progress" "$YES
$YES"
expect "two yes rows → no" "$(decision)" no
reset; story WD-0099 "In Progress" '| 2026-10-10 | Agent co-authorship: yes | Agent (inferred) |'
expect "yes inferred by the agent → no" "$(decision)" no
reset; story WD-0099 "In Progress" "$YES
| 2026-10-10 | Agent co-authorship: yes, but | Human |"
expect "a malformed second row still makes it ambiguous → no" "$(decision)" no
reset; story WD-0099 "In Progress" "$YES
| 2026-10-11 | Agent co-authorship : no | Human |"
expect "a second row with a space before the colon → no" "$(decision)" no
reset; story WD-0099 "In Progress" "$YES
| 2026-10-11 | Agent co-authorship – no | Human |"
expect "a second row with no colon → no" "$(decision)" no
reset; story WD-0099 "In Progress" "$YES
2026-10-11 | Agent co-authorship: no | Human |"
expect "a second row with no leading pipe → no" "$(decision)" no
reset; story WD-0099 "In Progress" '2026-10-10 | Agent co-authorship: yes | Human |'
expect "a lone yes row with no leading pipe → no" "$(decision)" no
reset; story WD-0099 "In Progress" "$YES
| 2026-10-11 | Agent co authorship: no | Human |"
expect "a second row spelled co authorship → no" "$(decision)" no
reset; story WD-0099 "In Progress" "$YES
| 2026-10-11 | Agent co_authorship: no | Human |"
expect "a second row spelled co_authorship → no" "$(decision)" no

# --- 2: where the row sits ---------------------------------------------------
reset; story WD-0099 "In Progress" '```
| 2026-10-10 | Agent co-authorship: yes | Human |
```'
expect "a yes row inside a fenced block → no" "$(decision)" no
reset
printf '# WD-0099: a story\n\n**Acceptance Criteria:**\n%s\n\n### Decisions\n| Date | Decision | Decided by |\n\n### Implementation Status: In Progress\n' "$YES" > "$CTX/WD-0099.md"
expect "a yes row outside the Decisions section → no" "$(decision)" no

# --- 3: which story ----------------------------------------------------------
reset; rm -rf "$CTX"
expect "no .workflow-dev/context → no" "$(decision)" no
mkdir -p "$CTX"
reset; story WD-0099 "Done" "$YES"
expect "the only story is Done → no" "$(decision)" no
reset; story WD-0099 "In Progress" "$YES"; story WD-0098 "In Progress" "$NO"
expect "two In Progress, the branch names the yes one → yes" "$(decision)" yes
on_branch wd-0098-other
expect "…and the branch names the no one → no" "$(decision)" no
on_branch wd-0098-wd-0099-merge
expect "the branch names both → no" "$(decision)" no
on_branch feature-unrelated
expect "two In Progress, the branch names neither → no" "$(decision)" no
reset; story WD-0099 "In Progress" "$YES"
expect "one In Progress, the branch names none → yes" "$(decision)" yes
on_branch wd-0101-not-initd
expect "the branch carries a code no story file has → no" "$(decision)" no
on_branch wd-0099-coauthor
reset; story WD-0099 "Done" ''; story WD-0100 "In Progress" "$YES"
expect "the branch names a Done story, another In Progress has yes → no" "$(decision)" no
git -C "$PROJ" commit -q --allow-empty -m seed 2>/dev/null
git -C "$PROJ" checkout -q --detach 2>/dev/null
expect "a detached HEAD, one In Progress story with yes → no" "$(decision)" no
on_branch wd-0099-coauthor
reset; story WD-0099 "In Progress" "$YES"
if [[ $(id -u) -ne 0 ]]; then
  chmod 000 "$CTX/WD-0099.md"
  expect "an unreadable story file → no" "$(decision)" no
  chmod 644 "$CTX/WD-0099.md"
else
  echo "  skip  unreadable file (running as root)"
fi

# --- 4: what a yes lets through ----------------------------------------------
# Fixtures are built here, never typed into a shell command: the live hook would
# deny that command for carrying them.
lib() { bash -c 'source "$1"; shift; "$@"' _ "$HERE/coauthor-decision.sh" "$@"; }
attr() { lib has_ai_attribution "$1" "$2" && printf attribution || printf clean; }
TRAILER='Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>'
PRLINE='🤖 Generated with [Claude Code](https://claude.com/claude-code)'
MSG=$(printf 'Add a thing\n\nBody text.\n\n%s' "$TRAILER")
PRBODY=$(printf 'Summary.\n\n%s' "$PRLINE")

expect "yes: the trailer passes" "$(attr "$MSG" yes)" clean
expect "yes: the PR line passes" "$(attr "$PRBODY" yes)" clean
expect "no: the trailer is attribution" "$(attr "$MSG" no)" attribution
expect "no: the PR line is attribution" "$(attr "$PRBODY" no)" attribution
expect "an unknown decision is no" "$(attr "$MSG" maybe)" attribution
expect "yes: the trailer closing a -m quote passes" "$(attr "$(printf 'git commit -m "x\n\n%s"' "$TRAILER")" yes)" clean
expect "yes: the trailer with more text on its line is attribution" "$(attr "$(printf 'x\n\n%s and more' "$TRAILER")" yes)" attribution
expect "yes: the trailer followed by another flag is attribution" "$(attr "$(printf 'x\n\n%s" --title y' "$TRAILER")" yes)" attribution
expect "yes: AI-generated in the body is still attribution" "$(attr "$(printf 'AI-generated change\n\n%s' "$TRAILER")" yes)" attribution
expect "yes: written by an AI in the body is still attribution" "$(attr "$(printf 'This was written by an AI.\n\n%s' "$TRAILER")" yes)" attribution
expect "yes: a lone robot emoji is still attribution" "$(attr "$(printf 'Done 🤖\n\n%s' "$TRAILER")" yes)" attribution
expect "clean text is clean either way" "$(attr 'Add a thing' no)" clean
expect "yes: a credit phrase inside the trailer name is attribution" "$(attr "$(printf 'x\n\nCo-Authored-By: AI-generated written by an AI <a@b.c>')" yes)" attribution
expect "yes: a credit phrase inside the PR link text is attribution" "$(attr "$(printf 'x\n\n🤖 Generated with [AI-generated code](https://claude.ai)')" yes)" attribution
expect "yes: a quote inside the trailer name is attribution" "$(attr "$(printf 'x\n\nCo-Authored-By: A" -m "Generated by claude <a@b.c>')" yes)" attribution

# --- 5: a command aimed at another repository --------------------------------
elsewhere() { lib coauthor_command_elsewhere "$1" && printf elsewhere || printf here; }
expect "git commit → here" "$(elsewhere 'git commit -m "x"')" here
expect "git -C dir commit → elsewhere" "$(elsewhere 'git -C /other commit -m "x"')" elsewhere
expect "--git-dir → elsewhere" "$(elsewhere 'git --git-dir=/o/.git commit -m x')" elsewhere
expect "cd before the commit → elsewhere" "$(elsewhere 'cd /other && git commit -m x')" elsewhere
expect "gh -R → elsewhere" "$(elsewhere 'gh pr create -R o/r --title x --body y')" elsewhere
expect "GIT_DIR= → elsewhere" "$(elsewhere 'GIT_DIR=/o/.git git commit -m x')" elsewhere
expect "GH_REPO= → elsewhere" "$(elsewhere 'GH_REPO=o/r gh pr create --title x --body y')" elsewhere
expect "gh -R glued to its value → elsewhere" "$(elsewhere 'gh pr create -Ro/r --title x --body y')" elsewhere
expect "a backslashed cd → elsewhere" "$(elsewhere '\cd /other && git commit -m x')" elsewhere
expect "git -c core.worktree= → elsewhere" "$(elsewhere 'git -c core.worktree=/x commit -m x')" elsewhere
expect "gh -R on a continued line → elsewhere" "$(elsewhere "$(printf 'gh pr create \\\n  -R o/r --title x')")" elsewhere
expect "cd in the quoted message → here" "$(elsewhere 'git commit -m "Support git -C paths and cd"')" here
expect "cd in a heredoc body → here" "$(elsewhere "$(printf 'git commit -m "$(cat <<%sEOF%s\nRun cd scripts, pass --repo.\nEOF\n)"' "'" "'")")" here
expect "cd inside bash -c quotes → elsewhere" "$(elsewhere "bash -c 'cd ../other && git commit -m x'")" elsewhere
expect "a quoted -C → elsewhere" "$(elsewhere 'git "-C" ../other commit -m x')" elsewhere
expect "a quoted core.worktree → elsewhere" "$(elsewhere 'git -c "core.worktree=../o" commit -m x')" elsewhere
expect "--repo in the --title text → here" "$(elsewhere 'gh pr create --title "Accept --repo" --body "cd"')" here
expect "<<EOF inside a message is not a heredoc" "$(elsewhere "$(printf 'git commit -m "Explain <<EOF usage"\ncd ../other')")" elsewhere
expect "a quoted --repo after a quoted --title value → elsewhere" "$(elsewhere 'gh pr create --title "T" "--repo" o/r --body "x"')" elsewhere
expect "a quoted -R after a --title= value → elsewhere" "$(elsewhere 'gh pr create --title="T" "-R" o/r --body "x"')" elsewhere
expect "a short-flag cluster that is not a message flag (bash -mc) → elsewhere" "$(elsewhere "bash -mc 'cd ../other && git commit -m x'")" elsewhere
expect "-am still drops its message → here" "$(elsewhere 'git commit -am "cd and --repo"')" here
expect "after the heredoc the command is read again" "$(elsewhere "$(printf 'git commit -F - <<EOF\nmsg\nEOF\ncd /x' )")" elsewhere

printf '\n%d passed, %d failed\n' "$pass" "$fail"
exit $((fail == 0 ? 0 : 1))
