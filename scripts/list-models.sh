#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
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
# Output: one model per line, tab-separated `provider<TAB>model` (the provider
# column is always `claude-code`). Order is the source's own, not re-sorted.
#
# Exit: 0 = at least one model listed; 1 = could not enumerate (reason on
# stderr); 2 = no automatic source exists, so the caller should ask the user to
# enter a model (its stderr says how). A non-zero exit is the honest outcome
# the workflow degrades on — never "the list came back empty, pick anyway".
#
# Test seam: WD_CLAUDE_MODELS_CMD replaces the gateway fetch.
#
# --print-harness prints `claude` when running under Claude Code and exits 1
# otherwise, so a caller that must know whether it runs under Claude Code at
# all (model-tiering-check.sh: the reminder and the role→model reader have no
# agents directory to read outside it) asks here instead of re-deriving the
# signals — one definition, not two that can drift.

set -u

PRINT_HARNESS=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --print-harness) PRINT_HARNESS=1; shift ;;
    *) shift ;;
  esac
done

# Claude Code sets CLAUDECODE / CLAUDE_CODE_ENTRYPOINT in the environment of
# every hook and tool call.
if [[ -z "${CLAUDECODE:-}${CLAUDE_CODE_ENTRYPOINT:-}" ]]; then
  echo "cannot enumerate: not running under Claude Code (neither CLAUDECODE nor CLAUDE_CODE_ENTRYPOINT is set)" >&2
  exit 1
fi

if [[ $PRINT_HARNESS -eq 1 ]]; then
  echo claude
  exit 0
fi

# Claude Code has no CLI that lists models. The one real dynamic source is a
# configured gateway/API: their GET /v1/models returns the ids. Without one, the
# honest path is to ask the user — never to invent an alias list (aliases are a
# few names that rot, and naming them here would be exactly the hardcoded list
# the plugin must not have).
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
