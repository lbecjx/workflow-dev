#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
# UserPromptSubmit hook — the actual delivery mechanism for the compaction
# warning. PreCompact can't hand Claude any text (see pre-compact-check.sh),
# but UserPromptSubmit's additionalContext is reliably delivered per Claude
# Code's own docs, so it picks up the marker PreCompact left and raises it
# on the very first prompt after a compaction — the earliest point where
# anything can actually reach Claude about it.

CONTEXT_DIR=".workflow-dev/context"
MARKER="$CONTEXT_DIR/.compaction-backups/.pending-save-notice"

[[ -f "$MARKER" ]] || exit 0

STORY_FILE=$(sed -n '1p' "$MARKER")
BACKUP_FILE=$(sed -n '2p' "$MARKER")

# Consume it now, not after a successful print — a stale marker nagging
# forever on every future prompt is worse than missing one notice.
rm -f "$MARKER"

printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"A context compaction happened earlier in this session while %s was still In Progress. The compaction summary may have dropped decisions or discoveries that only ever lived in conversation, never in a file — the raw pre-compaction transcript was backed up to %s as the only remaining copy of whatever that summary lost. Before responding to the prompt below, run /workflow-dev:save on your own initiative to persist anything from before the compaction that is not in the story file yet — save still shows its usual summary and asks for confirmation before writing, this only skips waiting to be asked to run it. When presenting that confirmation this time, explicitly warn the human that declining leaves that information unrecovered — the backup gets deleted once a save actually runs (per save/SKILL.md Step 6), so it is not a copy that can be revisited later if this save is skipped now and the story moves on."}}' "$STORY_FILE" "$BACKUP_FILE"
exit 0
