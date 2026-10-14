#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# The configuration interceptor (WD-0108). When one of this plugin's skills is
# about to run and a fixed setup answer is missing, it holds the skill's own
# steps until the agent has asked every missing question together, then lets
# the skill go on. Called in two ways:
#
#   config-check.sh
#       Claude Code `PreToolUse` (matcher: Skill) — the agent invoking a
#       workflow-dev skill. Emits `permissionDecision: "allow"` with an
#       `additionalContext` that lists the missing questions. Never `ask` (its
#       "don't ask again" button would silence this without configuring
#       anything) and never `deny` (Claude Code prints a hook deny behind
#       "Error:"): the same choice model-tiering-check.sh made in WD-0045/46.
#   config-check.sh --expansion
#       Claude Code `UserPromptExpansion` — the user typing
#       `/workflow-dev:<skill>`, which bypasses PreToolUse. That event cannot
#       hold anything, so it carries the same text as context.
#
# The five questions and their owners, which keep each question's wording, its
# options and how its answer is saved (this script only says which are missing):
#   gitignored         `.workflow-dev/config.env`          skills/init/SKILL.md, "The gitignored question"
#   model tiering      model-tiering-check.sh --status     references/tiering-question.md
#   agentCoauthorship  `.workflow-dev/config.env`          skills/summarize-changes/SKILL.md, Step 1
#   notifications      `~/.workflow-dev/config.env`        references/attention-alert.md, "Alerts on this machine"
#   phone              `~/.workflow-dev/config.env`        references/attention-alert.md, "Phone notifications"
#
# Silent on: a skill that isn't this plugin's, `setup-models` (it is the fix
# for tiering), `help` and `usage` (they only read), and nothing missing.
#
# This script does not source model-tiering-check.sh's "is this one of our
# skills" detection: like plugin-update-check.sh, it repeats the small check
# inline. Tiering itself is asked through `model-tiering-check.sh --status`,
# the one owner of that verdict.

set -u

MODE="hook"
[[ "${1:-}" == "--expansion" ]] && MODE="expansion"

HERE="$(cd -P "$(dirname "$0")" && pwd -P)"
PLUGIN_ROOT="$(cd -P "$HERE/.." && pwd -P)"

INPUT="$(cat)"
json_string() { # $1 = key
  printf '%s' "$INPUT" | grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 | sed -E 's/.*: *"(.*)"/\1/'
}
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# --- Is this one of our skills, and one that works on a story? -------------
# Only a `workflow-dev:` name counts: Claude Code's own `/init`, or another
# plugin's bare `plan`, must never raise these questions.
SKILL="$(json_string skill)"
[[ -z "$SKILL" ]] && SKILL="$(json_string command_name)"
SKILL="${SKILL#/}"
if [[ -n "$SKILL" ]]; then
  case "$SKILL" in
    workflow-dev:*) SKILL="${SKILL#workflow-dev:}" ;;
    *) exit 0 ;;
  esac
else
  for d in "$PLUGIN_ROOT"/skills/*/; do
    name="$(basename "$d")"
    case "$INPUT" in
      *"workflow-dev:$name"*) SKILL="$name"; break ;;
    esac
  done
fi
[[ -n "$SKILL" && -d "$PLUGIN_ROOT/skills/$SKILL" ]] || exit 0
case "$SKILL" in
  setup-models|help|usage) exit 0 ;;
esac

# --- Which answers are missing? -------------------------------------------
# The repo is the git toplevel of the directory the event names (the hook runs
# in Claude Code's current directory, which follows `cd`).
DIR="$(json_string cwd)"; [[ -n "$DIR" && -d "$DIR" ]] || DIR="$PWD"
ROOT="$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null)" || ROOT="$DIR"

# shellcheck source=config-env.sh
. "$HERE/config-env.sh" || exit 0

MISSING=()
gi="$(repo_config_get "$ROOT" gitignored 2>/dev/null)" || gi=""
[[ "$gi" == "true" || "$gi" == "false" ]] \
  || MISSING+=("whether to keep the .workflow-dev/ folder gitignored — owner: skills/init/SKILL.md, \"The gitignored question\"")

# Run from the repo root and leave `cwd` out of the payload: the status script
# reads a JSON string without unescaping it, so a path with a quote or a
# backslash would lose the repo's default.
tier="$(cd "$ROOT" 2>/dev/null && "$HERE/model-tiering-check.sh" --status "{\"skill\":\"workflow-dev:$SKILL\"}" 2>/dev/null </dev/null)"
case "$tier" in
  unmapped|stale|incomplete)
    MISSING+=("how to choose the model of each agent role — owner: references/tiering-question.md") ;;
esac

co="$(repo_config_get "$ROOT" agentCoauthorship 2>/dev/null)" || co=""
[[ "$co" == "yes" || "$co" == "no" ]] \
  || MISSING+=("whether commits and PRs of this repo credit the agent as co-author — owner: skills/summarize-changes/SKILL.md, Step 1")

al="$("$HERE/attention-alert.sh" get 2>/dev/null </dev/null)"
[[ "$al" == "unset" ]] \
  && MISSING+=("whether to turn the notifications on for this machine — owner: references/attention-alert.md, \"Alerts on this machine\"")

# Its own answer, also for a machine that already answered the sounds.
ph="$("$HERE/attention-alert.sh" phone get 2>/dev/null </dev/null)"
[[ "$ph" == "unset" ]] \
  && MISSING+=("whether to send push notifications to the phone on this machine — owner: references/attention-alert.md, \"Phone notifications\"")

[[ ${#MISSING[@]} -eq 0 ]] && exit 0

# --- Tell the agent --------------------------------------------------------
LIST=""
for i in "${!MISSING[@]}"; do LIST="$LIST $((i + 1))) ${MISSING[$i]}."; done
NOTE="workflow-dev is missing setup answers, and they come before anything else: before this skill's own first step (for init, before the run-mode question). Missing:$LIST Ask all of them together, in as few ask-question calls as the tool allows (up to 4 questions per call; the phone question last when they do not fit), in the user's language. Each owner file (under $PLUGIN_ROOT) holds that question's wording, options, how its answer is saved, and its fallback when nobody can answer; read the owners before asking. An answer the user already gave counts only under the rule in skills/init/SKILL.md, Phase 0 step 3: save it instead of asking. When nobody can answer (no ask-question tool, a non-interactive session with CLAUDE_CODE_SESSION_ATTENDED=0, or an ask that came back empty), do not ask in prose: apply each owner's fallback and save what it says to save (one saves nothing, so it is asked again when a human is there). If an answer cannot be saved (the script refuses it or prints unavailable), say so once and do not ask it again in this conversation. Save every answer, then continue the skill the user asked for; it is already loaded, so do not call it again."

if [[ "$MODE" == "expansion" ]]; then
  printf '{"hookSpecificOutput":{"hookEventName":"UserPromptExpansion","additionalContext":"%s"}}' "$(json_escape "$NOTE")"
else
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","additionalContext":"%s"}}' "$(json_escape "$NOTE")"
fi
exit 0
