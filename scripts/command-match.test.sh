#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Tests for command-match.sh. The table is the one measured on the two hooks
# before they shared a matcher: every row that used to be a false positive must
# answer `no`, every real invocation `real`, and everything the scanner cannot
# clear `maybe`. Fixtures are built in-process (printf), never typed as a
# literal into a shell command, so running this suite cannot trip a hook that
# reads the command it is run with.
#
#   bash scripts/command-match.test.sh

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=command-match.sh
source "$HERE/command-match.sh"

pass=0
fail=0
ok() { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }

# expect <verbs> <want> <label> <command>
expect() {
  local got
  got=$(command_match "$1" "$4")
  if [[ "$got" == "$2" ]]; then ok "$3"; else no "$3 — want $2, got $got"; fi
}

GC=git-commit
PC=gh-pr-create
PE=gh-pr-edit

echo "real — command position"
expect $GC real "plain commit"                 'git commit -m x'
expect $GC real "after &&"                     'git add . && git commit -m x'
expect $GC real "after ||"                     'false || git commit -m x'
expect $GC real "after ;"                      'cd a; git commit -m x'
expect $GC real "after a pipe"                 'echo x | git commit -F -'
expect $GC real "after cd … &&"                'cd /tmp/p && git add -A && git commit -m x'
expect $GC real "env prefix"                   'GIT_AUTHOR_NAME=x git commit -m y'
expect $GC real "wrapper: sudo"                'sudo git commit -m x'
expect $GC real "wrapper: env with vars"       'env A=1 git commit -m x'
expect $GC real "path-prefixed binary"         '/usr/bin/git commit -m x'
expect $GC real "git -C dir"                   'git -C ../other commit -m x'
expect $GC real "git -c k=v"                   'git -c user.name=x commit -m y'
expect $GC real "two spaces"                   'git  commit -m x'
expect $GC real "a tab"                        "$(printf 'git\tcommit -m x')"
expect $GC real "after a quoted argument"      'echo "done" && git commit -m "x"'
expect $GC real "the prescribed heredoc form"  "$(printf 'git commit -m "$(cat <<'"'"'EOF'"'"'\nsubject\n\nbody\nEOF\n)"')"
expect $GC real "in a subshell"                '(cd a && git commit -m x)'
expect $GC real "after a newline"              "$(printf 'echo hi\ngit commit -m x')"
expect $GC real "after a line continuation"    "$(printf 'git \\\n  commit -m x')"
expect $PC real "gh pr create"                 'gh pr create --title t --body b'
expect $PC real "gh -R repo pr create"         'gh -R o/r pr create --fill'
expect $PE real "gh pr edit"                   'gh pr edit 12 --title t'
expect $PC real "chained with git push"        'git push -u origin b && gh pr create --fill'

echo "no — only data"
expect $GC no "echo of the phrase"             'echo "run git commit later"'
expect $GC no "grep for the phrase"            'grep -rn "git commit" docs/'
expect $GC no "single-quoted phrase"           "printf '%s' 'git commit'"
expect $GC no "a comment"                      '# git commit later'
expect $GC no "an argument"                    'git log --grep="git commit"'
expect $GC no "commit-tree"                    'git commit-tree HEAD^{tree}'
expect $GC no "commit-graph"                   'git commit-graph write'
expect $GC no "other git verbs"                'git status && git diff'
expect $GC no "empty command"                  ''
expect $GC no "heredoc body that mentions it"  "$(printf 'cat > doc.md <<'"'"'EOF'"'"'\nrun git commit and gh pr create\nEOF')"
expect $GC no "indented heredoc (<<-)"         "$(printf 'cat <<-EOF\n\tgit commit\n\tEOF')"
expect $GC no "here-string"                    'cat <<< "git commit"'
expect $PC no "a PR title that says it"        'gh pr view 3 --json title # gh pr create'
expect $PC no "the WD-0017 shape"              "$(printf 'python3 - <<'"'"'PY'"'"'\nopen("n.md","w").write("gh pr create")\nPY')"
expect $PE no "verb not asked for"             'gh pr create --fill'

echo "real survives a mention in the same command"
expect $GC real "mention then real commit"     "$(printf 'echo "git commit"\ngit commit -m x')"
expect $GC real "heredoc then real commit"     "$(printf 'cat <<EOF > n\ngit commit\nEOF\ngit commit -m x')"

echo "maybe — the scanner cannot clear it"
expect $GC maybe "bash -c"                     'bash -c "git commit -m x"'
expect $GC maybe "sh -c"                       "sh -c 'git commit -m x'"
expect $GC maybe "eval"                        'eval "git commit -m x"'
expect $GC maybe "xargs"                       'echo a | xargs git commit -m'
expect $GC maybe "ssh"                         'ssh host "cd r && git commit -m x"'
expect $GC maybe "unterminated quote"          'echo "git commit'
expect $PC maybe "gh pr create in bash -c"     'bash -c "gh pr create --fill"'
expect $GC no    "bash -c without the phrase"  'bash -c "ls -la"'

echo "several verbs — strongest verdict wins"
expect "$GC,$PC" real  "real commit, no PR"    'git commit -m x'
expect "$GC,$PC" real  "real PR, no commit"    'gh pr create --fill'
expect "$GC,$PC,$PE" no "neither"              'echo git commit gh pr create gh pr edit'
expect "$GC,$PC" maybe "maybe beats no"        'bash -c "gh pr create"'

echo "CLI entry point"
got=$(bash "$HERE/command-match.sh" git-commit 'git commit -m x')
[[ "$got" == real ]] && ok "argument form" || no "argument form — got $got"
got=$(printf '%s' 'echo "git commit"' | bash "$HERE/command-match.sh" git-commit -)
[[ "$got" == no ]] && ok "stdin form (-)" || no "stdin form (-) — got $got"
got=$(printf '%s' 'git commit -m x' | bash "$HERE/command-match.sh" git-commit)
[[ "$got" == real ]] && ok "stdin form (no command)" || no "stdin form (no command) — got $got"
bash "$HERE/command-match.sh" >/dev/null 2>&1
[[ $? -eq 2 ]] && ok "no verbs → usage, exit 2" || no "no verbs → usage, exit 2"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
