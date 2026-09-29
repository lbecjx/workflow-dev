#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# The model-tiering reminder: asks while the agent roles are unbound or stale,
# and goes quiet once they are bound and current — or once the user has opted
# out. Called in four ways:
#
#   model-tiering-check.sh
#       Claude Code `PreToolUse` (matcher: Skill) — the agent invoking a
#       workflow-dev skill. Emits the explicit `permissionDecision: "ask"`.
#   model-tiering-check.sh --expansion
#       Claude Code `UserPromptExpansion` — the user typing
#       `/workflow-dev:<skill>` directly, which bypasses PreToolUse entirely.
#       That event has no permission decision, so the most it supports is
#       injecting the same reminder as context (a soft advisory — the honest
#       ceiling on that path, not a choice).
#   model-tiering-check.sh --status [payload]
#       Prints one word and exits 0. OpenCode's plugin reads this, because
#       OpenCode's `tool.execute.before` can only block or rewrite arguments —
#       it cannot ask, so OpenCode gets an advisory rather than an ask. The
#       payload (the JSON Claude Code would have piped) may be passed as an
#       argument instead of on stdin, which is how the plugin calls it without
#       a pipe.
#   model-tiering-check.sh --message [payload]
#       Prints the reminder text itself (plain, no JSON envelope) when the roles
#       are unbound/stale, and nothing otherwise. OpenCode's plugin calls this
#       so the reminder copy has one owner — this script — instead of the plugin
#       carrying a second wording that can drift from Claude Code's ask.
#
# A skill counts as this plugin's whether it arrives scoped as
# `workflow-dev:<name>` (Claude Code) or hyphenated as `workflow-dev-<name>`
# (the name OpenCode installs), where `<name>` is a real directory under this
# plugin's `skills/` — derived, never a hardcoded list.
#
# "Bound and current" is the same thing setup-models writes: an agent file per
# role under the harness's agents directory, carrying a `roles-hash` comment
# equal to the one scripts/roles-hash.sh computes now. Anything else — no file,
# or a hash from an older registry — is stale, and says so.
#
# Silent on: a skill that isn't this plugin's, the setup command itself (asking
# someone to run the fix while they run the fix is noise), an undetectable
# harness, and the opt-out.

set -u

MODE="hook"
PAYLOAD_ARG=""
case "${1:-}" in
  --expansion) MODE="expansion" ;;
  --status) MODE="status"; PAYLOAD_ARG="${2:-}" ;;
  --message) MODE="message"; PAYLOAD_ARG="${2:-}" ;;
esac

HERE="$(cd -P "$(dirname "$0")" && pwd -P)"
ROLES="$HERE/../skills/setup-models/references/roles.md"
OPTOUT="$HOME/.workflow-dev/tiering.json"
SETUP_SKILL="setup-models"

emit() { printf '%s' "$1"; }

# One line, always exit 0 — the `--status` contract the OpenCode plugin reads.
status() { emit "$1"; exit 0; }

# JSON-escape a string for embedding in a hand-built JSON envelope. The reminder
# text contains `"` (around `{"optOut": true}`), which a JSON string value must
# escape as `\"`. Kept as a function so the text stays plain for `--message` and
# only the JSON boundary escapes it — the one place a raw quote must never land.
json_escape() { printf '%s' "$1" | sed 's/"/\\"/g'; }

# --- Is this even a workflow-dev skill? ------------------------------------
# The Skill tool's input field name isn't documented, and the two events carry
# the skill's name under different keys, so try the known ones and fall back to
# "does the invocation name one of this plugin's own skills" — derived from the
# skills directory, never a hardcoded list.
if [[ "$MODE" == "status" || "$MODE" == "message" ]] && [[ -n "$PAYLOAD_ARG" ]]; then
  INPUT="$PAYLOAD_ARG"
else
  INPUT="$(cat)"
fi
json_string() { # $1 = key
  printf '%s' "$INPUT" | grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 | sed -E 's/.*: *"(.*)"/\1/'
}

SKILL="$(json_string skill)"
[[ -z "$SKILL" ]] && SKILL="$(json_string command_name)"
SKILL="${SKILL#workflow-dev:}"
SKILL="${SKILL#workflow-dev-}"

if [[ -z "$SKILL" ]]; then
  for d in "$HERE"/../skills/*/; do
    name="$(basename "$d")"
    case "$INPUT" in
      *"workflow-dev:$name"*|*"workflow-dev-$name"*) SKILL="$name"; break ;;
    esac
  done
fi

# Not one of ours (or we couldn't tell) — say nothing.
if [[ -z "$SKILL" || ! -d "$HERE/../skills/$SKILL" ]]; then
  [[ "$MODE" == "status" ]] && status "not-ours"
  exit 0
fi

# Never nag while running the thing that fixes it.
[[ "$SKILL" == "$SETUP_SKILL" ]] && { [[ "$MODE" == "status" ]] && status "not-ours"; exit 0; }

# --- Opted out? ------------------------------------------------------------
if [[ -f "$OPTOUT" ]] && grep -q '"optOut"[[:space:]]*:[[:space:]]*true' "$OPTOUT"; then
  [[ "$MODE" == "status" ]] && status "opted-out"
  exit 0
fi

# --- Which harness, so we know which agent files to look for ---------------
HARNESS="$("$HERE/list-models.sh" --print-harness 2>/dev/null)" || HARNESS=""
case "$HARNESS" in
  claude)   AGENTS_DIR="$HOME/.claude/agents" ;;
  opencode) AGENTS_DIR="$HOME/.config/opencode/agents" ;;
  *)        [[ "$MODE" == "status" ]] && status "no-harness"; exit 0 ;;
esac

# --- Bound and current? ----------------------------------------------------
HASH="$("$HERE/roles-hash.sh" 2>/dev/null)" || HASH=""
[[ -n "$HASH" ]] || { [[ "$MODE" == "status" ]] && status "no-registry"; exit 0; }

MISSING=""; STALE=""; NROLES=0
# Role names are the `### \`role\`` headings of the registry — one source, so a
# renamed role is picked up here without touching this script.
while IFS= read -r role; do
  [[ -n "$role" ]] || continue
  NROLES=$((NROLES + 1))
  f="$AGENTS_DIR/$role.md"
  if [[ ! -f "$f" ]]; then
    MISSING="$MISSING $role"
  elif ! grep -q "workflow-dev:roles-hash $HASH" "$f"; then
    STALE="$STALE $role"
  fi
done < <(grep '^### ' "$ROLES" 2>/dev/null | sed -E 's/^### `([^`]+)`.*/\1/')

# The registry is readable (roles-hash.sh succeeded) but yielded no role
# headings — a format change this grep no longer matches. Fail loud, not
# silent: treat it as unbound so the reminder still nags, rather than reporting
# "ok" and letting a nothing-mapped user read as clean.
[[ "$NROLES" -eq 0 ]] && MISSING="*"

if [[ -z "$MISSING" && -z "$STALE" ]]; then
  [[ "$MODE" == "status" ]] && status "ok"
  exit 0
fi

if [[ "$MODE" == "status" ]]; then
  if [[ -n "$MISSING" && -n "$STALE" ]]; then status "incomplete"
  elif [[ -n "$MISSING" ]]; then status "unmapped"
  else status "stale"
  fi
fi

# --- Tell the human --------------------------------------------------------
# This text is the single source of truth, shared by Claude Code (the JSON
# envelope below) and OpenCode (the plugin's `--message` mode). It stays plain
# here; only the JSON boundary escapes it (json_escape above).
REMINDER="Model tiering isn't set up on this harness: run /workflow-dev:setup-models to bind each agent role to a model, or set {\"optOut\": true} in ~/.workflow-dev/tiering.json to run everything on your default model and stop being asked."
if [[ -n "$STALE" ]] && [[ -z "$MISSING" ]]; then
  REMINDER="The agent roles are stale — the role registry changed since they were generated. Re-run /workflow-dev:setup-models to refresh them (your chosen models are kept), or set {\"optOut\": true} in ~/.workflow-dev/tiering.json to run everything on your default model."
fi

case "$MODE" in
  message)
    emit "$REMINDER"
    ;;
  expansion)
    emit "{\"hookSpecificOutput\":{\"hookEventName\":\"UserPromptExpansion\",\"additionalContext\":\"$(json_escape "$REMINDER")\"}}"
    ;;
  *)
    emit "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"ask\",\"permissionDecisionReason\":\"$(json_escape "$REMINDER")\"}}"
    ;;
esac
exit 0
