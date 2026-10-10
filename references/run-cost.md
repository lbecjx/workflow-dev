<!--
workflow-dev — a persistent-context development workflow for Claude Code
Copyright (C) 2026  lbecjx

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version. See LICENSE for the full text.
-->

# Recording a skill run's cost

Every skill that works on a story points here instead of restating these rules
(WD-0054). A second wording of the same rule is free to drift from the first.

## The rule being measured

A story's cost is **only the spend of the workflow-dev skill runs made for
it**. A run is one skill from its first step to its last: every question to the
human, every answer, every revision. Chat between two skills is never counted,
even when it is about the story. So each run records two checkpoints in the
story's durable ledger (`.workflow-dev/context/.usage/[STORY-ID].json`):

- **Start** — the run's first step, once the STORY-ID is known:

  ```sh
  PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd -P "<this skill's directory>/../.." && pwd -P)}"
  "$PLUGIN_ROOT"/scripts/session-usage.sh --snapshot [STORY-ID] --stage <skill> --start
  ```

  Do not show its line to the human; it costs nothing and says nothing new.

- **End** — the run's very last step, after everything else the skill does:

  ```sh
  "$PLUGIN_ROOT"/scripts/session-usage.sh --snapshot [STORY-ID] --stage <skill>
  ```

  Show the line it prints: this run's spend and the story's running total. If
  it names open runs, say so: the total is then a lower bound.

`<skill>` is the skill's own name (`init`, `plan`, `implement`, `validate`,
`save`, `resume`, `refresh`, `manual-qa`, `summarize-changes`). Claude Code
gives a skill's shell no `CLAUDE_PLUGIN_ROOT`, so the fallback is what normally
runs; never drop it. Both calls are best-effort: a non-zero exit, or
`unavailable`, never stops the skill.

## When a skill records nothing

- **No active story.** The STORY-ID is the story the skill works on. When it
  has none, it is the `.workflow-dev/context/*.md` file whose Implementation
  Status is In Progress, usually the one the git branch names. No story, no
  checkpoint.
- **Nested in another skill's run.** When another workflow-dev skill's run is
  still open in this conversation — it invoked this one (`validate` →
  `manual-qa`, `implement` → `save` or `validate`, `init` → `setup-models`), or a
  hook asked for this one in the middle of it (the save prompted after a
  compaction) — take neither the start nor the end. The outer run already
  contains this spend, and a start here would cut the outer run short: its
  spend before this point would then show up as an open run.
- **Not a story skill.** `help`, `setup-models` and `usage` never record, also
  inside another run: their spend belongs to that run. The script refuses those
  stage names anyway.
- **A wrapper.** `init-auto` records nothing: the `init` it invokes records the
  run.

## Spend outside the transcript

A plugin eval (`claude plugin eval`) runs its cases in child processes, so the
two checkpoints above never see what they cost. Its result file holds the
figure: record it inside the run in progress with `--record-suite`, before that
run's end. It has no start or end of its own and is never a stage of its own.
How and when: `skills/validate/references/rules.md` §6.1.

## Why a start is never skipped

Without its start, an end is measured from the session's previous checkpoint,
which may be the end of another story's run, an hour of unrelated chat ago.
That is the legacy mode the ledger keeps for checkpoints written before 1.36.0.
A start that never gets its end (the session died, the skill was cut short) is
an **open run**: its spend is lost, never guessed, and the story total is marked
`≥`. A skill of another story run in the middle of this one (the human switches
story while `init` waits on its questions) is fine: its run is taken out of this
one, so nothing is counted twice.
