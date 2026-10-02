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
expect $GC maybe "ssh"                         'ssh host "cd r && git commit -m x"'
expect $GC maybe "unterminated quote"          'echo "git commit'
expect $PC maybe "gh pr create in bash -c"     'bash -c "gh pr create --fill"'
expect $GC no    "bash -c without the phrase"  'bash -c "ls -la"'

echo "real — wrappers and options a substring match never saw past"
expect $GC real "time -p"                      'time -p git commit -m x'
expect $GC real "command -p"                   'command -p git commit -m x'
expect $GC real "exec -a name"                 'exec -a n git commit -m x'
expect $GC real "sudo -iu user"                'sudo -iu bob git commit -m x'
expect $GC real "doas"                         'doas git commit -m x'
expect $GC real "arch -arm64"                  'arch -arm64 git commit -m x'
expect $GC real "caffeinate -i"                'caffeinate -i git commit -m x'
expect $GC real "caffeinate -t N"              'caffeinate -t 5 git commit -m x'
expect $GC real "stdbuf -oL"                   'stdbuf -oL git commit -m x'
expect $GC real "flock lockfile"               'flock /tmp/l git commit -m x'
expect $GC real "timeout DURATION"             'timeout 60 git commit -m x'
expect $GC real "timeout -s KILL DURATION"     'timeout -s KILL 60 git commit -m x'
expect $GC real "xargs"                        'echo a | xargs git commit -m x'
expect $GC real "xargs -n 1"                   'echo a | xargs -n 1 git commit -m x'
expect $GC real "wrappers stacked"             'sudo -u bob env A=1 nice -n 5 git commit -m x'
expect $GC real "leading &> redirect"          '&>log git commit -m x'
expect $GC real "leading 2>&1 redirect"        '2>&1 git commit -m x'
expect $GC real "redirect between words"       'git commit >log 2>&1 -m x'
expect $PC real "gh pr new is create"          'gh pr new --fill'
expect $PC real "gh pr --repo X create"        'gh pr --repo o/r create --fill'
expect $PE real "gh -R X pr edit"              'gh -R o/r pr edit 3 --title t'

echo "real — a heredoc or arithmetic must not swallow what follows"
expect $GC real "heredoc glued to a redirect"  "$(printf 'cat <<EOF>n.md\nhi\nEOF\ngit commit -m x')"
expect $GC real "quoted delimiter + redirect"  "$(printf 'cat <<'"'"'EOF'"'"'>n.md\nhi\nEOF\ngit commit -m x')"
expect $GC real "heredoc then redirect word"   "$(printf 'cat <<EOF >n.md\nhi\nEOF\ngit commit -m x')"
expect $GC real "arithmetic << on its own line" "$(printf 'n=$((1<<2))\ngit commit -m x')"
expect $GC real "(( x <<= 1 )) line"           "$(printf '(( x <<= 1 ))\ngit commit -m x')"
expect $GC real "arithmetic inside quotes"     "$(printf 'echo "$((1<<2))"\ngit commit -m x')"
expect $GC real "a subshell is not arithmetic" '$((cd a); git commit -m x)'

echo "maybe — what is handed to something else to run"
expect $GC maybe "script fed to bash by heredoc"   "$(printf "bash <<'EOF'\ngit commit -m x\nEOF")"
expect $GC maybe "script fed to sh -s by heredoc"  "$(printf 'sh -s <<EOF\ngit commit -m x\nEOF')"
expect $GC maybe "script fed to ssh by heredoc"    "$(printf "ssh host <<'EOF'\ngit commit -m x\nEOF")"
expect $GC maybe "piped into bash"                 'echo "git commit -m x" | bash'
expect $GC maybe "bash -c with a substitution"     "$(printf 'bash -c "$(cat <<'"'"'EOF'"'"'\ngit commit -m x\nEOF\n)"')"
expect $GC maybe "git submodule foreach"           'git submodule foreach git commit -am x'
expect $GC maybe "git submodule foreach, quoted"   "git submodule foreach 'git commit -am x'"
expect $GC maybe "trap handler"                    "trap 'git commit -m x' EXIT"
expect $GC maybe "find -execdir"                   'find . -execdir git commit -m x \;'
expect $GC maybe "an unknown program given git"    'mytool git commit -m x'
expect $GC maybe "program word from a variable"    '"$GIT" commit -m x'
expect $GC maybe "program word from a substitution" '$(which git) commit -m x'
expect $PC maybe "an unknown program given gh"     'mytool gh pr create --fill'
expect $GC no    "a script fed to bash with no commit" "$(printf 'bash <<EOF\nls\nEOF')"
expect $GC no    "an unknown program, quoted mention"  'mytool "git commit"'
expect $GC no    "echo with bare words"                'echo git commit'
expect $GC no    "a heredoc to cat mentioning it"      "$(printf 'cat <<EOF\ngit commit\nEOF')"

echo "size — a command too long to scan is not silently cleared"
LONG="$(printf 'echo %s; git commit -m x' "$(head -c 120000 /dev/zero | tr '\0' a)")"
expect $GC maybe "over the scan cap"               "$LONG"
expect $GC no    "long but no verb in it"          "$(head -c 120000 /dev/zero | tr '\0' a)"
expect $GC no    "no verb word → no awk needed"    'ls -la && echo hi'

echo "command_from_payload — one extractor"
payload() { printf '{"tool_input":{"command":%s}}' "$(printf '%s' "$1" | jq -Rs .)"; }
if command -v jq >/dev/null 2>&1; then
  C=$(printf 'echo "a" && git commit -m "x"\nls\there')
  [[ "$(command_from_payload "$(payload "$C")")" == "$C" ]] && ok "jq path: round-trips quotes, newline, tab" || no "jq path round-trip"
  NOJQ="$(mktemp -d)"
  for t in bash cat grep sed awk head tr printf; do p="$(command -v $t)" && ln -sf "$p" "$NOJQ/$t"; done
  got=$(PATH="$NOJQ" bash -c 'source "$1"; command_from_payload "$2"' _ "$HERE/command-match.sh" "$(payload "$C")")
  [[ "$got" == "$C" ]] && ok "no-jq fallback: round-trips quotes, newline, tab" || no "no-jq fallback round-trip — got: $got"
  # An escaped backslash before n is a backslash and an n, not a newline: the
  # mention below must read back byte for byte, or it would be read as a commit.
  M='echo foo\\ngit commit'
  got=$(PATH="$NOJQ" bash -c 'source "$1"; command_from_payload "$2"' _ "$HERE/command-match.sh" "$(payload "$M")")
  [[ "$got" == "$M" ]] && ok "no-jq fallback: an escaped backslash before n stays literal" || no "no-jq fallback: escaped backslash before n — got: $got"
  rm -rf "$NOJQ"
fi

echo "regressions the scanner rewrite had to avoid"
expect $GC real "nested subshells, not arithmetic"      '((cd a); (git commit -m x))'
expect $GC real "nested subshells in a substitution"    'x=$((cd a) && (git commit -m x))'
expect $GC real "arithmetic with an inner group"        "$(printf 'n=$((1+(2)))\ngit commit -m x')"
expect $GC no   "a word ending in S is not a substitution" "$(printf "python3 - <<'PY'\nprint('git commit')\nPY\nbash build.sh --os MACOS")"
expect $GC no   "a quoted mention beside ssh ... DOCS"  "$(printf "echo 'git commit -m x' > notes.md\nssh host ls DOCS")"
expect $GC no   "cat > tools/sh <<EOF (sh is a path, not the program)" "$(printf 'cat > tools/sh <<EOF\ngit commit -m x\nEOF')"
expect $GC no   "a flag value that says sh"             "$(printf 'python3 gen.py --shell sh <<EOF\ngit commit -m x\nEOF')"
expect $GC no   "for w in git commit"                   'for w in git commit; do echo $w; done'
expect $GC no   "legit commit piped to bash -c"         "echo 'this is legit commit' | bash -c 'cat'"
expect $GC no   "git log piped to sh -c"                "git log --grep commit | sh -c 'wc -l'"
expect $GC maybe "sudo -u bob bash <<EOF"               "$(printf 'sudo -u bob bash <<EOF\ngit commit -m x\nEOF')"
expect $GC maybe "a here-string fed to bash"            "bash <<<'git commit -m x'"
expect $GC maybe "a here-string fed to bash, spaced"    "bash <<< 'git commit -m x'"
expect $GC maybe "echo through tee into bash"           "echo 'git commit -m x' | tee log | bash"
expect $GC maybe "a heredoc to cat piped to sh"         "$(printf 'cat <<E | sh\ngit commit -m x\nE')"
expect $GC no    "a here-string to cat"                 'cat <<< "git commit -m x"'

echo "bash syntax a substring match could not tell from a command"
expect $GC no   "\$'...' with an escaped quote hides a mention"   "$(printf "echo \$'a\\\\'; git commit -m x '")"
expect $GC real "a command after a \$'...' string"                  "$(printf "echo \$'it\\\\'s' && git commit -m x")"
expect $GC no   "a ; inside \${...} is not a separator"             'echo ${v:-a; git commit -m x}'
expect $GC no   "an array literal holding the words"                'words=(git commit -m x)'
expect $GC no   "an array append"                                   'arr+=(git commit)'
expect $GC no   "a regex with a group in [[ =~ ]]"                  '[[ $x =~ (a|git commit) ]]'
expect $GC real "a command after [[ ... ]]"                         '[[ -f f ]] && git commit -m x'
expect $GC real "old-style \$[1<<2] arithmetic"                     "$(printf 'n=$[1<<2]\ngit commit -m x')"

echo "maybe — more ways to hand a command to something else"
expect $GC maybe "docker exec ... sh <<E"           "$(printf 'docker exec c sh <<E\ngit commit -m x\nE')"
expect $GC maybe "docker exec ... sh -c"            'docker exec c sh -c "git commit -m x"'
expect $GC no    "docker logs with a quoted mention" 'docker logs c "git commit"'
expect $GC maybe "git rebase -x"                    "git rebase -x 'git commit --amend' main"
expect $GC maybe "git rebase --exec=..."            'git rebase -i --exec="git commit --amend" main'
expect $GC no    "git rebase without exec"          'git rebase -i main'
expect $GC maybe "env -S"                           "env -S 'git commit -m x'"
expect $GC real  "env -i A=1"                       'env -i A=1 git commit -m x'
expect $GC maybe "flock lockfile -c"                "flock /tmp/l -c 'git commit -m x'"
expect $GC maybe "flock -x lockfile -c"             "flock -x /tmp/l -c 'git commit -m x'"
expect $GC maybe 'set -- ...; "$@"'                 'set -- git commit -m x; "$@"'
expect $GC maybe "eval of a variable holding it"    "cmd='git commit -m x'; eval \"\$cmd\""
expect $GC no    "eval of a harmless variable"      "cmd='ls'; eval \"\$cmd\""

echo "a shell that runs a script FILE reads its stdin and arguments as data"
expect $GC no   "bash script.sh <<EOF"                "$(printf "bash scripts/check.sh <<'EOF'\n{\"command\":\"git commit -m x\"}\nEOF")"
expect $GC no   "printf | bash script.sh"             "printf '%s\\n' '{\"command\":\"git commit -m x\"}' | bash scripts/check.sh"
expect $GC no   "bash script.sh <<<'...'"             "bash scripts/check.sh <<<'{\"command\":\"git commit -m x\"}'"
expect $PC no   "echo | sh hook.sh"                   "echo '{\"command\":\"gh pr create\"}' | sh scripts/hook.sh"
expect $GC no   "bash script.sh \"\$(heredoc)\""      "$(printf "bash scripts/check.sh \"\$(cat <<'EOF'\nmention git commit -m x here\nEOF\n)\"")"
expect $GC no   "bash script.sh \"git commit\""        'bash scripts/check.sh "git commit -m x"'
expect $GC maybe "bash -s <<EOF"                      "$(printf "bash -s <<'EOF'\ngit commit -m x\nEOF")"

echo "maybe/real — more wrappers, keywords and substitutions"
expect $GC maybe "timeout N bash <<EOF"               "$(printf "timeout 10 bash <<'EOF'\ngit commit -m x\nEOF")"
expect $GC maybe "xargs bash <<EOF"                   "$(printf "xargs bash <<'EOF'\ngit commit -m x\nEOF")"
expect $GC maybe "arch -arm64 bash <<EOF"             "$(printf "arch -arm64 bash <<'EOF'\ngit commit -m x\nEOF")"
expect $GC maybe "flock lockfile bash <<EOF"          "$(printf "flock /tmp/l bash <<'EOF'\ngit commit -m x\nEOF")"
expect $GC maybe "fish <<EOF"                         "$(printf "fish <<'EOF'\ngit commit -m x\nEOF")"
expect $GC real  "function f { git commit; }"        'function f { git commit -m x; }; f'
expect $GC real  "f() { git commit; }"               'f() { git commit -m x; }; f'
expect $GC maybe "a here-string piped into bash"      "cat <<<'git commit -m x' | bash"
expect $GC maybe "bash -c \"\$(printf ...)\""         "bash -c \"\$(printf 'git commit -m x')\""
expect $GC maybe "sh -c \"\$(echo ...)\""             'sh -c "$(echo git commit -m x)"'
expect $GC maybe "echo \"\$(heredoc)\" | bash"        "$(printf "echo \"\$(cat <<'EOF'\ngit commit -m x\nEOF\n)\" | bash")"

echo "one scan answers both questions"
[[ "$(command_match_scan git-commit,gh-pr-create,gh-pr-edit 'gh pr create --fill')" == "real real" ]] && ok "a PR → real real" || no "a PR → real real"
[[ "$(command_match_scan git-commit,gh-pr-create,gh-pr-edit 'git commit -m x')" == "real no" ]] && ok "a commit → real no" || no "a commit → real no"
[[ "$(command_match_scan git-commit,gh-pr-create,gh-pr-edit 'ls -la')" == "no no" ]] && ok "an ordinary command → no no" || no "an ordinary command → no no"
[[ "$(command_match_scan git-commit,gh-pr-create,gh-pr-edit 'bash -c "gh pr edit 3"')" == "maybe maybe" ]] && ok "wrapped PR → maybe maybe" || no "wrapped PR → maybe maybe"

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
