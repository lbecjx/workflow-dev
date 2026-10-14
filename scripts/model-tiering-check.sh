#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# The model-tiering verdict: are the agent roles bound and current, or has the
# user chosen the default model for this repo or this story? Called in two ways:
#
#   model-tiering-check.sh --status [payload]
#       Prints one word and exits 0: ok, unmapped, stale, incomplete, opted-out,
#       no-harness, no-registry, or not-ours. `skills/init` (Phase 0) and
#       `config-check.sh`, the configuration interceptor, read it. The payload
#       (a hook-style JSON naming the skill, and optionally `cwd`) is passed as
#       an argument; with none, stdin is read.
#   model-tiering-check.sh --role-models
#       One `role<TAB>state<TAB>model` line per role, for the usage report.
#
# Until WD-0108 this script was also the hook that paused a skill to ask the
# tiering question. That moved to config-check.sh, which asks it together with
# the other missing setup answers; called any other way, this script says
# nothing.
#
# A skill counts as this plugin's when it arrives as `workflow-dev:<name>`,
# where `<name>` is a real directory under this plugin's `skills/` — derived,
# never a hardcoded list.
#
# "Bound and current" is the same thing setup-models writes: an agent file per
# role under ~/.claude/agents, carrying a `roles-hash` comment
# equal to the one scripts/roles-hash.sh computes now. Anything else — no file,
# or a hash from an older registry — is stale, and says so.
#
# `--status` answers `not-ours` for a skill that isn't this plugin's and for the
# setup command itself, `no-harness` outside Claude Code, and `opted-out` for a
# default model chosen for this repo or this story.

set -u

MODE=""
PAYLOAD_ARG=""
case "${1:-}" in
  --status) MODE="status"; PAYLOAD_ARG="${2:-}" ;;
  --role-models) MODE="role-models" ;;
  *) exit 0 ;;
esac

HERE="$(cd -P "$(dirname "$0")" && pwd -P)"
ROLES="$HERE/../skills/setup-models/references/roles.md"
SETUP_SKILL="setup-models"

emit() { printf '%s' "$1"; }

# One line, always exit 0 — the `--status` contract skills/init reads.
status() { emit "$1"; exit 0; }

# Is the default model chosen for the project containing $1 — or for its active
# story? Prints `repo` or `story`, nothing when neither (WD-0045). The choice is
# only ever per repo or per story, never per user or per machine:
#   repo   .workflow-dev/config.env carries tiering=default
#   story  the Decisions table of the story the branch names (wd-0045-… →
#          WD-0045) carries a `Tiering: default model` row
default_scope() {
  local root branch code
  root="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)" || return 0
  # shellcheck source=config-env.sh
  if . "$HERE/config-env.sh" 2>/dev/null && [[ "$(repo_config_get "$root" tiering)" == default ]]; then
    printf 'repo'; return 0
  fi
  branch="$(git -C "$root" symbolic-ref --short HEAD 2>/dev/null)" || return 0
  code="$(printf '%s' "$branch" | grep -oiE '[a-z]+-[0-9]{4}' | head -1 | tr '[:lower:]' '[:upper:]')"
  # A Decisions table row, not a mention: a story that merely documents this very
  # row (WD-0045's own file does) must not silence the reminder by quoting it.
  if [[ -n "$code" ]] && grep -qsE '^\|[^|]*\|[[:space:]]*Tiering: default model[[:space:]]*\|' "$root/.workflow-dev/context/$code.md"; then
    printf 'story'
  fi
}

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

# The agents directory — ONE mapping, shared by the reader and the reminder, so
# a path change is edited in a single place. Empty outside Claude Code.
agents_dir_for() {
  case "$1" in
    claude)   printf '%s' "$HOME/.claude/agents" ;;
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
#              never do, and an absent model means the harness default.
#   opt-out    a default model was chosen for this repo or this story (see
#              `default_scope`).
#   unreadable no harness signal. An unreadable registry prints NOTHING — with
#              no roles to name there is no row to label — and the consumer
#              (session-usage.sh) reports that empty case itself.
# The role parsing and the hash both reuse this script's own code and
# scripts/roles-hash.sh, so no second parser can diverge from the reminder's.
role_models() {
  local agents_dir hash optout=0
  [[ -n "$(default_scope "$PWD")" ]] && optout=1
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
          # (never honest), and an absent `model:` means the harness default,
          # so `default` is the true answer.
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

# --- Is this even a workflow-dev skill? ------------------------------------
# The Skill tool's input field name isn't documented, and the two events carry
# the skill's name under different keys, so try the known ones and fall back to
# "does the invocation name one of this plugin's own skills" — derived from the
# skills directory, never a hardcoded list.
if [[ "$MODE" == "status" ]] && [[ -n "$PAYLOAD_ARG" ]]; then
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

if [[ -z "$SKILL" ]]; then
  for d in "$HERE"/../skills/*/; do
    name="$(basename "$d")"
    case "$INPUT" in
      *"workflow-dev:$name"*) SKILL="$name"; break ;;
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

# --- A default model chosen for this repo or this story? (WD-0045) ---------
# The only way out of tiering: per repo or per story, never for the whole machine.
# Both read as "opted-out": run everything on the default model, say nothing.
PROJECT_DIR="$(json_string cwd)"; [[ -n "$PROJECT_DIR" ]] || PROJECT_DIR="$PWD"
if [[ -n "$(default_scope "$PROJECT_DIR")" ]]; then
  [[ "$MODE" == "status" ]] && status "opted-out"
  exit 0
fi

# --- Under Claude Code? Outside it there are no agent files to look for -----
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

exit 0
