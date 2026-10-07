---
name: help
description: Shows workflow status, available skills, and next steps based on current project state. Use when the user says "help", "what skills are there", or needs guidance on the workflow.
---

<!--
workflow-dev — a persistent-context development workflow for Claude Code and OpenCode
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
6. **Every task group Done** → never report "nothing left to do" while the validate/manual-QA step is still ahead. Always point at `/workflow-dev:validate`, and tailor the manual-QA clause from the story's Working Memory → Decisions **"Manual QA for this story"** row:

   - **"yes"** → "Implementation complete. Next: `/workflow-dev:validate` — it runs a manual-QA pass (this story opted in) before the commit/PR step."
   - **"no", or no row** → "Implementation complete. Next: `/workflow-dev:validate` — it skips manual QA unless you ask; then the commit/PR step."

7. **On OpenCode, also check the plugin is running** — the reminders and the
   tool-catalog notice come from `opencode/plugin.ts`, and a plugin that failed
   to load in OpenCode's background service leaves only a warning in a log:

   ```sh
   PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd -P "<this skill's directory>/../.." && pwd -P)}"
   if [ "$("$PLUGIN_ROOT"/scripts/list-models.sh --print-harness)" = opencode ]; then
     "$PLUGIN_ROOT"/scripts/opencode-live-check.sh --message
   fi
   ```

   Silent when it is live, and on Claude Code (nothing to check there). If it
   prints, show that text first in Step 2, as it stands — it names the fix.

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
  /workflow-dev:init              — Start a new story (extracts from Jira/Confluence/GitHub/repo/local .md)
  /workflow-dev:plan              — Decompose a story into task groups
  /workflow-dev:implement         — Execute the next task group under the quality rules
  /workflow-dev:validate          — Run the quality gate on uncommitted changes
  /workflow-dev:manual-qa         — Verify ACs in a real browser/device (run by validate when opted in)
  /workflow-dev:summarize-changes — Draft and review the commit message / PR text
  /workflow-dev:save              — Persist discoveries and progress
  /workflow-dev:resume            — Load context at the start of a new session
  /workflow-dev:refresh           — Check Jira/Confluence/GitHub/the repo for drift since the last save
  /workflow-dev:setup-models      — Bind each agent role to a model the harness offers (one-time)
  /workflow-dev:usage             — Show the active story's total cost and tokens (from its ledger)
  /workflow-dev:help              — This screen
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
│  PASS → (optional manual QA) → commit                     │
│  FAIL → fix → re-validate                                 │
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

## Local work (no external tracker)

This workflow doesn't require a cloud-based issue tracker — `init` accepts a path to any local Markdown file as a story source (see Phase 1-alt in `skills/init`). Point it at any `.md` file that has a title and Acceptance Criteria and it works exactly like passing an external tracker's issue ID would.

One way to produce such files without hand-writing them is the separate **`local-backlog`** plugin (auto-incrementing codes, a local viewer) — it's an independent plugin, not a dependency; install it separately if you want that workflow, and see its own `/local-backlog:help` for what it offers.

---

## When to use each skill

| Situation | Skill |
|-----------|-------|
| Starting a new story | `/workflow-dev:init` |
| Story is complex, needs structure | `/workflow-dev:plan` |
| Ready to code | `/workflow-dev:implement` (or direct it manually) |
| Done coding, want a quality check | `/workflow-dev:validate` |
| Want UI/mobile work verified in a real browser/device | `/workflow-dev:validate` can run a manual-QA pass (the `manual-qa` skill) |
| Ready to commit or open a PR | `/workflow-dev:summarize-changes` |
| Want to save progress before a break or compaction | `/workflow-dev:save` |
| New session, picking up where you left off | `/workflow-dev:resume` |
| Wondering if Jira/Confluence/GitHub/the repo drifted since the last save | `/workflow-dev:refresh` |
| Want sub-agent work tiered — mechanical on a fast model, judgment on a strong one | `/workflow-dev:setup-models` |
| Want to see what the active story has cost so far | `/workflow-dev:usage` |
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
| 3 | **Validate before commit** — the quality gate is not optional; the manual-QA pass it can run is opt-in |
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
