#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  Luis Becerra
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
# PreToolUse hook (matcher: Bash) — advisory reminder to run
# /workflow-dev:validate before a git commit, when this project uses
# workflow-dev and no matching "already validated" marker exists for the
# current diff. Never blocks the commit — only injects a heads-up Claude can
# act on. Committing without validating stays the human's call, matching
# validate/SKILL.md: "Doesn't commit or push... leaves the call to the human."

INPUT=$(cat)
COMMAND=$(printf '%s' "$INPUT" | grep -o '"command"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*: *"(.*)"/\1/')

case "$COMMAND" in
  *"git commit"*) ;;
  *) exit 0 ;;
esac

[[ -d ".workflow-dev/context" ]] || exit 0

git rev-parse --show-toplevel >/dev/null 2>&1 || exit 0
# tr -d '\n' before hashing so this is safe whether the path passes through a
# variable first or not — command substitution silently strips a trailing
# newline, so hashing "$(cmd)" directly vs. piping cmd's raw output produces
# different hashes for the same value unless it's explicitly normalized here.
# (Found the hard way: this and validate/SKILL.md used to compute it two
# slightly different ways and never matched.)
REPO_HASH=$(git rev-parse --show-toplevel | tr -d '\n' | shasum | cut -c1-12)
MARKER_FILE="${TMPDIR:-/tmp}/workflow-dev-validate/$REPO_HASH.json"

# Same formula validate/SKILL.md uses to write the marker — .workflow-dev/ is
# excluded so a /workflow-dev:save write to the story file never invalidates
# a validation that already passed on the actual code changes.
CURRENT_HASH=$(
  { git diff -- . ':!.workflow-dev'; git status --porcelain -- . ':!.workflow-dev'; } | shasum | cut -d' ' -f1
)

if [[ -f "$MARKER_FILE" ]]; then
  SAVED_HASH=$(grep -o '"diffHash"[[:space:]]*:[[:space:]]*"[^"]*"' "$MARKER_FILE" | sed -E 's/.*: *"(.*)"/\1/')
  [[ "$SAVED_HASH" == "$CURRENT_HASH" ]] && exit 0
fi

printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","additionalContext":"This project uses workflow-dev quality gates. No matching /workflow-dev:validate record found for the current changes — confirm validate passed before this commit, or note if this intentionally skips it."}}'
exit 0
