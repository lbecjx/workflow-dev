---
name: implement
description: Executes task groups from the plan with the quality rules loaded. Use when the user says "implement", "execute", "go", or "next task group".
---

<!--
workflow-dev — a persistent-context development workflow for Claude Code
Copyright (C) 2026  lbecjx

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version. See LICENSE for the full text.
-->

# Implement

Executes the next task group from the story's plan section: loads every execution rule, shows progress, explains each change, and runs `/workflow-dev:validate` once the group is complete.

**Read every file under `references/` before executing** — they carry the rules this skill enforces.

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

### Step 3: Execute tasks — one at a time

For each task:

1. **Read** the relevant source files
2. **Implement** the change following coding-standards.md
3. **Explain** what changed, where, and why (2-3 sentences)
4. **Wait** for human confirmation before next task

Show progress after each task:
```
Task Group N: <Title>
✅ task 1
🔧 task 2 ← current
⬜ task 3
```

### Step 4: Decision points

During implementation, STOP and ask the human when any condition from `references/decision-points.md` is met. Never proceed silently past a decision point.

### Step 5: Task group complete → validate (per the story's validation mode)

When all tasks in the group are done:

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
     running it. Call `scripts/validate-mark-deferred.sh` — this marks the
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
   story.md.

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
- Suggest running `/workflow-dev:save` to persist estimated progress, discoveries, and anything else from this task group into the story's Working Memory section — don't duplicate that logic here inline; `save` already owns reviewing the conversation and classifying what goes where

## Principles

All principles from `references/coding-standards.md` and `references/decision-points.md` apply. The three non-negotiable ones:

1. **Human-in-the-loop** — explain and wait after every task. No silent batching.
2. **Validate before commit — or defer it deliberately, per the story's chosen mode.** Every task group's changes get checked, one way or another: either `/workflow-dev:validate` runs right after it (marked "validated"), or it's marked "deferred" and folded into the one batched pass at story end (Step 5) — never silently skipped with no marker at all.
3. **Zero-inference** — read code or ask. Never assume.
