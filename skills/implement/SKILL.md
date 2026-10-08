---
name: implement
description: Executes task groups from the plan with the quality rules loaded. Use when the user says "implement", "execute", "go", or "next task group".
---

<!--
workflow-dev — a persistent-context development workflow for Claude Code and OpenCode
Copyright (C) 2026  lbecjx

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version. See LICENSE for the full text.
-->

# Implement

Executes the next task group from the story's plan section: loads every execution rule, shows progress, explains each change, and runs `/workflow-dev:validate` once the group is complete.

**Read every file under `references/` before executing** — they carry the rules this skill enforces.

**Text shown to the user follows `references/user-language.md` (at the plugin root, not this skill's own `references/`)** — its language, wording, and length.

## When to use

- The user says "implement", "execute", "go with the plan", "next task group"
- `/workflow-dev:plan` has produced a plan and the human is ready to start

## When not to use

- There's no plan section in the story file — tell the human to run `/workflow-dev:plan` first
- The human is already directing work step by step — follow their lead; the same rules apply, they just don't need the formal invocation

## Important

**The rules in `references/` govern any code written under this workflow, whether or not this skill was formally invoked.** This skill formalizes the flow; the engineering standards themselves are permanent.

## Execution

### Step 1: Load context

0. **Detect autonomous mode.** Read the story's Working Memory → Decisions table. A row `Autonomous mode: on` means this run is autonomous: Steps 2–5 below stop asking and follow the infer + record + report rule in `references/autonomous-mode.md` (at the plugin root). Absence of the row means human-piloted — the default, and the behaviour this skill describes as its primary path.

1. Read `.workflow-dev/context/[STORY-ID].md` — find the Plan section, identify next task group (first with status "Not Started" or "In Progress")
2. Read `.workflow-dev/context/REPO.md` — project conventions, prohibitions, good practices
3. Read `references/coding-standards.md` — universal engineering rules
4. Read `references/decision-points.md` — when to stop and ask
5. Detect project stack and load relevant `references/stacks/*.md` files:
   - `react` in package.json → load `stacks/react-typescript.md`
   - (future: go.mod → `stacks/go.md`, etc.)
   - If no stack file exists for this project's tech, universal rules are sufficient

### Step 2: Show what's next

```
Task Group N: <Title>
- [ ] task 1
- [ ] task 2
- [ ] task 3

Validates: AC #X
```

Ask: "Starting with Task Group N?"

In autonomous mode, skip this ask — continue with the next task group. Record
that the task group was started (a normal progress-table update, no separate
decision to log).

### Step 3: Execute tasks — one at a time

For each task:

1. **Read** the relevant source files
2. **Implement** the change following coding-standards.md
3. **Explain** what changed, where, and why (2-3 sentences)
4. **Wait** for human confirmation before next task — *except in autonomous
   mode*, where you do not wait: continue to the next task and note each
   completion in the story's context (Files Touched, as usual). The per-task
   pause is the one confirmation autonomous mode removes; it is replaced by the
   end-of-run report, not by nothing.

Show progress after each task:
```
Task Group N: <Title>
✅ task 1
🔧 task 2 ← current
⬜ task 3
```

### Step 4: Decision points

During implementation, STOP and ask the human when any condition from `references/decision-points.md` is met. Never proceed silently past a decision point.

In autonomous mode, a decision point is not a stop — it is resolved by the
infer + record + report rule in `references/autonomous-mode.md`: infer the
answer the human would give, write the decision and its inferred reason to the
story's Decisions table, and carry it into the end-of-run report. Never skip the
record step — a decision taken for the human with no written trace is the one
failure this mode must not have. The hard boundary in `autonomous-mode.md`
(never push a protected branch, never merge, never skip the adversarial pass,
never invent ACs, never bypass the attribution block) still applies to every
inference, with no fallback.

### Step 5: Task group complete → validate (per the story's validation mode)

> **Gates for this step and the commit/PR it leads to** — the moves that leave
> no artifact of their own, so a miss is easy to overlook. Do them, don't just
> read them:
> - **Read, never re-ask:** the stored validation mode is already in the
>   story's Decisions table — read it; never ask it again here.
> - **`summarize-changes` runs before the commit/PR, never after:** its Part
>   12 review and "mark reviewed" step only mean anything ahead of
>   `git commit` / `gh pr create` / `gh pr edit`.
> - **After a real `gh pr create`/`gh pr edit`, hand back the full URL** as
>   plain text on its own line (WD-0024) — `post-pr-url-check.sh` reminds for
>   this, but relaying it to the human is still this step's job.
> - **One commit per task group** — don't fold unrelated task groups into one
>   commit.
> - **Record the run's ids:** when you spawn a sub-agent, note its id in the
>   story's context (OpenCode's `subagent sessionID`; Claude Code's transcript
>   path), so `validate` can total cost **per story**, not just per session
>   (`session-usage.sh --sessions` / `--transcripts`).
> - **Plugin updates are repo-first and post-merge:** change the **repo** →
>   PR → merge → *then* update the installed copy (Claude Code **and**
>   OpenCode). Never edit an installed copy, and never update ahead of the
>   merge.

When all tasks in the group are done:

**In autonomous mode the quality gate is load-bearing** (see
`references/autonomous-mode.md`): a FAIL here does not let the run continue to a
commit/PR. Fix and re-validate; if the finding cannot be fixed, stop and report
it — never downgrade a blocking finding to a warning so the run can keep going.

1. Show completion summary.

2. Check the story's Working Memory → Decisions for the "Validation mode
   for this story" row — written once by `/workflow-dev:plan`'s Step 5,
   right after the plan was approved. This step never asks that question
   itself; it only reads what was already decided.

   - **"After every task group"** (or no such row at all — an older story
     from before this mode existed): unchanged from before. Run
     `/workflow-dev:validate`. If FAIL → fix issues, re-validate. Once it
     PASSes, continue to point 4.
   - **"Once, at the end"**: defer this task group's validation instead of
     running it. Call `"$PLUGIN_ROOT"/scripts/validate-mark-deferred.sh` (`PLUGIN_ROOT` is `${CLAUDE_PLUGIN_ROOT}` on Claude Code; OpenCode doesn't set it, so use `cd -P "<this skill's directory>/../.." && pwd -P`) — this marks the
     current diff so the commit-time hook (`pre-commit-validate-check.sh`)
     lets the commit through with a visible note instead of asking. Add
     one line to the completion summary: "Validation: deferred (story
     default)." No question, no separate notice — the choice was already
     made once, at plan time; don't re-litigate it here. Continue to
     point 4.
   - **Ad-hoc override, either mode:** if the human explicitly says
     something like "validate this one now" for this specific task group,
     run `/workflow-dev:validate` for it regardless of the stored mode,
     then continue to point 4 once it PASSes. This doesn't change the
     stored mode for the rest of the story — the next task group still
     follows whatever was recorded in Step 2 above.

3. **If this was the last task group in the plan** (every other one
   already Done) **and** the story's mode is "once, at the end": this is
   the trigger for the story-end batched validation — see
   `/workflow-dev:validate`'s batched/story-end mode (its own SKILL.md).
   Run it now, against the full accumulated diff since the story started,
   before considering the story finished — this is the actual validation
   all the deferred task groups have been waiting for, not optional at
   this point. If the mode was "after every task group" instead, skip
   this entirely: every task group was already fully validated on its
   own, so there's nothing left pending to batch — running another pass
   here would just re-pay the cost this mode never deferred in the first
   place.

4. Once this task group is validated, deferred, or overridden (not
   FAILed) → run `/workflow-dev:summarize-changes` for the commit
   message, then suggest it to the human. Update plan progress in
   story.md. In autonomous mode, do not suggest — `summarize-changes`
   marks the text reviewed, and the run continues to the next task group
   (or, after the last one, to the end-of-run report); the human sees the
   drafted text in that report, not per task group.

   This isn't handled inline here on purpose: drafting-and-reviewing the
   commit message is a distinct action from validating the diff, and
   `summarize-changes` is its one owner regardless of what triggered
   it — the same skill also handles a PR's title/description if this task
   group's work becomes one later (a "create the PR" request, a "yes"
   confirming one, filling in a template — none of that needs this skill
   to hand anything off explicitly, `summarize-changes` triggers on its
   own). The `pre-commit-message-check.sh` hook still fires at actual
   `git commit` time regardless of whether this step ran; running it here
   just means that's a formality instead of the first real look at the
   text.

### Step 6: Update story.md and suggest saving

After successful validation:
- Mark task group as "Done" in Plan Progress table (this one update happens here, directly — it's the literal record of what this skill just did)
- Record this task group's cost checkpoint (WD-0037): run
  `"$PLUGIN_ROOT"/scripts/session-usage.sh --snapshot [STORY-ID] --stage implement`
  and show the line it prints (this step's spend and the story's running total); when it also prints a `spend verified ✓` line, tell the human the story's spend is now verified.
  It appends to the story's durable ledger; best-effort, `unavailable` rather
  than a zero when no source resolves. `PLUGIN_ROOT` resolves as `validate`'s
  Step 4 notes.
- Suggest running `/workflow-dev:save` to persist estimated progress, discoveries, and anything else from this task group into the story's Working Memory section — don't duplicate that logic here inline; `save` already owns reviewing the conversation and classifying what goes where
  - **In autonomous mode, run `/workflow-dev:save` after every task group**
    instead of suggesting it (`references/autonomous-mode.md`). Nothing else
    persists the run's progress, decisions, and discoveries while nobody is
    watching, so a crash or compaction mid-run must not lose them. `save` already
    applies without asking in that mode (its Step 4); list what each save wrote
    in the end-of-run report.

## Principles

All principles from `references/coding-standards.md` and `references/decision-points.md` apply. The three non-negotiable ones:

1. **Human-in-the-loop** — explain and wait after every task. No silent batching. The one exception is autonomous mode (`Autonomous mode: on` in the story's Decisions — `references/autonomous-mode.md`), which replaces the per-task wait with infer + record + report; it does not make a human-piloted run silent.
2. **Validate before commit — or defer it deliberately, per the story's chosen mode.** Every task group's changes get checked, one way or another: either `/workflow-dev:validate` runs right after it (marked "validated"), or it's marked "deferred" and folded into the one batched pass at story end (Step 5) — never silently skipped with no marker at all.
3. **Zero-inference** — read code or ask. Never assume.
