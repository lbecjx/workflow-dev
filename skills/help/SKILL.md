---
name: help
description: Shows workflow status, available skills, and next steps based on current project state. Use when the user says "help", "what skills are there", or needs guidance on the workflow.
---

<!--
workflow-dev — a persistent-context development workflow for Claude Code
Copyright (C) 2026  lbecjx

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version. See LICENSE for the full text.
-->

# Help

Detects current project state and suggests the next step. Shows available skills and the overall workflow.

## Execution

### Step 1: Detect project state

Check for `.workflow-dev/context/` in the current project:

1. **No `.workflow-dev/context/` directory** → "No persistent context yet. Run `/workflow-dev:init <STORY-ID>` to start."
2. **REPO.md exists but no story files** → "Repo context loaded. Run `/workflow-dev:init <STORY-ID>` to start a story."
3. **Story file exists, no Plan section** → "Story loaded. Run `/workflow-dev:plan` to decompose it, or direct the work step by step."
4. **Story file has a Plan with task groups Not Started** → "Plan ready. Run `/workflow-dev:implement`, or direct it manually."
5. **Story file has a Plan with task groups In Progress** → "Work in progress. Run `/workflow-dev:implement` to continue, or `/workflow-dev:validate` to check the current state."
6. **Every task group Done** → "Implementation complete. Ready for commit/PR."

### Step 2: Show status and suggestions

```
Status

Context:  .workflow-dev/context/REPO.md ✅
Story:    PROJ-14000 — Fix Airtable pagination
Plan:     3 task groups (2 done, 1 in progress)
Progress: 75%

Next: /workflow-dev:implement to continue Task Group 3,
      or /workflow-dev:validate to check what you have so far.

Available skills:
  /workflow-dev:init      — Start a new story (extracts from Jira/Confluence/repo/local .md)
  /workflow-dev:plan      — Decompose a story into task groups
  /workflow-dev:implement — Execute the next task group under the quality rules
  /workflow-dev:validate  — Run the quality gate on uncommitted changes
  /workflow-dev:save      — Persist discoveries and progress
  /workflow-dev:resume    — Load context at the start of a new session
  /workflow-dev:help      — This screen
```

---

## Workflow diagram

```
┌────────────────────────────────────────────────────────┐
│  /workflow-dev:init <STORY-ID>                          │
│  Extract context from Jira + Confluence + repo          │
│  Creates: .workflow-dev/context/REPO.md + [STORY-ID].md  │
└─────────────────────┬────────────────────────────────────┘
                       │
                       ▼ (optional, for complex stories)
┌────────────────────────────────────────────────────────┐
│  /workflow-dev:plan                                      │
│  Decompose ACs into task groups, validation-aware        │
│  Writes: Plan section in [STORY-ID].md                   │
└─────────────────────┬────────────────────────────────────┘
                       │
                       ▼ (repeat per task group)
┌────────────────────────────────────────────────────────┐
│  /workflow-dev:implement                                 │
│  Execute tasks under the coding rules                    │
│  Human-in-the-loop after each task                        │
└─────────────────────┬────────────────────────────────────┘
                       │
                       ▼ (after each task group)
┌────────────────────────────────────────────────────────┐
│  /workflow-dev:validate                                   │
│  Quality gate: security, types, tests, code quality       │
│  PASS → commit    FAIL → fix → re-validate                │
└─────────────────────┬────────────────────────────────────┘
                       │
                       ▼ (anytime during work)
┌────────────────────────────────────────────────────────┐
│  /workflow-dev:save                                       │
│  Persist decisions, discoveries, progress                 │
│  Updates: REPO.md + [STORY-ID].md                          │
└────────────────────────────────────────────────────────┘

  /workflow-dev:resume — Load context at the start of a new session
  /workflow-dev:help   — Show this status + workflow
```

---

## Local work (no Jira)

This workflow doesn't require Jira — `init` accepts a path to any local Markdown file as a story source (see Phase 1-alt in `skills/init`). Point it at any `.md` file that has a title and Acceptance Criteria and it works exactly like a Jira ID would.

One way to produce such files without hand-writing them is the separate **`local-backlog`** plugin (auto-incrementing codes, a local viewer) — it's an independent plugin, not a dependency; install it separately if you want that workflow, and see its own `/local-backlog:help` for what it offers.

---

## When to use each skill

| Situation | Skill |
|-----------|-------|
| Starting a new story | `/workflow-dev:init` |
| Story is complex, needs structure | `/workflow-dev:plan` |
| Ready to code | `/workflow-dev:implement` (or direct it manually) |
| Done coding, want a quality check | `/workflow-dev:validate` |
| Want to save progress before a break or compaction | `/workflow-dev:save` |
| New session, picking up where you left off | `/workflow-dev:resume` |
| Not sure what's next | `/workflow-dev:help` |

## When not to reach for this workflow

- Quick questions ("what does this function do?")
- One-line fixes with an obvious path
- Reading/exploring code without modifying it
- Git operations (commit, push, PR)

This workflow exists for implementation work on stories. For everything else, just work normally.

---

## Key principles

| # | Principle |
|---|-----------|
| 1 | **Living context** — survives compaction and new sessions |
| 2 | **The human is the architect** — the agent executes, the human decides |
| 3 | **Validate before commit** — the quality gate is not optional |
| 4 | **Zero inference** — read the code or ask; never guess |
| 5 | **Scope discipline** — touch only what's needed |
| 6 | **Stack-agnostic rules, stack-specific knowledge** — universal standards plus what's been learned about this repo |
| 7 | **Lightweight for small work, structured for complex work** — the plan is optional; validation isn't |

---

## Adding stack knowledge

When you discover a pattern or standard for a specific technology, say:

```
"Save this as a [stack] standard"
```

It gets written to `skills/implement/references/stacks/[stack].md` and auto-loads for future projects on that stack.

Stacks currently documented:
- `react-typescript.md` — React + TypeScript component patterns, hooks, performance
- (add more as they're learned)
