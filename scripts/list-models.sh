#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code and OpenCode
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Invoked by /workflow-dev:setup-models. Lists the models the *harness* itself
# offers, so setup can present a live list instead of one hardcoded in the
# plugin. A hardcoded list is wrong on most machines and rots as models come
# and go — the whole reason roles exist (see
# skills/setup-models/references/roles.md).
#
# Output: one model per line, tab-separated `provider<TAB>model`. The split is
# on the *first* slash only, so a nested id keeps its remainder intact —
# `nested-vendor/sub/id-three` is provider `nested-vendor`, model `sub/id-three`.
# A line with no slash isn't a
# `provider/model` id and is skipped. Input order is preserved (the CLI's own
# ordering), not re-sorted here.
#
# Exit: 0 = at least one model listed; 1 = could not enumerate (reason on
# stderr); 2 = no automatic source exists, so the caller should ask the user to
# enter a model (its stderr says how). A non-zero exit is the honest outcome
# the workflow degrades on — never "the list came back empty, pick anyway".
#
# Test seams: WD_OPENCODE_MODELS_CMD replaces the OpenCode command (default
# `opencode models`); WD_CLAUDE_MODELS_CMD replaces the Claude Code fetch.
# Both mirror OPENCODE_DB in save-read-unsaved.sh. --harness forces a harness,
# so a test doesn't depend on the ambient environment.
#
# --print-harness prints just the detected harness name and exits, so a caller
# that needs to know *which* harness it is on (setup-models decides where to
# write its agent file) asks here instead of re-deriving the signals — one
# definition of "how we detect the harness", not two that can drift.

set -u

PRINT_HARNESS=0
HARNESS=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --harness) HARNESS="${2:-}"; shift 2 ;;
    --print-harness) PRINT_HARNESS=1; shift ;;
    *) shift ;;
  esac
done

# OpenCode sets OPENCODE_TERMINAL; Claude Code sets
# CLAUDECODE/CLAUDE_CODE_ENTRYPOINT. Same signals save-read-unsaved.sh uses.
detect_harness() {
  if [[ -n "${OPENCODE_TERMINAL:-}${OPENCODE:-}" ]]; then echo opencode; return; fi
  if [[ -n "${CLAUDECODE:-}${CLAUDE_CODE_ENTRYPOINT:-}" ]]; then echo claude; return; fi
  echo ""
}

[[ -n "$HARNESS" ]] || HARNESS="$(detect_harness)"

if [[ $PRINT_HARNESS -eq 1 ]]; then
  if [[ -z "$HARNESS" ]]; then
    echo "cannot enumerate: no harness detected (neither OpenCode nor Claude Code signals are set)" >&2
    exit 1
  fi
  echo "$HARNESS"
  exit 0
fi

# Split `provider/model` on the first slash; drop anything without one.
normalize() {
  awk '{ i = index($0, "/"); if (i > 1) printf "%s\t%s\n", substr($0, 1, i - 1), substr($0, i + 1) }'
}

case "$HARNESS" in
  opencode)
    CMD="${WD_OPENCODE_MODELS_CMD:-opencode models}"
    if ! RAW="$($CMD 2>/dev/null)"; then
      echo "cannot enumerate: \`$CMD\` failed" >&2
      exit 1
    fi
    OUT="$(printf '%s\n' "$RAW" | normalize)"
    if [[ -z "$OUT" ]]; then
      echo "cannot enumerate: \`$CMD\` returned no provider/model entries" >&2
      exit 1
    fi
    printf '%s\n' "$OUT"
    ;;
  claude)
    # Claude Code has no CLI that lists models. The one real dynamic source is
    # a configured gateway/API: their GET /v1/models returns the ids. Without
    # one, the honest path is to ask the user — never to invent an alias list
    # (aliases are a few names that rot, and naming them here would be exactly
    # the hardcoded list the plugin must not have).
    RESP=""
    if [[ -n "${WD_CLAUDE_MODELS_CMD:-}" ]]; then
      RESP="$($WD_CLAUDE_MODELS_CMD 2>/dev/null)" || RESP=""
    elif [[ -n "${ANTHROPIC_BASE_URL:-}" ]] && command -v curl >/dev/null 2>&1; then
      AUTH=()
      [[ -n "${ANTHROPIC_API_KEY:-}" ]] && AUTH=(-H "x-api-key: $ANTHROPIC_API_KEY")
      RESP="$(curl -fsS -H "anthropic-version: 2023-06-01" "${AUTH[@]}" \
        "${ANTHROPIC_BASE_URL%/}/v1/models" 2>/dev/null)" || RESP=""
    fi
    if [[ -n "$RESP" ]]; then
      OUT="$(printf '%s\n' "$RESP" | grep -o '"id"[[:space:]]*:[[:space:]]*"[^"]*"' | sed -E 's/.*: *"(.*)"/\1/')"
      if [[ -n "$OUT" ]]; then
        while IFS= read -r m; do [[ -n "$m" ]] && printf 'claude-code\t%s\n' "$m"; done <<< "$OUT"
        exit 0
      fi
    fi
    echo "no automatic model source: set ANTHROPIC_BASE_URL to list from a gateway, or run \`/model\` in Claude Code to see your models and enter one manually (https://docs.claude.com/en/docs/claude-code/model-config)" >&2
    exit 2
    ;;
  "")
    echo "cannot enumerate: no harness detected (neither OpenCode nor Claude Code signals are set)" >&2
    exit 1
    ;;
  *)
    # A harness this script doesn't know. Reported, never an empty-but-usable list.
    echo "cannot enumerate: unknown harness '$HARNESS'" >&2
    exit 1
    ;;
esac
