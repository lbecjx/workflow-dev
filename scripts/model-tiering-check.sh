#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code and OpenCode
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
#       asking goes through the permission hook instead, which this reminder
#       does not use yet — so OpenCode gets an advisory rather than an ask. The
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
  --role-models) MODE="role-models" ;;
esac

HERE="$(cd -P "$(dirname "$0")" && pwd -P)"
ROLES="$HERE/../skills/setup-models/references/roles.md"
OPTOUT="$HOME/.workflow-dev/tiering.json"
SETUP_SKILL="setup-models"

emit() { printf '%s' "$1"; }

# One line, always exit 0 — the `--status` contract the OpenCode plugin reads.
status() { emit "$1"; exit 0; }

# The role names, from the registry's `### \`role\`` headings — ONE source, so a
# renamed/added/removed role is picked up by the reminder and the reader alike
# without touching either. `--role-models` and the bound/stale check both call
# this, never their own copy of the grep/sed.
role_names() {
  # `-n` + `/p`: only a `### \`role\`` heading yields a name. Without them, sed
  # prints an unmatched line unchanged, so a prose `### Notas` heading in the
  # registry surfaced as a phantom role row.
  grep '^### ' "$ROLES" 2>/dev/null | sed -nE 's/^### `([^`]+)`.*/\1/p'
}

# The harness's agents directory — ONE mapping, shared by the reader and the
# reminder, so a path change (or a new harness) is edited in a single place.
agents_dir_for() {
  case "$1" in
    claude)   printf '%s' "$HOME/.claude/agents" ;;
    opencode) printf '%s' "$HOME/.config/opencode/agents" ;;
    *)        printf '' ;;
  esac
}

# --- Role→model reader (WD-0025), consumed by the usage report -------------
# Prints one line per DEFINED role — from the registry's `### \`role\``
# headings, never a hardcoded list — as `role<TAB>state<TAB>model`:
#   bound      a generated agent file whose roles-hash matches the current
#              registry; `model` is its front-matter `model:` value, shown
#              exactly as written (an alias like `sonnet` is never resolved to
#              a version we cannot confirm).
#   default    the role is ungenerated, its file predates the registry (hash
#              mismatch), or it carries no readable `model:` to confirm a
#              binding from: the run falls back to the harness default. A
#              hash-matching file with no `model:` is NOT `bound` — claiming so
#              would render an empty model, the one thing this reader must
#              never do, and an absent model is the default on both harnesses.
#   opt-out    ~/.workflow-dev/tiering.json sets optOut: true.
#   unreadable no harness signal. An unreadable registry prints NOTHING — with
#              no roles to name there is no row to label — and the consumer
#              (session-usage.sh) reports that empty case itself.
# The role parsing and the hash both reuse this script's own code and
# scripts/roles-hash.sh, so no second parser can diverge from the reminder's.
role_models() {
  local agents_dir hash optout=0
  [[ -f "$OPTOUT" ]] && grep -q '"optOut"[[:space:]]*:[[:space:]]*true' "$OPTOUT" && optout=1
  agents_dir="$(agents_dir_for "$("$HERE/list-models.sh" --print-harness 2>/dev/null)")"
  hash="$("$HERE/roles-hash.sh" 2>/dev/null)" || hash=""
  local role state model f
  while IFS= read -r role; do
    [[ -n "$role" ]] || continue
    if [[ "$optout" -eq 1 ]]; then
      state="opt-out"; model=""
    elif [[ -z "$agents_dir" || -z "$hash" ]]; then
      state="unreadable"; model=""
    else
      f="$agents_dir/$role.md"
      if [[ ! -f "$f" ]]; then
        state="default"; model=""
      elif ! grep -q "workflow-dev:roles-hash $hash" "$f"; then
        state="default"; model=""
      else
        # Read `model:` from the YAML front-matter ONLY, never the body: a
        # hand-edited body line starting `model:` must not be mistaken for the
        # binding (AC 2). The block must actually CLOSE — `print model` runs on
        # the closing `---` — so an unterminated front matter (no second `---`)
        # prints nothing and reads `default`, rather than trusting a body
        # `model:`. A leading UTF-8 BOM is skipped (byte-wise, LC_ALL=C), the way
        # a YAML parser treats it, so a BOM'd file still reports its binding.
        model="$(LC_ALL=C awk '
          NR == 1 && substr($0, 1, 3) == "\357\273\277" { $0 = substr($0, 4) }
          NR == 1 && $0 !~ /^---[[:space:]]*$/ { exit }
          NR == 1 { next }
          /^---[[:space:]]*$/ { print model; exit }
          !seen && /^model:([[:space:]]|$)/ {
            v = $0; sub(/^model:[[:space:]]*/, "", v); sub(/[[:space:]]+$/, "", v)
            model = v; seen = 1
          }
        ' "$f")"
        if [[ -z "$model" ]]; then
          # The hash matches but no `model:` is readable in the front matter — a
          # binding that cannot be confirmed. `bound` would print an empty model
          # (never honest), and an absent `model:` is the harness default on both
          # harnesses, so `default` is the true answer.
          state="default"; model=""
        else
          state="bound"
        fi
      fi
    fi
    printf '%s\t%s\t%s\n' "$role" "$state" "$model"
  done < <(role_names)
}

if [[ "$MODE" == "role-models" ]]; then
  role_models
  exit 0
fi

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
AGENTS_DIR="$(agents_dir_for "$HARNESS")"
[[ -n "$AGENTS_DIR" ]] || { [[ "$MODE" == "status" ]] && status "no-harness"; exit 0; }

# --- Bound and current? ----------------------------------------------------
HASH="$("$HERE/roles-hash.sh" 2>/dev/null)" || HASH=""
[[ -n "$HASH" ]] || { [[ "$MODE" == "status" ]] && status "no-registry"; exit 0; }

MISSING=""; STALE=""; NROLES=0
# Role names come from the one `role_names` helper (the registry's headings).
while IFS= read -r role; do
  [[ -n "$role" ]] || continue
  NROLES=$((NROLES + 1))
  f="$AGENTS_DIR/$role.md"
  if [[ ! -f "$f" ]]; then
    MISSING="$MISSING $role"
  elif ! grep -q "workflow-dev:roles-hash $HASH" "$f"; then
    STALE="$STALE $role"
  fi
done < <(role_names)

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
