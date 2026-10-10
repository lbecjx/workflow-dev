<!--
workflow-dev — a persistent-context development workflow for Claude Code
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
checkpoint (`--snapshot`), every `--reconcile` and every `--record-suite`. The write is atomic (temp
file, then rename), so a reader never sees half a file.

## What a story costs

A story's cost is **only the spend of the workflow-dev skill runs made for
it**. Each skill (`init`, `plan`, `implement`, `validate`, `save`, `resume`,
`refresh`, `manual-qa`, `summarize-changes`) records a start checkpoint when it
begins and an end checkpoint when it finishes, in the same session; a run costs
end minus start. Chat between skills, and other work in the same session, is
never counted, even when it is about the story. So the session's real spend can
be higher than the sum of its stories. `help`, `setup-models` and `usage` never
record anything.

A start whose end never came (the session died, the skill was cut short) is an
**open run**: its spend is unknown and is never filled in, so the total becomes
a lower bound. A run still being written (the last entry of a session written
in the last 15 minutes) is in progress, not open. An end with no start before it
(ledgers from before 1.36.0) is measured from the session's previous checkpoint,
as it was then. A run of another story nested inside a run of the same session
is taken out of the outer run, so it is counted once.

A plugin eval (`claude plugin eval`) that `validate` runs spends in child
processes, outside the session. Its result file is recorded inside the skill
run it ran in (`session-usage.sh --record-suite`), at the file's `costUsd`,
which already holds the judge's spend. So the story total includes it. An eval that
left no readable result adds no amount and makes the total a lower bound.

**Detection:** the file exists only in a project that uses workflow-dev and has
recorded at least one checkpoint. No file means nothing to show — a reader
skips its workflow-dev segment silently, never an error.

## Shape (`schema: "workflow-dev.usage/2"`)

```json
{
  "schema": "workflow-dev.usage/2",
  "updated_at": "2026-10-08T08:04:13Z",
  "last_story": "WD-0049",
  "stories": {
    "WD-0049": {
      "total_usd": 23.4459,
      "estimated": true,
      "lower_bound": true,
      "open_runs": 0,
      "checkpoints": 9,
      "unpriced_checkpoints": 5,
      "sessions": 1,
      "suite_usd": 4.0946,
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
| `schema` | Contract version. A reader must check it and skip on a value it does not know. A breaking change gets a new value; added fields do not. `/2` (1.36.0) removed `verified` and `verified_reason` from `/1`: they said a figure came from an exact Claude Code reading, which read as a guarantee of what was measured. |
| `updated_at` | When the index was rebuilt (UTC). |
| `last_story` | The story with the most recent checkpoint — the one most likely in progress. `null` when there is none. |
| `total_usd` | The story's cost across every session, in USD, rounded to 4 decimals. The sum of the ledger's deltas. |
| `estimated` | Part of the total is an estimate, not Claude Code's exact figure. A run is exact only when its start and its end are both exact figures and no other story ran inside it; otherwise it is priced from the price table at both ends, model by model, from the tokens spent between them. An exact figure that lands later settles a run only if the run started exact and the session did no new work after its end; otherwise the estimate stays. For ledgers from before 1.36.0: some session's latest reading is an estimate. |
| `lower_bound` | The real cost is at least `total_usd`: an estimate (they run low — calls Claude Code makes outside the transcript), a session with no price yet, a sub-agent whose logged output is incomplete, an open run (`open_runs` > 0), or a plugin eval that left no readable result. Show it as `≥`. |
| `open_runs` | How many skill runs started and never recorded their end (see "What a story costs"). Their spend is missing from `total_usd`. A run in progress is not counted: its start is the story latest checkpoint for a session written in the last 15 minutes (another story working in that session meanwhile does not end it, since a run waiting on the human looks the same). Like the rest of the file, it is computed when the index is written, so a run that dies stays counted as in progress until the next checkpoint in the project. Added in `/2`. |
| `checkpoints`, `unpriced_checkpoints`, `sessions` | Ledger counts. The two checkpoint counts are of **ends** only; a start is bookkeeping. A recorded plugin eval result is none of the three. |
| `suite_usd` | The part of `total_usd` spent by plugin evals (`claude plugin eval`), judge included. `0` when none ran. Added in 1.43.0, within `/2`. |
| `last_stage`, `last_recorded_at` | The latest workflow checkpoint's stage (`init`, `plan`, `implement`, `validate`, `save`, …) and time. A `reconcile` entry and a start are bookkeeping and never show here, nor make a story `last_story`; a story with only a start has `null` here. |
| `tokens` | Token totals across the story. |
| `by_agent` | Per role (`orchestrator`, `wd-judge`, …): `cost_usd` (`null` when no reading was priced) and `lower_bound` (`true` once any of its readings had incomplete logged output). Roles are always priced from the price table, never from Claude Code's exact figure, which has no per-role split — so they need not add up to `total_usd`. |

## What it is not

- **Not the session's cost.** Claude Code's own figure (the status line's
  `cost.total_cost_usd`) is one session; a story spans sessions, and a session
  can work on more than one story. Show them as two separate numbers.
- **Not live to the turn.** It changes when a workflow step records a
  checkpoint, not on every message.
- **Not writable by readers.** Only `session-usage.sh` writes it.
- **Not the closing report.** `session-usage.sh --story <ID> --final` prints a
  per-skill table at story close; it is display only and changes nothing here.
- **Not a lock.** Two checkpoints written at the same instant can leave the
  index one write behind until the next one; the ledgers themselves are the
  source of truth.

Entries are keyed by ledger **file name** — the same id `--story` reads. A
ledger that does not parse is left out (and left on disk for the human).
