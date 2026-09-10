---
name: plan
description: Creates a structured implementation plan (task groups) in the active story context. Use when the user says "plan", "make a plan", or "break this down".
---

<!--
workflow-dev — a persistent-context development workflow for Claude Code
Copyright (C) 2026  Luis Becjx

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version. See LICENSE for the full text.
-->

# Plan

Decomposes the current story's acceptance criteria into ordered task groups with specific tasks. The plan is written directly into the story's `.workflow-dev/context/[STORY-ID].md` file — no separate artifacts.

**Before executing, read all files in `references/` for execution principles and validation awareness.**

## When to use

- After `/workflow-dev:init` when the story is understood but work hasn't started
- When a story is complex enough that "next step" isn't enough guidance
- When the human says "plan", "make a plan", "break this down"

## When NOT to use

- Simple fixes (1-2 file changes, obvious path) — just do them
- When the human is already directing step-by-step — follow their lead

## Execution

### Step 1: Read context

1. Read `.workflow-dev/context/[STORY-ID].md` — understand ACs, discoveries, decisions, scope
2. Read `.workflow-dev/context/REPO.md` — understand conventions, prohibitions, infra
3. Read `references/execution-principles.md` — internalize how tasks will be executed
4. Read `references/validation-awareness.md` — understand what the quality gate checks

### Step 2: Explore code

Read the relevant source files to understand:
- Current state (what exists today)
- Target state (what ACs require)
- Patterns to follow (how similar things are done in this codebase)
- Files that need to change

### Step 3: Decompose into task groups

Break the work into ordered task groups. Each group is an atomic unit that:
- Can be validated independently
- Can be committed independently
- Has clear inputs and outputs

**Ordering principle:** dependencies first, tests last (or alongside).

### Step 4: Present plan to human

Show the proposed plan clearly:

```
Plan — [STORY-ID]:

Task Group 1: <Title>
- [ ] <specific task with file path>
- [ ] <specific task with file path>
Validates: AC #X

Task Group 2: <Title>
- [ ] <specific task>
- [ ] <specific task>
Validates: AC #Y

Task Group 3: Tests
- [ ] <test for TG1 behavior>
- [ ] <test for TG2 behavior>
Validates: AC #Z
```

Ask: "Approve this plan, or adjust something?"

### Step 5: Write to story file

If human approves, write the plan as a new section in the story.md file:

```markdown
## 5. Plan

### Task Group 1: <Title>
- [ ] <task>
- [ ] <task>
**Validates:** AC #X
**After completion:** `/workflow-dev:validate` → fix → commit

### Task Group 2: <Title>
- [ ] <task>
- [ ] <task>
**Validates:** AC #Y
**After completion:** `/workflow-dev:validate` → fix → commit

### Plan Progress
| # | Task Group | Status |
|---|-----------|--------|
| 1 | <title> | Not Started |
| 2 | <title> | Not Started |
```

Tell the human the plan is saved and suggest running `/workflow-dev:implement` to start on Task Group 1.

## Principles

1. **Validation-aware** — every task group is designed to pass `/workflow-dev:validate`. If a task would introduce security issues, missing tests, or broken types, the plan accounts for it.
2. **Execution-aware** — tasks are written knowing the agent will execute them with human-in-the-loop, zero-inference, and scope discipline.
3. **Minimal** — don't over-decompose. A fix that takes 3 tasks doesn't need 3 task groups. Group related changes.
4. **Specific** — each task names the file and the change. "Update handler" is bad. "Add a pagination loop to fetchInvoices in src/billing/invoice-client.ts" is good.
5. **Ordered by dependency** — if Task B needs Task A's output, A comes first.
6. **Tests are explicit** — never assume tests will "just happen." Make them a task or a task group.
7. **Commit boundaries** — each task group = one potential commit. Don't mix unrelated changes.
