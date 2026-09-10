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

### Step 5: Task group complete → validate

When all tasks in the group are done:

1. Show completion summary
2. Run `/workflow-dev:validate` (or tell human to run it)
3. If FAIL → fix issues, re-validate
4. If PASS → suggest commit message, update plan progress in story.md

### Step 6: Update story.md and suggest saving

After successful validation:
- Mark task group as "Done" in Plan Progress table (this one update happens here, directly — it's the literal record of what this skill just did)
- Suggest running `/workflow-dev:save` to persist estimated progress, discoveries, and anything else from this task group into the story's Working Memory section — don't duplicate that logic here inline; `save` already owns reviewing the conversation and classifying what goes where

## Principles

All principles from `references/coding-standards.md` and `references/decision-points.md` apply. The three non-negotiable ones:

1. **Human-in-the-loop** — explain and wait after every task. No silent batching.
2. **Validate before commit** — always run `/workflow-dev:validate` after completing a task group.
3. **Zero-inference** — read code or ask. Never assume.
