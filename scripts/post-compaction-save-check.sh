#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
# The actual delivery mechanism for the compaction warning. PreCompact
# can't hand Claude any text (see pre-compact-check.sh), but this hook's
# additionalContext is reliably delivered per Claude Code's own docs.
#
# Registered under BOTH UserPromptSubmit and PostToolUse (no matcher, so
# any tool) in hooks.json — whichever fires first after a compaction
# consumes the marker. UserPromptSubmit alone assumes the human types
# something soon after compacting; during a long autonomous run (e.g.
# /workflow-dev:implement chaining tool calls with no human input in
# between), that assumption is false and the reminder could sit unseen
# for a long time. PostToolUse fires on every one of those tool calls, so
# it catches the case UserPromptSubmit misses.
#
# Since the same script serves two different events, hookEventName in the
# response is read from the hook's own input rather than hardcoded — the
# docs require it to match the event that actually fired.

CONTEXT_DIR=".workflow-dev/context"
MARKER="$CONTEXT_DIR/.compaction-backups/.pending-save-notice"

[[ -f "$MARKER" ]] || exit 0

INPUT=$(cat)
EVENT_NAME=$(printf '%s' "$INPUT" | grep -o '"hook_event_name"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4)
[[ -n "$EVENT_NAME" ]] || exit 0

STORY_FILE=$(sed -n '1p' "$MARKER")
BACKUP_FILE=$(sed -n '2p' "$MARKER")

# Consume it now, not after a successful print — a stale marker nagging
# forever on every future prompt/tool call is worse than missing one notice.
rm -f "$MARKER"

printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":"A context compaction happened while %s was In Progress — raw transcript backup at %s. Do both, now, without asking: (1) Invoke /workflow-dev:save immediately, no permission needed beyond its own '\''save all this?'\'' step. (2) In that same confirmation, add this line verbatim: '\''Declining deletes nothing, but leaves this out of the story file until a future save reads it.'\''"}}' "$EVENT_NAME" "$STORY_FILE" "$BACKUP_FILE"
exit 0
