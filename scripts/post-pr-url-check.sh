#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code and OpenCode
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# PostToolUse hook (matcher: Bash) — after a real `gh pr create`/`gh pr edit`
# succeeds, hands the agent the PR's full URL so it can relay it plainly
# (WD-0024). The command has already run; this only reminds, never blocks.
#
# Two modes, one owner of both the detection and the wording:
#   post-pr-url-check.sh
#       Claude Code `PostToolUse` — emits the JSON envelope. Reads
#       tool_response.stdout/exit_code from the payload.
#   post-pr-url-check.sh --message [payload]
#       Prints the reminder as plain text, nothing when there is none.
#       OpenCode's plugin calls this with { tool_input, tool_output }: no
#       exit code is available there, so a found URL is the only signal of
#       success (documented gap, see hooks/README.md).
#
# command-match.sh owns detection, same as pre-commit-message-check.sh: `no`
# means the command only mentions `gh pr create`/`gh pr edit` (a heredoc body,
# an echo), so there is nothing to look for. Per its policy, `maybe` is
# treated like `real` here — a missed real PR command is worse than one
# reminder that finds no URL and says nothing.

set -u

MODE="hook"
PAYLOAD_ARG=""
case "${1:-}" in
  --message) MODE="message"; PAYLOAD_ARG="${2:-}" ;;
esac

if [[ -n "$PAYLOAD_ARG" ]]; then
  INPUT="$PAYLOAD_ARG"
else
  INPUT=$(cat)
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=command-match.sh
source "$HERE/command-match.sh"

COMMAND=$(command_from_payload "$INPUT")
[[ -n "$COMMAND" ]] || exit 0

SCAN=$(command_match_scan gh-pr-create,gh-pr-edit "$COMMAND")
VERDICT="${SCAN%% *}"
[[ "$VERDICT" == "no" ]] && exit 0

json_get_string() {
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$1" | jq -r --arg k "$2" '.[$k] // empty' 2>/dev/null
    return 0
  fi
  printf '%s' "$1" | grep -oE "\"$2\"[[:space:]]*:[[:space:]]*\"([^\"\\\\]|\\\\.)*\"" | head -1 | sed -E 's/^"[^"]*"[[:space:]]*:[[:space:]]*"(.*)"$/\1/'
}

if [[ "$MODE" == "hook" ]]; then
  if command -v jq >/dev/null 2>&1; then
    EXIT_CODE=$(printf '%s' "$INPUT" | jq -r '.tool_response.exit_code // 0' 2>/dev/null)
    STDOUT=$(printf '%s' "$INPUT" | jq -r '.tool_response.stdout // empty' 2>/dev/null)
  else
    EXIT_CODE=$(printf '%s' "$INPUT" | grep -o '"exit_code"[[:space:]]*:[[:space:]]*[0-9-]*' | head -1 | grep -o '[0-9-]*$')
    TOOL_RESPONSE=$(printf '%s' "$INPUT" | grep -o '"tool_response"[[:space:]]*:[[:space:]]*{.*}' | head -1)
    STDOUT=$(json_get_string "$TOOL_RESPONSE" "stdout")
  fi
  [[ -z "${EXIT_CODE:-}" || "$EXIT_CODE" == "0" ]] || exit 0
else
  if command -v jq >/dev/null 2>&1; then
    STDOUT=$(printf '%s' "$INPUT" | jq -r '.tool_output // empty' 2>/dev/null)
  else
    STDOUT=$(json_get_string "$INPUT" "tool_output")
  fi
fi

URL_PATTERN='https://[A-Za-z0-9.-]+/[^/[:space:]"]+/[^/[:space:]"]+/pull/[0-9]+'
URL=$(printf '%s' "$STDOUT" | grep -oE "$URL_PATTERN" | tail -1)

if [[ -z "$URL" ]]; then
  PR_VERDICT="${SCAN##* }"
  # Only gh-pr-edit has a documented no-stdout-URL case (AC #5); gh-pr-create
  # always prints the URL on success.
  if [[ "$PR_VERDICT" != "no" ]] && printf '%s' "$COMMAND" | grep -qE '(^|[^A-Za-z0-9_-])gh[[:space:]]+([^;&|]*[[:space:]])?pr[[:space:]]+edit($|[^A-Za-z0-9_-])' \
     && command -v gh >/dev/null 2>&1; then
    # The number/URL can sit anywhere after `pr edit`, not only immediately
    # after it (`gh pr edit --title x 44` as well as `gh pr edit 44 --title x`);
    # a flag's own numeric value in between is a known, accepted gap at this
    # best-effort level. `-R`/`--repo` is read separately so a cross-repo edit
    # is looked up in the right place instead of the hook's own cwd.
    AFTER_EDIT=$(printf '%s' "$COMMAND" | sed -E 's/^.*pr[[:space:]]+edit([[:space:]]|$)//')
    ARG=$(printf '%s' "$AFTER_EDIT" | grep -oE '(^|[[:space:]])([0-9]+|https://[^[:space:]]*/pull/[0-9]+)([[:space:]]|$)' | head -1 | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
    REPO_ARG=$(printf '%s' "$COMMAND" | grep -oE -- '(-R|--repo)[[:space:]=]+[^[:space:]]+' | head -1 | sed -E 's/^(-R|--repo)[[:space:]=]+//')

    TIMEOUT_BIN=""
    if command -v timeout >/dev/null 2>&1; then TIMEOUT_BIN="timeout 4"
    elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT_BIN="gtimeout 4"
    fi
    FALLBACK_URL=$($TIMEOUT_BIN gh pr view ${ARG:+"$ARG"} ${REPO_ARG:+-R "$REPO_ARG"} --json url -q .url 2>/dev/null)
    # Re-run through the same pattern as the stdout path: gh is trusted, but
    # nothing reaches the JSON envelope below without matching the shape this
    # script already promises to emit.
    [[ "$FALLBACK_URL" =~ ^${URL_PATTERN}$ ]] && URL="$FALLBACK_URL"
  fi
fi

[[ -n "$URL" ]] || exit 0

REMINDER="The PR command just ran — relay its full URL to the human as plain text, on its own line, not only as a Markdown link label: $URL"

case "$MODE" in
  message) printf '%s' "$REMINDER" ;;
  *)
    REMINDER_JSON="${REMINDER//\\/\\\\}"
    printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"%s"}}' "$REMINDER_JSON"
    ;;
esac
exit 0
