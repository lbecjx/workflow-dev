#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# PreToolUse hook (matcher: Bash) — the actual guarantee behind validate's
# Git History Disclosure dimension (references/rules.md Part 12). A skill
# can be told to self-review the commit message or PR description it just
# drafted, but "the skill was told to" isn't certainty it happened — this
# hook fires on every `git commit` / `gh pr create` / `gh pr edit` command
# regardless of which skill produced it (or whether any workflow-dev skill
# was involved at all), and asks for confirmation unless the exact message
# text already has a matching reviewed-marker from
# git-message-mark-reviewed.sh. Same non-blocking "ask" pattern as
# pre-commit-validate-check.sh: never denies the command outright, but an
# advisory string alone is easy to read past in an auto-accept session —
# this makes the human (or the agent acting for them) actually confront the
# question at the moment it matters.
#
# Message extraction is best-effort, not a real shell parser. It handles the
# one shape this session's own git/gh conventions actually produce — a
# `-m "$(cat <<'EOF' ... EOF)"` / `--body "$(cat <<'EOF' ... EOF)"` heredoc —
# plus a simple single-line `-m "..."` / `--body "..."` fallback. A message
# built some other way (multiple -m flags, --body-file, a delimiter other
# than EOF) won't be recognized, and this hook silently does nothing rather
# than guess — same philosophy as Part 6's "can't discover it, skip, don't
# fail": a check that can't run confidently shouldn't produce a false sense
# of either safety or danger.

INPUT=$(cat)

if command -v jq >/dev/null 2>&1; then
  COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
else
  # Fallback when jq isn't installed: grab the raw JSON string value. Escaped
  # newlines/quotes inside it are unescaped best-effort below — a message
  # containing something this doesn't anticipate just won't match, which
  # fails toward "hook does nothing," not toward a false positive.
  COMMAND=$(printf '%s' "$INPUT" | grep -o '"command"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*: *"(.*)"/\1/')
  COMMAND=$(printf '%s' "$COMMAND" | sed 's/\\n/\n/g; s/\\"/"/g')
fi

[[ -n "$COMMAND" ]] || exit 0

case "$COMMAND" in
  *"git commit"*|*"gh pr create"*|*"gh pr edit"*) ;;
  *) exit 0 ;;
esac

# Pulls the body of the first heredoc in the command: everything between a
# `<<[-]['"]DELIM['"]` opener and the next line that is exactly DELIM.
extract_heredoc_body() {
  local text="$1"
  local delim="" in_body=0 body=""
  while IFS= read -r line; do
    if [[ $in_body -eq 0 ]]; then
      if [[ "$line" =~ \<\<-?[[:space:]]*[\'\"]?([A-Za-z_]+)[\'\"]?[[:space:]]*$ ]]; then
        delim="${BASH_REMATCH[1]}"
        in_body=1
      fi
    elif [[ "$line" == "$delim" ]]; then
      printf '%s' "$body"
      return 0
    else
      body+="$line"$'\n'
    fi
  done <<< "$text"
  # Heredoc opener found but never closed within the command text — return
  # whatever was captured rather than nothing, best-effort.
  [[ -n "$body" ]] && printf '%s' "$body"
}

BODY=$(extract_heredoc_body "$COMMAND")

if [[ -z "$BODY" ]]; then
  BODY=$(printf '%s' "$COMMAND" | grep -oE -- '(-m|--body)[[:space:]]+"[^"]*"' | head -1 | sed -E 's/^(-m|--body)[[:space:]]+"(.*)"$/\2/')
fi

[[ -n "$BODY" ]] || exit 0

MESSAGE_HASH=$(printf '%s' "$BODY" | shasum | cut -d' ' -f1)
MARKER_FILE="${TMPDIR:-/tmp}/workflow-dev-validate/messages/$MESSAGE_HASH.json"

[[ -f "$MARKER_FILE" ]] && exit 0

printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"This commit message / PR description has not been through the Git History Disclosure review (validate Part 12 — formality, no security-incident narration, no personal or internal-workflow exposure). Confirm it is safe to use as-is, or run the check and mark it reviewed first with git-message-mark-reviewed.sh."}}'
exit 0
