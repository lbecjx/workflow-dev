# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# What the test scripts of .github/scripts share, defined once. Source it right
# after `set -u`:   HERE="$(cd "$(dirname "$0")" && pwd)";  . "$HERE/test-lib.sh"
# It gives each test a scratch folder $TMP (removed on exit), the ok/no/check/not
# helpers with their counters, and `finish` for the last line. Bash 3.2 compatible.

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok() { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }
check() { # $1 label, then a test command
  local label="$1"
  shift
  if "$@"; then ok "$label"; else no "$label"; fi
}
not() { ! "$@"; }
finish() {
  printf '\n%d passed, %d failed\n' "$pass" "$fail"
  [ "$fail" -eq 0 ]
}

# The repos the tests make commit as nobody and read no git configuration.
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

# mkremote <name>: a bare origin and a clone of it with one commit pushed to main.
# Prints the clone's path.
mkremote() {
  local o="$TMP/$1.git" w="$TMP/$1"
  git init -q --bare "$o"
  git clone -q "$o" "$w" 2>/dev/null
  git -C "$w" checkout -q -b main
  echo x > "$w/f"
  git -C "$w" add f
  git -C "$w" commit -q -m init
  git -C "$w" push -q origin main 2>/dev/null
  echo "$w"
}

# install_gh_stub: a stand-in for gh, first on the PATH. It logs its arguments in
# $GH_LOG and answers from the STUB_* variables:
#   pr list        STUB_FAIL=1 fails; STUB_PRS_JSON is run through the --jq it is given
#   label create   STUB_LABEL_FAIL=1 fails
#   pr create      STUB_DENY=1 answers the "not permitted to create or approve pull
#                  requests" error; STUB_FAIL=1 fails with another error; the
#                  description (--body-file) is kept in $TMP/pr-body.md
#   pr edit        STUB_EDIT_FAIL=1 fails
#   pr view        succeeds only with STUB_PR_EXISTS=1
#   release view   succeeds only with STUB_RELEASED=1
#   release create STUB_CREATE_FAIL=1 fails; the notes it was given are kept in
#                  $TMP/notes-seen.txt
#   api graphql    the request body (--input) is kept in $TMP/graphql-body.json;
#                  STUB_API_FAIL=1 fails, else it prints STUB_API_GRAPHQL
install_gh_stub() {
  mkdir -p "$TMP/bin"
  GH_LOG="$TMP/gh.log"
  export GH_LOG TMP
  cat > "$TMP/bin/gh" <<'STUBEOF'
#!/bin/bash
echo "$*" >> "$GH_LOG"
case "$1 $2" in
  "pr list")
    [ "${STUB_FAIL:-0}" = 1 ] && exit 1
    expr=""
    while [ $# -gt 0 ]; do
      [ "$1" = "--jq" ] && expr="$2"
      shift
    done
    [ -n "${STUB_PRS_JSON:-}" ] && printf '%s' "$STUB_PRS_JSON" | jq -r "$expr"
    exit 0 ;;
  "label create")
    [ "${STUB_LABEL_FAIL:-0}" = 1 ] && exit 1
    exit 0 ;;
  "pr edit")
    [ "${STUB_EDIT_FAIL:-0}" = 1 ] && exit 1
    exit 0 ;;
  "pr view") [ "${STUB_PR_EXISTS:-0}" = 1 ]; exit $? ;;
  "pr create")
    for a in "$@"; do
      [ "${prev:-}" = "--body-file" ] && cp "$a" "$TMP/pr-body.md"
      prev="$a"
    done
    if [ "${STUB_DENY:-0}" = 1 ]; then
      echo "pull request create failed: GraphQL: GitHub Actions is not permitted to create or approve pull requests (createPullRequest)" >&2
      exit 1
    fi
    if [ "${STUB_FAIL:-0}" = 1 ]; then echo "boom: something else" >&2; exit 1; fi
    echo "https://github.com/lbecjx/workflow-dev/pull/99"
    exit 0 ;;
  "release view") [ "${STUB_RELEASED:-0}" = 1 ]; exit $? ;;
  "release create")
    [ "${STUB_CREATE_FAIL:-0}" = 1 ] && { echo "boom" >&2; exit 1; }
    while [ $# -gt 0 ]; do
      [ "$1" = "--notes-file" ] && cp "$2" "$TMP/notes-seen.txt"
      shift
    done
    exit 0 ;;
  "api graphql")
    while [ $# -gt 0 ]; do
      [ "$1" = "--input" ] && cp "$2" "$TMP/graphql-body.json"
      shift
    done
    [ "${STUB_API_FAIL:-0}" = 1 ] && { echo "GraphQL: boom" >&2; exit 1; }
    printf '%s' "${STUB_API_GRAPHQL:-}"
    exit 0 ;;
esac
exit 0
STUBEOF
  chmod +x "$TMP/bin/gh"
  export PATH="$TMP/bin:$PATH"
}
