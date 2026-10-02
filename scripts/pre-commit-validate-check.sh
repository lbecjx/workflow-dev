#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
# PreToolUse hook (matcher: Bash) — requires explicit human confirmation
# before a git commit, when this project uses workflow-dev and no matching
# "already validated" marker exists for the current diff. Never denies the
# commit outright — the human can still approve it — but an injected
# advisory string is easy for an agent to read and then commit past anyway
# without acting on it, especially in an unattended/auto-accept mode where
# nothing forces the moment to actually register. "Committing without
# validating stays the human's call" (validate/SKILL.md: "Doesn't commit or
# push... leaves the call to the human.") now means the human is actually
# asked, not just theoretically free to have noticed an advisory string.
#
# Two modes, one text:
#   pre-commit-validate-check.sh
#       Claude Code `PreToolUse` (matcher: Bash) — emits the JSON envelope.
#   pre-commit-validate-check.sh --message [payload]
#       Prints the reminder as plain text and nothing otherwise, for OpenCode's
#       plugin (payload as an argument — no pipe). Silence covers both "there is
#       a matching marker" and the deferred case below, so the caller never has
#       to interpret an empty answer as a verdict.

set -u

MODE="hook"
PAYLOAD_ARG=""
case "${1:-}" in
  --message) MODE="message"; PAYLOAD_ARG="${2:-}" ;;
esac

if [[ "$MODE" == "message" && -n "$PAYLOAD_ARG" ]]; then
  INPUT="$PAYLOAD_ARG"
else
  INPUT=$(cat)
fi
# command-match.sh owns both questions every commit hook asks: what the command
# was (one JSON extractor, shared) and whether it is really a commit — a command
# that only mentions `git commit` (a heredoc body, an `echo`, a `grep`) is data.
# `maybe` (`bash -c "…"`, `eval`, an unterminated quote) still asks: this hook
# only ever asks, and a missed real commit is worse than one extra question.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=command-match.sh
source "$HERE/command-match.sh"

COMMAND=$(command_from_payload "$INPUT")

[[ "$(command_match git-commit "$COMMAND")" == "no" ]] && exit 0

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
#
# Fingerprints file CONTENT read straight off disk, not `git diff`'s text —
# confirmed the hard way: the previous formula (`git diff` + `git status
# --porcelain`) changed hash across a plain `git add` with zero content
# change, because a file's porcelain status line ("?? f" / " M f" vs "A  f"
# / "M  f") differs between untracked/unstaged and staged even though
# nothing in the file itself changed, and `git diff` alone goes silent for
# a file the instant it's fully staged. Net effect: validating before
# staging (the normal order) and then running `git add` before commit
# invalidated the marker on every single commit, unconditionally. Listing
# touched paths via `git diff --name-only HEAD` (stable across staged vs.
# unstaged for tracked files) plus `git ls-files --others` (untracked
# files) and hashing each path's actual on-disk content sidesteps the
# staging state entirely — `git add` never changes what's on disk.
CURRENT_HASH=$(
  { git diff --name-only HEAD -- . ':!.workflow-dev';
    git ls-files --others --exclude-standard -- . ':!.workflow-dev';
  } | sort -u | while IFS= read -r f; do
    [[ -n "$f" ]] && printf '%s\n' "$f" && cat "$f" 2>/dev/null
  done | shasum | cut -d' ' -f1
)

if [[ -f "$MARKER_FILE" ]]; then
  SAVED_HASH=$(grep -o '"diffHash"[[:space:]]*:[[:space:]]*"[^"]*"' "$MARKER_FILE" | sed -E 's/.*: *"(.*)"/\1/')
  if [[ "$SAVED_HASH" == "$CURRENT_HASH" ]]; then
    # Three-tier, not two: a marker can now record "validated" (a real PASS)
    # or "deferred" (deliberately skipped, per WD-0003 — the human/implement
    # chose to batch this task group's check at story end instead of
    # skipping it entirely). A marker with no status field at all predates
    # this field and is treated as "validated" for backward compatibility.
    STATUS=$(grep -o '"status"[[:space:]]*:[[:space:]]*"[^"]*"' "$MARKER_FILE" | sed -E 's/.*: *"(.*)"/\1/')
    [[ -z "$STATUS" ]] && STATUS="validated"
    if [[ "$STATUS" == "deferred" ]]; then
      # Nothing to say in --message mode: `allow` does not surface a prompt on
      # Claude Code either, so mirroring it as an OpenCode notice would be a
      # reminder the other harness never showed — noise, not parity.
      [[ "$MODE" == "message" ]] && exit 0
      printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"Validation deferred for this task group, as planned — will run once at story end."}}'
      exit 0
    fi
    exit 0
  fi
fi

REMINDER="This project uses workflow-dev quality gates. No matching /workflow-dev:validate record found for the current changes — confirm this commit was actually validated before approving it, or approve anyway if this intentionally skips validate."
if [[ "$MODE" == "message" ]]; then
  printf '%s' "$REMINDER"
else
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"%s"}}' "$REMINDER"
fi
exit 0
