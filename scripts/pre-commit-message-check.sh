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
# was involved at all).
#
# Two different enforcement levels, not one:
# - Most of Part 12 (tone, length, disclosure framing) is a judgment call,
#   so an unreviewed message gets a non-blocking "ask" — same pattern as
#   pre-commit-validate-check.sh, never denies outright, but an advisory
#   string alone is easy to read past in an auto-accept session, so this
#   makes the human (or the agent acting for them) actually confront the
#   question at the moment it matters.
# - AI/agent/LLM attribution (Part 12.3's hard rule) is not a judgment
#   call, so it's checked separately and **denied outright** — the only
#   rule in this file that is — regardless of whether the text carries a
#   reviewed-marker. `git-message-mark-reviewed.sh` already refuses to
#   mark text containing it, so reaching this point means that step got
#   bypassed somehow; deny is the backstop for that, not the first line
#   of defense.
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

# Kept byte-identical to git-message-mark-reviewed.sh's AI_ATTRIBUTION_PATTERN
# — if you change one, change the other, or a message could get marked
# reviewed under a pattern this hook doesn't also enforce. Checked against
# the whole raw command, not just the extracted body below, so it still
# catches attribution even if heredoc/-m extraction fails for some reason.
AI_ATTRIBUTION_PATTERN='(co-authored-by:.*(claude|anthropic|openai|chatgpt|copilot|gemini|codex))|(generated (with|by)[^.]*(claude|copilot|chatgpt|anthropic))|🤖|(claude\.ai)|(claude\.com/claude-code)|(anthropic\.com)|(ai-generated)|(ai-assisted)|(written (with|by) (an )?(ai|llm)\b)'

if printf '%s' "$COMMAND" | grep -qiE "$AI_ATTRIBUTION_PATTERN"; then
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"This commit/PR contains AI/agent/LLM attribution or co-authorship (validate Part 12.3 — hard rule, no exceptions). Every commit and PR here is attributed to the human alone. Remove the attribution and re-run."}}'
  exit 0
fi

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

# For a PR, the reviewed text is title+description concatenated — same
# convention summarize-changes/SKILL.md uses when marking it
# (`printf '%s\n\n%s' "<title>" "<description>"`). A commit has no separate
# title, so HASH_TEXT is just the message body.
HASH_TEXT="$BODY"
case "$COMMAND" in
  *"gh pr create"*|*"gh pr edit"*)
    TITLE=$(printf '%s' "$COMMAND" | grep -oE -- '--title[[:space:]]+"[^"]*"' | head -1 | sed -E 's/^--title[[:space:]]+"(.*)"$/\1/')
    [[ -n "$TITLE" ]] && HASH_TEXT=$(printf '%s\n\n%s' "$TITLE" "$BODY")
    ;;
esac

MESSAGE_HASH=$(printf '%s' "$HASH_TEXT" | shasum | cut -d' ' -f1)
MARKER_FILE="${TMPDIR:-/tmp}/workflow-dev-validate/messages/$MESSAGE_HASH.json"

[[ -f "$MARKER_FILE" ]] && exit 0

printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"This commit message / PR description has not been through the Git History Disclosure review (validate Part 12 — formality, no security-incident narration, no personal or internal-workflow exposure). Confirm it is safe to use as-is, or run the check and mark it reviewed first with git-message-mark-reviewed.sh."}}'
exit 0
