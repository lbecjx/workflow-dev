---
name: plan
description: Creates a structured implementation plan (task groups) in the active story context. Use when the user says "plan", "make a plan", or "break this down".
---

<!--
workflow-dev — a persistent-context development workflow for Claude Code
Copyright (C) 2026  lbecjx

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

### Step 5: Choose validation mode (once per story, never re-asked)

Once the plan is approved — before writing anything, and before
`/workflow-dev:implement` runs any task group — ask this exactly once for
the whole story:

```
AskUserQuestion:
  question: "Before starting: the full validation (multiple sub-agents, plus
    Adversarial Correctness — minutes on FULL) will run at some point.
    Should it run once at the end of the story, or after every task group?"
  header: "Validation mode"
  options:
    - label: "Once, at the end (recommended)"
      description: "Pay that cost once, not per task group."
    - label: "After every task group"
      description: "Pay that same cost repeatedly — catches issues sooner,
        costs more overall."
```

Both options name the same underlying mechanism explicitly — they differ
only in *frequency* of when it runs, never in *what* runs or *whether* it
runs. Don't substitute a cost figure (a dollar amount, a token count) for
either option's description — a number derived from one measurement isn't
representative across diffs, models, or pricing, and goes stale; "pay once
vs. repeatedly" is the fact that's always true regardless.

**Unattended/non-interactive** (no human available to answer): skip the
tool call entirely, default to "once, at the end" silently — same
fallback philosophy as Adversarial Correctness's own §11.0 unattended
default (`rules.md`), just applied to *frequency* instead of *depth*.

Record the answer in the story's Working Memory → Decisions table (Step 6
writes the Plan section; add this as its own row in the same pass):

```markdown
| Date | Decision | Decided by |
|-------|----------|---------------|
| YYYY-MM-DD | Validation mode for this story: <"once at the end" | "after every task group"> | Human |
```

This is what lets `/workflow-dev:implement`'s Step 5 read the choice
silently later, with no question of its own, ever, during execution — see
its own docs. The choice is sticky for the whole story, not re-asked, but
not an irreversible lock-in either: the human can still say "validate this
one now" for a specific task group at any point as a normal instruction,
without changing what's recorded here.

### Step 6: Write to story file

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
8. **Validation mode is decided once, up front** — asked right after plan approval (Step 5), never per task group and never silently defaulted without asking (except when genuinely unattended). `/workflow-dev:implement` reads this choice; it doesn't decide it.
