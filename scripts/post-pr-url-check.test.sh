#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Tests for post-pr-url-check.sh (WD-0024): a real gh pr create/edit yields
# the PR's URL, a mere mention or a failed command stays quiet, and gh pr
# edit falls back to `gh pr view` when its own stdout carries no URL.
#
#   bash scripts/post-pr-url-check.test.sh

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/post-pr-url-check.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok() { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }

if ! command -v jq >/dev/null 2>&1; then
  echo "  skip  jq isn't installed — payload construction for this suite needs it"
  exit 0
fi

mk_hook() { jq -n --arg cmd "$1" --arg out "${2:-}" --argjson ec "${3:-0}" '{tool_input:{command:$cmd},tool_response:{stdout:$out,exit_code:$ec}}'; }
mk_msg()  { jq -n --arg cmd "$1" --arg out "${2:-}" '{tool_input:{command:$cmd},tool_output:$out}'; }
hook()    { printf '%s' "$1" | bash "$SCRIPT"; }
plain()   { bash "$SCRIPT" --message "$1"; }

STUBDIR="$TMP/stub"
mkdir -p "$STUBDIR"
cat > "$STUBDIR/gh" <<'EOF'
#!/bin/bash
echo "https://github.com/lbecjx/workflow-dev/pull/44"
EOF
chmod +x "$STUBDIR/gh"

CREATE_OUT="Creating pull request for feature into main...
https://github.com/lbecjx/workflow-dev/pull/44"

# --- 1: a real create → the URL, in both modes ------------------------------
CREATE_HOOK="$(mk_hook 'gh pr create --title x --body y' "$CREATE_OUT")"
H="$(hook "$CREATE_HOOK")"
case "$H" in
  *"https://github.com/lbecjx/workflow-dev/pull/44"*) ok "real create → hook mode carries the URL" ;;
  *) no "real create → hook mode carries the URL (got: $H)" ;;
esac
case "$H" in
  *'"hookEventName":"PostToolUse"'*) ok "real create → hook mode is a PostToolUse envelope" ;;
  *) no "real create → hook mode is a PostToolUse envelope (got: $H)" ;;
esac

CREATE_MSG="$(mk_msg 'gh pr create --title x --body y' "$CREATE_OUT")"
P="$(plain "$CREATE_MSG")"
case "$P" in
  *"https://github.com/lbecjx/workflow-dev/pull/44"*) ok "real create → --message carries the URL" ;;
  *) no "real create → --message carries the URL (got: $P)" ;;
esac

# --- 2: a real edit with the URL already in stdout --------------------------
EDIT_WITH_URL="$(mk_hook 'gh pr edit 44 --title newtitle' 'https://github.com/lbecjx/workflow-dev/pull/44')"
H="$(hook "$EDIT_WITH_URL")"
case "$H" in
  *"pull/44"*) ok "real edit, URL in stdout → carries it" ;;
  *) no "real edit, URL in stdout → carries it (got: $H)" ;;
esac

# --- 3: a real edit with no URL in stdout → gh pr view fallback -------------
EDIT_NO_URL="$(mk_hook 'gh pr edit 44 --title newtitle' '')"
H=$(PATH="$STUBDIR:$PATH" hook "$EDIT_NO_URL")
case "$H" in
  *"pull/44"*) ok "real edit, no URL in stdout → gh pr view fallback fires" ;;
  *) no "real edit, no URL in stdout → gh pr view fallback fires (got: $H)" ;;
esac

# --- 4: same case with no gh binary on PATH → quiet, never guesses ---------
# PATH keeps bash/grep/sed/jq (needed to run the hook itself) but drops every
# directory that could contain a real `gh`.
NO_GH_PATH=$(printf '%s' "$PATH" | tr ':' '\n' | while read -r d; do [[ -x "$d/gh" ]] || printf '%s:' "$d"; done)
H=$(PATH="$NO_GH_PATH" hook "$EDIT_NO_URL")
[[ -z "$H" ]] && ok "real edit, no URL, no gh binary → quiet" || no "real edit, no URL, no gh binary → quiet (got: $H)"

# --- 5: a mere mention stays quiet ------------------------------------------
MENTION="$(mk_hook 'echo "will run gh pr create later"' 'will run gh pr create later')"
H="$(hook "$MENTION")"
[[ -z "$H" ]] && ok "mention-only command → quiet" || no "mention-only command → quiet (got: $H)"

MENTION_MSG="$(mk_msg 'echo "will run gh pr create later"' 'will run gh pr create later')"
P="$(plain "$MENTION_MSG")"
[[ -z "$P" ]] && ok "mention-only command → --message quiet" || no "mention-only command → --message quiet (got: $P)"

# --- 6: a plain git commit (not a PR verb) stays quiet -----------------------
COMMIT="$(mk_hook 'git commit -m "x"' '[main abc1234] x')"
H="$(hook "$COMMIT")"
[[ -z "$H" ]] && ok "git commit (no PR verb) → quiet" || no "git commit (no PR verb) → quiet (got: $H)"

# --- 7: a failed command (non-zero exit) stays quiet even with a URL in stdout
FAILED="$(mk_hook 'gh pr create --title x --body y' "$CREATE_OUT" 1)"
H="$(hook "$FAILED")"
[[ -z "$H" ]] && ok "failed command (exit_code 1) → quiet" || no "failed command (exit_code 1) → quiet (got: $H)"

# --- 8: a wrapped (maybe-verdict) command still fires if its output has a URL
MAYBE="$(mk_hook 'bash -c "gh pr create --title x --body y"' 'https://github.com/o/r/pull/9')"
H="$(hook "$MAYBE")"
case "$H" in
  *"pull/9"*) ok "wrapped (maybe) command with a URL in output → still fires" ;;
  *) no "wrapped (maybe) command with a URL in output → still fires (got: $H)" ;;
esac

# --- 9: a flag between `pr edit` and the number still resolves the fallback,
# and -R is passed through to the right repo. A stub `gh` records its argv
# instead of just echoing a fixed URL, so the test can check what it got.
ARGV_FILE="$TMP/gh-argv"
cat > "$STUBDIR/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" > "$ARGV_FILE"
echo "https://github.com/other/repo/pull/44"
EOF
chmod +x "$STUBDIR/gh"

EDIT_WITH_FLAG="$(mk_hook 'gh pr edit --title newtitle -R other/repo 44' '')"
H=$(PATH="$STUBDIR:$PATH" hook "$EDIT_WITH_FLAG")
case "$H" in
  *"pull/44"*) ok "a flag before the number → fallback still finds it" ;;
  *) no "a flag before the number → fallback still finds it (got: $H)" ;;
esac
ARGV=$(cat "$ARGV_FILE" 2>/dev/null)
case "$ARGV" in
  *"44"*"-R other/repo"*) ok "...and passes the number and -R through to gh pr view" ;;
  *) no "...and passes the number and -R through to gh pr view (got argv: $ARGV)" ;;
esac

# Restore the simple stub for any later use.
cat > "$STUBDIR/gh" <<'EOF'
#!/bin/bash
echo "https://github.com/lbecjx/workflow-dev/pull/44"
EOF
chmod +x "$STUBDIR/gh"

# --- 10: the fallback result is still checked against the URL pattern — a gh
# stub that prints garbage must not be relayed as if it were a URL.
cat > "$STUBDIR/gh" <<'EOF'
#!/bin/bash
echo "not a url"
EOF
chmod +x "$STUBDIR/gh"
H=$(PATH="$STUBDIR:$PATH" hook "$EDIT_NO_URL")
[[ -z "$H" ]] && ok "fallback output that isn't a PR URL → quiet, not relayed" || no "fallback output that isn't a PR URL → quiet, not relayed (got: $H)"

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
