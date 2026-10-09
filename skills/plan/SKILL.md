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

**Text shown to the user follows `references/user-language.md` (at the plugin root, not this skill's own `references/`)** — its language, wording, and length.

## When to use

- After `/workflow-dev:init` when the story is understood but work hasn't started
- When a story is complex enough that "next step" isn't enough guidance
- When the human says "plan", "make a plan", "break this down"

## When NOT to use

- Simple fixes (1-2 file changes, obvious path) — just do them
- When the human is already directing step-by-step — follow their lead

## Execution

### Step 1: Read context

0. Record this run's start (`references/run-cost.md` at the plugin root,
   `--stage plan --start`).
1. Read `.workflow-dev/context/[STORY-ID].md` — understand ACs, discoveries, decisions, scope
2. Read `.workflow-dev/context/REPO.md` — understand conventions, prohibitions, infra
3. Read `references/execution-principles.md` — internalize how tasks will be executed
4. Read `references/validation-awareness.md` — understand what the quality gate checks
5. Read `../implement/references/coding-standards.md` and `../implement/references/decision-points.md` — the rules every task group is implemented under, and where implementation must stop for a decision
6. Read the stack file `implement` would load for this project (`../implement/SKILL.md` Step 1, item 5 — e.g. `../implement/references/stacks/react-typescript.md`); none matches → skip it

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

**Execution class.** Give every task group one of two classes:

- `mechanical` — the change is fully specified: the file, the function, and the
  pattern to follow are named, and nothing is left to decide.
- `judgment` — the group still holds a decision, new logic, or wording to write.

The class is recorded with the group (Steps 4 and 6). It tells the human, and a
later per-group delegation of the implementation, which groups need judgment.

**Who drafts it.** The decomposition runs in a sub-agent under the
**`wd-architect`** role (`../setup-models/references/roles.md`) — name the role
as the sub-agent's type, never a model. Its brief carries the content inline,
never a command or a path for it to read on its own (the same rule as
`validate`'s Step 3 — a re-read is paid twice):

- the story file and REPO.md (Step 1);
- `references/execution-principles.md` and `references/validation-awareness.md`;
- `../implement/references/coding-standards.md`, `../implement/references/decision-points.md`,
  and the stack file from Step 1, when one applies — so each task group is
  planned under the rules it will be implemented under, and a group that will
  hit a decision point is classed `judgment`;
- the relevant source files Step 2 identified, or the parts of them that matter;
- the task this step defines: ordered task groups in Step 4's format, each with
  its execution class, and a line on anything the brief left unsettled.

The sub-agent never asks the human anything: presenting the plan, the approval
(Step 4), and the two one-time questions (Step 5) stay with you, the main agent,
exactly as in a plan you drafted yourself — and so does every autonomous-mode
rule below. Read its draft against the code you explored before you present it.

Two fallbacks, and each one is said, never hidden:

- The harness cannot select a model per sub-agent, or `wd-architect` is not
  bound — its `model-tiering-check.sh --role-models` state is anything other
  than `bound` → run the sub-agent on the default model and say so.
- The sub-agent fails, or returns no usable plan → draft the plan yourself and
  say so.

### Step 4: Present plan to human

Show the proposed plan clearly:

```
Plan — [STORY-ID]:

Task Group 1: <Title>  [mechanical | judgment]
- [ ] <specific task with file path>
- [ ] <specific task with file path>
Validates: AC #X

Task Group 2: <Title>  [mechanical | judgment]
- [ ] <specific task>
- [ ] <specific task>
Validates: AC #Y

Task Group 3: Tests  [mechanical | judgment]
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

In autonomous mode (`Autonomous mode: on` in the story's Decisions —
`references/autonomous-mode.md` at the plugin root), skip this ask: write the
plan to the story file, record `Plan approved (autonomous)` in the Decisions
table, and carry on. The plan is still written and still followed — only the
approval pause is removed, and the plan itself stays in the end-of-run report
for the human to review after the fact.

### Step 5: Choose validation mode and manual QA (once per story, never re-asked)

> **Gates for this step** — the two one-time questions below, asked here and
> never again for this story; a miss here is easy to overlook. Do them, don't
> just read them:
> - **Validation mode:** "once at the end" or "after every task group"? →
>   record it in the Decisions table; `implement` reads it, never re-asks.
> - **Manual QA:** "yes" or "no" for this story? → record it; `validate`
>   reads it, never re-asks.
> Unattended → both default silently (once at the end / no).

Autonomous mode (`Autonomous mode: on` in the story's Decisions —
`references/autonomous-mode.md` at the plugin root) counts as unattended for
both one-time questions below: skip the ask, take the defaults, and record them.
The two questions are still asked (and still recorded as decided by the Human)
in a human-piloted run; autonomous mode only removes the per-step ask, never the
recorded decision.

Once the plan is approved — before writing anything, and before
`/workflow-dev:implement` runs any task group — ask this exactly once for
the whole story:

```
Ask the human (ask-question tool):
  question: "The full quality check uses several sub-agents. Run it once at
    the end of the story, or after every task group?"
  header: "Validation mode"
  options:
    - label: "Once, at the end (recommended)"
      description: "Run the full check once and pay its cost once."
    - label: "After every task group"
      description: "Run the full check each time. Finds issues sooner."
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
Ask the human (ask-question tool):
  question: "When the quality check passes, also test this story in the
    running app, in a real browser or device?"
  header: "Manual QA"
  options:
    - label: "Yes — run it"
      description: "Check each criterion in the running app. Costs more."
    - label: "No — skip for this story"
      description: "Check the code only. No browser or device."
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
**Execution class:** <mechanical | judgment>
- [ ] <task>
- [ ] <task>
**Validates:** AC #X
**After completion:** `/workflow-dev:validate` → fix → commit

### Task Group 2: <Title>
**Execution class:** <mechanical | judgment>
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

In autonomous mode, don't suggest: run `/workflow-dev:implement` in the same
turn, right after this run's end checkpoint below (`references/autonomous-mode.md`
at the plugin root, "Chaining").

Then, as this run's last step, record its end and show its line
(`references/run-cost.md`, `--stage plan`): the approval and the two one-time
questions above are part of the run.

## Principles

1. **Validation-aware** — every task group is designed to pass `/workflow-dev:validate`. If a task would introduce security issues, missing tests, or broken types, the plan accounts for it.
2. **Execution-aware** — tasks are written knowing the agent will execute them with human-in-the-loop, zero-inference, and scope discipline.
3. **Minimal** — don't over-decompose. A fix that takes 3 tasks doesn't need 3 task groups. Group related changes.
4. **Specific** — each task names the file and the change. "Update handler" is bad. "Add a pagination loop to fetchInvoices in src/billing/invoice-client.ts" is good.
5. **Ordered by dependency** — if Task B needs Task A's output, A comes first.
6. **Tests are explicit** — never assume tests will "just happen." Make them a task or a task group.
7. **Commit boundaries** — each task group = one potential commit. Don't mix unrelated changes.
8. **Every task group carries its execution class** — `mechanical` or `judgment` (Step 3). Never leave it out: a later delegation of the implementation reads it.
9. **The drafting is delegated, the conversation is not** — a `wd-architect` sub-agent drafts the task groups from an inline brief; the main agent presents them, asks for approval, and asks Step 5's questions (Step 3).
10. **Validation mode and manual QA are decided once, up front** — both asked together right after plan approval (Step 5), never per task group, never re-asked, and never silently defaulted without asking (except when genuinely unattended). `/workflow-dev:implement` reads the validation mode; `/workflow-dev:validate` reads the manual-QA choice; neither decides its own.
