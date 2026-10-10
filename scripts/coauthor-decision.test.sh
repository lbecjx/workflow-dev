#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Tests for coauthor-decision.sh: when the repository's decision in
# .workflow-dev/config.json means yes (only one shape does), what a yes lets
# through, and which commands it may apply to. Every case that is not an
# explicit, readable yes must read as no — that is what keeps the attribution
# deny exactly as it was. Runs in a throwaway project, never against this
# repo's live context.
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
mkdir -p "$PROJ/.workflow-dev/context"
CFG="$PROJ/.workflow-dev/config.json"
cfg() { printf '%s' "$1" > "$CFG"; }
decision() { ( cd "$PROJ" && bash -c 'source "$1"; coauthor_decision' _ "$HERE/coauthor-decision.sh" ); }

if ! command -v jq >/dev/null 2>&1; then
  echo "  skip  jq isn't installed — the decision needs it (and reads as no without it)"
  exit 0
fi

# --- 1: the repository's decision --------------------------------------------
cfg '{ "gitignored": true, "agentCoauthorship": "yes" }'
expect "agentCoauthorship \"yes\" → yes" "$(decision)" yes
cfg '{"agentCoauthorship":"yes"}'
expect "compact JSON → yes" "$(decision)" yes
cfg '{ "gitignored": true, "agentCoauthorship": "no" }'
expect "agentCoauthorship \"no\" → no" "$(decision)" no
cfg '{ "gitignored": true }'
expect "no key → no" "$(decision)" no
rm -f "$CFG"
expect "no config.json → no" "$(decision)" no
cfg '{ "agentCoauthorship": "YES" }'
expect "\"YES\" is not the recorded value → no" "$(decision)" no
cfg '{ "agentCoauthorship": "sí" }'
expect "\"sí\" → no" "$(decision)" no
cfg '{ "agentCoauthorship": true }'
expect "a boolean true → no" "$(decision)" no
cfg '{ "agentCoauthorship": "yes", "agentCoauthorship": "no" }'
expect "the key twice → no" "$(decision)" no
cfg '{ "agentCoauthorship": "no", "agentCoauthorship": "yes" }'
expect "the key twice, yes last → no" "$(decision)" no
cfg '{ "agentCoauthorship": "yes" '
expect "malformed JSON → no" "$(decision)" no
cfg '{ "note": "agentCoauthorship", "agentCoauthorship": "yes" }'
expect "the key name also in a value → no (ambiguous)" "$(decision)" no
cfg '{ "x": { "agentCoauthorship": "yes" } }'
expect "the key nested, not top-level → no" "$(decision)" no
cfg '{"agentCoauthorship":"yes"}{}'
expect "two JSON documents → no" "$(decision)" no
cfg '["x"]
{"agentCoauthorship":"yes"}'
expect "an erroring document before the yes → no" "$(decision)" no
cfg '{"agentCoauthorship":"no","agentCoauthorship":"yes"}'
expect "an escaped duplicate key → no" "$(decision)" no
cfg '{"agentCoauthorship":"yes\n"}'
expect "\"yes\\n\" → no" "$(decision)" no
cfg '{"agentCoauthorship":"yes\u0000"}'
expect "\"yes\\u0000\" → no" "$(decision)" no
printf '{"agentCoauthorship":"y\000es"}' > "$CFG"
expect "a raw NUL byte in the file → no" "$(decision)" no
cfg '{ "agentCoauthorship": "yes" }'
mkdir -p "$PROJ/sub"
expect "run from a subdirectory → no (the config is read from the working directory)" "$( ( cd "$PROJ/sub" && bash -c 'source "$1"; coauthor_decision' _ "$HERE/coauthor-decision.sh" ) )" no
if [[ $(id -u) -ne 0 ]]; then
  chmod 000 "$CFG"
  expect "an unreadable config.json → no" "$(decision)" no
  chmod 644 "$CFG"
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
expect "yes: the trailer as a second -m on one line is attribution (safe side: heredoc is the form)" "$(attr "$(printf 'git commit -m "Add a thing" -m "%s"' "$TRAILER")" yes)" attribution
expect "yes: 'Generated by -m <trailer>' prose is attribution" "$(attr "$(printf 'Generated by -m "%s"' "$TRAILER")" yes)" attribution
expect "yes: a credit phrase in the first -m beside a trailer -m is attribution" "$(attr "$(printf 'git commit -m "AI-generated change" -m "%s"' "$TRAILER")" yes)" attribution
expect "no: the trailer as a second -m is attribution" "$(attr "$(printf 'git commit -m "Add a thing" -m "%s"' "$TRAILER")" no)" attribution
expect "yes: a trailer name of more than four words is attribution" "$(attr "$(printf 'x\n\nCo-Authored-By: Claude did this whole feature alone <noreply@anthropic.com>')" yes)" attribution
expect "yes: two trailers is attribution" "$(attr "$(printf 'x\n\n%s\n%s' "$TRAILER" "$TRAILER")" yes)" attribution
expect "yes: the PR line as the title (first line) is attribution" "$(attr "$(printf '%s\n\nbody' "$PRLINE")" yes)" attribution
expect "yes: the trailer as the subject is attribution" "$(attr "$TRAILER" yes)" attribution
expect "yes: written by Claude in the body is attribution" "$(attr "$(printf 'Written by Claude.\n\n%s' "$TRAILER")" yes)" attribution
expect "yes: a credit phrase inside the trailer name is attribution" "$(attr "$(printf 'x\n\nCo-Authored-By: AI-generated written by an AI <a@b.c>')" yes)" attribution
expect "yes: a credit phrase inside the PR link text is attribution" "$(attr "$(printf 'x\n\n🤖 Generated with [AI-generated code](https://claude.ai)')" yes)" attribution
expect "yes: a quote inside the trailer name is attribution" "$(attr "$(printf 'x\n\nCo-Authored-By: A" -m "Generated by claude <a@b.c>')" yes)" attribution

# --- 5: which commands the yes may apply to ---------------------------------
# An allowlist: only a plain git commit / gh pr create|edit in this directory.
plain() { lib coauthor_command_plain "$1" && printf plain || printf other; }
HD="$(printf 'git commit -m "$(cat <<%sEOF%s\nSubject\n\nRun cd scripts, pass --repo, use -C.\nEOF\n)"' "'" "'")"
PRHD="$(printf 'gh pr create --title "Add a thing" --body "$(cat <<%sEOF%s\nSummary.\nEOF\n)"' "'" "'")"
expect "heredoc commit (the summarize-changes form) → plain" "$(plain "$HD")" plain
expect "heredoc PR → plain" "$(plain "$PRHD")" plain
expect "git commit -m with quotes → plain" "$(plain 'git commit -m "Support git -C paths and cd"')" plain
expect "git commit -am → plain" "$(plain 'git commit -am "x"')" plain
expect "git commit --message=\"x\" → plain" "$(plain 'git commit --message="x"')" plain
expect "a heredoc on stdin → other (bash expands an unquoted body)" "$(plain "$(printf 'git commit -F - <<EOF\nmsg\nEOF')")" other
expect "the canonical form with an unquoted delimiter → other" "$(plain "$(printf 'git commit -m "$(cat <<EOF\nmsg\nEOF\n)"')")" other
expect "an opener inside the -m text, \$( on the next line → other" "$(plain "$(printf 'git commit -m "x <<EOF\n$(cd /o && git commit -m y)\nEOF\n"')")" other
expect "a command after the heredoc inside \$( → other" "$(plain "$(printf 'git commit -m "$(cat <<%sEOF%s\nSubject\nEOF\ngit -C /o commit -m x\n)"' "'" "'")")" other
expect "text after ) before the closing quote → other" "$(plain "$(printf 'git commit -m "$(cat <<%sEOF%s\nSubject\nEOF\n) && cd /o"' "'" "'")")" other
expect "an opener inside a single-quoted -m → other" "$(plain "$(printf "git commit -m 'Subject <<EOF\n'; cd o && git commit -m x\nEOF\n'")")" other
expect "gh -dR (cluster) → other" "$(plain 'gh pr create -dR o/r --title "T" --body "x"')" other
expect "an unbalanced ) in the heredoc body → other (bash 3.2 closes the \$( there)" "$(plain "$(printf 'git commit -m "$(cat <<%sEOF%s\nSubject\n)"\ngit -C ../o commit -m x\necho "\nEOF\n)"' "'" "'")")" other
expect "balanced parentheses in the body → plain" "$(plain "$(printf 'git commit -m "$(cat <<%sEOF%s\nAdd a thing (WD-0053)\nEOF\n)"' "'" "'")")" plain
expect "parentheses beside an apostrophe in the body → other" "$(plain "$(printf 'git commit -m "$(cat <<%sEOF%s\nDon%st break (x)\nEOF\n)"' "'" "'" "'")")" other
expect "an apostrophe without parentheses → plain" "$(plain "$(printf 'git commit -m "$(cat <<%sEOF%s\nDon%st break it\nEOF\n)"' "'" "'" "'")")" plain
expect "a backslash beside parentheses in the body → other" "$(plain "$(printf 'git commit -m "$(cat <<%sEOF%s\nSubject (WD-1) \\(\n)$\\\n(git -C ../o commit -m x)\nEOF\n)"' "'" "'")")" other
expect "a # beside parentheses in the body → other" "$(plain "$(printf 'git commit -m "$(cat <<%sEOF%s\nSubject # (\n)\nEOF\n)"' "'" "'")")" other
expect "a # without parentheses → plain (issue refs)" "$(plain "$(printf 'git commit -m "$(cat <<%sEOF%s\nFix #12\nEOF\n)"' "'" "'")")" plain
expect "a CR line after the heredoc → other" "$(plain "$(printf 'git commit -m "$(cat <<%sEOF%s\nSubject\nEOF\n\r)"' "'" "'")")" other
expect "a trailing vertical-tab line → other" "$(plain "$(printf 'git commit -m "S"\n\v')")" other
expect "a CR inside the command word → other" "$(plain "$(printf 'git\rcommit -m "S"')")" other
expect "a tab between words → plain" "$(plain "$(printf 'git\tcommit -m "S"')")" plain
expect "a \$( in the body → other" "$(plain "$(printf 'git commit -m "$(cat <<%sEOF%s\nRun $(x)\nEOF\n)"' "'" "'")")" other
expect "a <<- opener with a tab-indented delimiter → plain" "$(plain "$(printf 'git commit -m "$(cat <<-%sEOF%s\nmsg\n\tEOF\n)"' "'" "'")")" plain
expect "a tab-indented delimiter without <<- does not end the heredoc → other" "$(plain "$(printf 'git commit -m "$(cat <<%sEOF%s\nmsg\n\tEOF\n)"' "'" "'")")" other
expect "gh pr edit 12 --body → plain" "$(plain 'gh pr edit 12 --body "x"')" plain
expect "gh pr create --title \"T\" --base main → plain" "$(plain 'gh pr create --title "T" --base main --body "x"')" plain
expect "cd before the commit → other" "$(plain 'cd /other && git commit -m x')" other
expect "a backslashed cd → other" "$(plain '\cd /other && git commit -m x')" other
expect "chdir → other" "$(plain 'chdir ../o && git commit -m x')" other
expect "env --chdir → other" "$(plain 'env --chdir=../o git commit -m x')" other
expect "git -C dir commit → other" "$(plain 'git -C /other commit -m "x"')" other
expect "git --git-dir → other" "$(plain 'git --git-dir=/o/.git commit -m x')" other
expect "git -c core.worktree → other" "$(plain 'git -c core.worktree=/x commit -m x')" other
expect "GIT_DIR= → other" "$(plain 'GIT_DIR=/o/.git git commit -m x')" other
expect "GIT_CONFIG_PARAMETERS → other" "$(plain "GIT_CONFIG_PARAMETERS=\"'core.worktree=/x'\" git commit -m x")" other
expect "GH_REPO= → other" "$(plain 'GH_REPO=o/r gh pr create --title x --body y')" other
expect "gh -R → other" "$(plain 'gh pr create -R o/r --title x --body y')" other
expect "gh -R glued → other" "$(plain 'gh pr create -Ro/r --title x --body y')" other
expect "gh --repo= → other" "$(plain 'gh pr create --repo=o/r --title x')" other
expect "a quoted --repo → other" "$(plain 'gh pr create --title "T" "--repo" o/r --body "x"')" other
expect "gh pr edit with a PR URL → other" "$(plain 'gh pr edit https://github.com/o/r/pull/1 --body "x"')" other
expect "bash -c → other" "$(plain "bash -c 'git commit -m x'")" other
expect "bash -cm → other" "$(plain "bash -cm 'cd ../o && git commit -m x'")" other
expect "eval → other" "$(plain "eval 'cd ../o'; git commit -m x")" other
expect "a second command on the next line → other" "$(plain "$(printf 'echo -m\n"cd" ../o && git commit -m x')")" other
expect "a command substitution inside -m → other" "$(plain 'git commit -m "$(cd ../o && git commit -m x)"')" other
expect "a quoted value of a non-message flag → other" "$(plain 'git commit "--git-dir=../o" -m x')" other
expect "text glued after a closing quote → other" "$(plain 'git commit -m "x""-C" ../o')" other
expect "<<EOF inside a message is not a heredoc" "$(plain "$(printf 'git commit -m "Explain <<EOF usage"\ncd ../o')")" other
expect "after a heredoc, a second command → other" "$(plain "$(printf 'git commit -F - <<EOF\nmsg\nEOF\ncd /x')")" other
expect "an unterminated quote → other" "$(plain 'git commit -m "x')" other
expect "git status → other" "$(plain 'git status')" other

printf '\n%d passed, %d failed\n' "$pass" "$fail"
exit $((fail == 0 ? 0 : 1))
