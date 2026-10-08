---
name: usage
description: Shows the active story's total consumption — dollars and tokens — totalled from its durable cost ledger across sessions and harnesses. Use when the user asks "usage", "cost", "how much did this story cost", "cuánto costó", or wants the current story's spend.
---

<!--
workflow-dev — a persistent-context development workflow for Claude Code and OpenCode
Copyright (C) 2026  lbecjx

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version. See LICENSE for the full text.
-->

# Usage

**Text shown to the user follows `references/user-language.md` (at the plugin root, not this skill's own `references/`)** — its language, wording, and length.

## What this does

Prints the active story's cost report, summed from its **durable ledger**
(`.workflow-dev/context/.usage/<STORY-ID>.json`) — not from the harness's live
store, which can be deleted (OpenCode hard-deletes sessions; a Claude Code
transcript can be removed). The total spans every session and both harnesses,
so a story started on one and continued on the other still sums correctly.

## When to use

- The user asks what the active story has cost so far, in dollars or tokens
- The user says "usage", "cost", "how much did this story cost", "cuánto costó"

## When NOT to use

- A repo-wide or all-stories total — this reports **one** story's ledger
- A single live session's snapshot — that is `validate`'s checkpoint, not this

## Execution

1. Identify the active story: the `.workflow-dev/context/*.md` whose
   `Implementation Status` is `In Progress` (usually the one the git branch
   names). If none is active, ask which story, or list the ones that have a
   ledger under `.workflow-dev/context/.usage/`.
2. Run the one script — harness-agnostic, no branching here (it dispatches to
   the right adapter itself):

   ```sh
   PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd -P "<this skill's directory>/../.." && pwd -P)}"
   "$PLUGIN_ROOT"/scripts/session-usage.sh --story <STORY-ID>
   ```

3. Present the report as-is: the total, the tokens, the split by stage and by
   session, the **per-agent/role** breakdown (each cub's model included), the
   **configured role→model binding** for every defined role, any
   config-vs-observed discrepancy, and the reminder that a role's model changes
   with `/workflow-dev:setup-models`.

No source and no checkpoint → the script reports `unavailable`; relay that,
never a zero or a total it cannot back. Because the script reads the ledger and
never the live store, a deleted session does not change the answer.

## Principles

- **One report, both harnesses.** The script dispatches on the harness; this
  skill never branches on it.
- **The ledger is the truth, not the live store.** The total survives deletion
  of the session or transcript that produced it.
- **No invented numbers.** `unavailable` when nothing is recorded — the repo's
  rule: fail toward doing nothing rather than a false positive.
