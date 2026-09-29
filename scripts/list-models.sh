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
# Output: one model per line, tab-separated `provider<TAB>model`. The split is
# on the *first* slash only, so a nested id keeps its remainder intact —
# `openrouter/~anthropic/claude-haiku-latest` is provider `openrouter`, model
# `~anthropic/claude-haiku-latest`. A line with no slash isn't a
# `provider/model` id and is skipped. Input order is preserved (the CLI's own
# ordering), not re-sorted here.
#
# Exit: 0 = at least one model listed; 1 = could not enumerate (reason on
# stderr). A non-zero exit is the honest "cannot enumerate" outcome the
# workflow degrades on — never "the list came back empty, pick anyway".
#
# Test seam: WD_OPENCODE_MODELS_CMD overrides the OpenCode command (default
# `opencode models`), mirroring OPENCODE_DB in save-read-unsaved.sh. --harness
# forces a harness, so a test doesn't depend on the ambient environment.

set -u

HARNESS=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --harness) HARNESS="${2:-}"; shift 2 ;;
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
  "")
    echo "cannot enumerate: no harness detected (neither OpenCode nor Claude Code signals are set)" >&2
    exit 1
    ;;
  *)
    # No model source is wired for this harness yet. Reported as the honest
    # outcome, never as an empty-but-usable list.
    echo "cannot enumerate: no model source for harness '$HARNESS'" >&2
    exit 1
    ;;
esac
