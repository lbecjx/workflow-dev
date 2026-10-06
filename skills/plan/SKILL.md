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

**This is its own moment.** Ask for approval on its own — do **not** bundle it
with Step 5's two one-time questions in one prompt. The human must be able to
approve (or adjust) the plan *before* being asked to choose a validation mode;
mixing them lets a mode be picked for a plan that isn't approved yet, and it
reads as one long form instead of a decision.

### Step 5: Choose validation mode and manual QA (once per story, never re-asked)

> **Gates for this step** — the two one-time questions below, asked here and
> never again for this story; a miss here is easy to overlook. Do them, don't
> just read them:
> - **Validation mode:** "once at the end" or "after every task group"? →
>   record it in the Decisions table; `implement` reads it, never re-asks.
> - **Manual QA:** "yes" or "no" for this story? → record it; `validate`
>   reads it, never re-asks.
> Unattended → both default silently (once at the end / no).

Once the plan is approved — before writing anything, and before
`/workflow-dev:implement` runs any task group — ask this exactly once for
the whole story:

```
Ask the human (OpenCode `question`, Claude Code `AskUserQuestion`):
  question: "Before starting: the full validation (multiple sub-agents, plus
    Adversarial Correctness) will run at some point. Should it run once at the
    end of the story, or after every task group?"
  header: "Validation mode"
  options:
    - label: "Once, at the end (recommended)"
      description: "Pay that cost once, not per task group."
    - label: "After every task group"
      description: "Pay that same cost repeatedly — catches issues sooner,
        costs more overall."
```

> `(recommended)` marks the plugin's **default suggestion** — it is **not** the
> recorded answer. Whatever the human picks is what's written to Decisions and
> read downstream; the label only surfaces the cheaper default. Don't let a
> reader mistake "the plugin suggests X" for "I chose X".

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

#### Manual QA — the second one-time question

Immediately after the validation-mode answer (same sitting, same tool), ask
once more for the whole story:

```
Ask the human (OpenCode `question`, Claude Code `AskUserQuestion`):
  question: "Should /workflow-dev:validate run a manual QA pass (a real
    browser / device against the running app) before commit for this story?"
  header: "Manual QA"
  options:
    - label: "Yes — run it"
      description: "On validate's PASS path, exercise the app in a real
        browser/emulator and check each Acceptance Criterion. Costs tokens."
    - label: "No — skip for this story"
      description: "Validate stays pure static analysis; no browser/device pass."
```

This is a plain **Yes/No** — it does not carry its own timing. When QA runs,
it follows the validation mode decided just above: "once, at the end" → QA
runs on the single end-of-story validate; "after every task group" → QA runs
on each PASS. (A change with no UI/mobile surface, or any the human doesn't
want browser-verified, is a normal "No".)

**Unattended/non-interactive:** skip the tool call and default to
**"No — skip"** silently — manual QA is the expensive, opt-in pass, so the
safe default with no one to answer is not to run it.

Record alongside the validation-mode row:

```markdown
| YYYY-MM-DD | Manual QA for this story: <"yes" | "no"> | Human |
```

`/workflow-dev:validate` reads this on its PASS path (its Step 7): "yes" runs
`../manual-qa/SKILL.md`; "no" (or no row) skips it. It never re-asks.

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

Then record the plan checkpoint (WD-0037):
`"$PLUGIN_ROOT"/scripts/session-usage.sh --snapshot [STORY-ID] --stage plan`,
and show the line it prints (this step's spend and the story's running total).
`PLUGIN_ROOT` resolves as elsewhere in this plugin (`${CLAUDE_PLUGIN_ROOT}` on
Claude Code; `cd -P "<this skill's directory>/../.." && pwd -P` on OpenCode).

## Principles

1. **Validation-aware** — every task group is designed to pass `/workflow-dev:validate`. If a task would introduce security issues, missing tests, or broken types, the plan accounts for it.
2. **Execution-aware** — tasks are written knowing the agent will execute them with human-in-the-loop, zero-inference, and scope discipline.
3. **Minimal** — don't over-decompose. A fix that takes 3 tasks doesn't need 3 task groups. Group related changes.
4. **Specific** — each task names the file and the change. "Update handler" is bad. "Add a pagination loop to fetchInvoices in src/billing/invoice-client.ts" is good.
5. **Ordered by dependency** — if Task B needs Task A's output, A comes first.
6. **Tests are explicit** — never assume tests will "just happen." Make them a task or a task group.
7. **Commit boundaries** — each task group = one potential commit. Don't mix unrelated changes.
8. **Validation mode and manual QA are decided once, up front** — both asked together right after plan approval (Step 5), never per task group, never re-asked, and never silently defaulted without asking (except when genuinely unattended). `/workflow-dev:implement` reads the validation mode; `/workflow-dev:validate` reads the manual-QA choice; neither decides its own.
