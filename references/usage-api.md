<!--
workflow-dev — a persistent-context development workflow for Claude Code and OpenCode
Copyright (C) 2026  lbecjx

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version. See LICENSE for the full text.
-->

# Story cost API (`.usage/.index.json`)

A read-only summary of every story's cost, for tools outside this plugin — a
status line, a dashboard. It is a file, not a command: a reader needs no `jq`,
no shell, and no path to the installed plugin.

## Where

`<git toplevel>/.workflow-dev/context/.usage/.index.json`

`scripts/session-usage.sh` rebuilds it from the story ledgers after every
checkpoint (`--snapshot`) and every `--reconcile`. The write is atomic (temp
file, then rename), so a reader never sees half a file.

**Detection:** the file exists only in a project that uses workflow-dev and has
recorded at least one checkpoint. No file means nothing to show — a reader
skips its workflow-dev segment silently, never an error.

## Shape (`schema: "workflow-dev.usage/1"`)

```json
{
  "schema": "workflow-dev.usage/1",
  "updated_at": "2026-10-08T08:04:13Z",
  "last_story": "WD-0049",
  "stories": {
    "WD-0049": {
      "total_usd": 23.4459,
      "estimated": true,
      "lower_bound": true,
      "verified": false,
      "verified_reason": "estimated",
      "checkpoints": 9,
      "unpriced_checkpoints": 5,
      "sessions": 1,
      "last_stage": "validate",
      "last_recorded_at": "2026-10-08T08:04:13Z",
      "tokens": { "input": 722, "output": 214915, "reasoning": 0, "cache_read": 54676871, "cache_write": 1310202 },
      "by_agent": {
        "orchestrator": { "cost_usd": 20.0388, "lower_bound": false },
        "wd-adversary": { "cost_usd": 2.4821, "lower_bound": true }
      }
    }
  }
}
```

| Field | Meaning |
|---|---|
| `schema` | Contract version. A reader must check it and skip on a value it does not know. A breaking change gets a new value; added fields do not. |
| `updated_at` | When the index was rebuilt (UTC). |
| `last_story` | The story with the most recent checkpoint — the one most likely in progress. `null` when there is none. |
| `total_usd` | The story's cost across every session and harness, in USD, rounded to 4 decimals. The sum of the ledger's deltas. |
| `estimated` | Some session's latest reading is an estimate, not Claude Code's exact figure. An estimate is settled later only if that session did no new work after the story's checkpoint; otherwise the exact figure would include work done for something else, and the estimate stays. |
| `verified` | `true` when the total holds only figures the harness itself recorded, so its error against the harness's own accounting is 0. Show a check. Every one of these must hold: each session's latest reading is exact (a Claude Code cost-state with no sub-agent still writing after it, or an OpenCode row); the last priced reading of every earlier segment of a session is exact too; every model with tokens has a price; and no session is shared with another story, since the split between stories is not something the harness measured. It covers `total_usd`, not `by_agent`. `session-usage.sh` prints `usage <story> · spend verified ✓ $<total> …` once, when a checkpoint or `--reconcile` for that story makes it verified. A rebuild with no readable previous index is a silent baseline. |
| `verified_reason` | `null` when verified; otherwise why not: `estimated`, `unpriced`, `earlier-estimate`, `shared-session` or `no-checkpoints`. |
| `lower_bound` | The real cost is at least `total_usd`: an estimate (they run low — calls Claude Code makes outside the transcript), a session with no price yet, or a sub-agent whose logged output is incomplete. Show it as `≥`. |
| `checkpoints`, `unpriced_checkpoints`, `sessions` | Ledger counts. |
| `last_stage`, `last_recorded_at` | The latest workflow checkpoint's stage (`init`, `plan`, `implement`, `validate`, `save`) and time. A `reconcile` entry is bookkeeping and never shows here, nor makes a story `last_story`. |
| `tokens` | Token totals across the story. |
| `by_agent` | Per role (`orchestrator`, `wd-judge`, …): `cost_usd` (`null` when no reading was priced) and `lower_bound` (`true` once any of its readings had incomplete logged output). Roles are always priced from the price table, never from Claude Code's exact figure, which has no per-role split — so they need not add up to `total_usd`. |

## What it is not

- **Not the session's cost.** Claude Code's own figure (the status line's
  `cost.total_cost_usd`) is one session; a story spans sessions, and a session
  can work on more than one story. Show them as two separate numbers.
- **Not live to the turn.** It changes when a workflow step records a
  checkpoint, not on every message.
- **Not writable by readers.** Only `session-usage.sh` writes it.
- **Not a lock.** Two checkpoints written at the same instant can leave the
  index one write behind until the next one; the ledgers themselves are the
  source of truth.

Entries are keyed by ledger **file name** — the same id `--story` reads. A
ledger that does not parse is left out (and left on disk for the human).
