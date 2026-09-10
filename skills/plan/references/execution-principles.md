<!--
workflow-dev — a persistent-context development workflow for Claude Code
Copyright (C) 2026  Luis Becjx

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version. See LICENSE for the full text.
-->

# Execution Principles

When a task group from the plan is being implemented, these principles govern how the agent works. The plan should be written WITH these in mind — don't create tasks that violate these principles.

---

## Human-in-the-Loop

- After each task: explain what changed and why, then wait for confirmation
- Before non-obvious decisions: present options, let the human choose
- If something doesn't match the plan: STOP, explain, ask how to proceed
- Never batch multiple tasks silently — each one gets visibility

**Plan implication:** Tasks should be small enough that explaining them takes 2-3 sentences. If a task needs a paragraph to explain, split it.

---

## Zero-Inference

- Don't assume naming conventions — read existing code
- Don't assume error handling strategy — match existing patterns
- Don't assume data shapes or types — read actual interfaces
- Don't assume business logic — ask
- Don't assume the plan is still correct — verify against codebase before executing

**Plan implication:** Tasks should reference specific files/functions/patterns to follow. "Do it like X" is better than "implement this" when there's a pattern to follow.

---

## Scope Discipline

- Only modify files relevant to the current task group
- Don't "fix" unrelated issues noticed along the way
- Don't refactor code that works (unless the task explicitly says to)
- Don't add features beyond what the AC requires
- If something MUST be fixed outside scope: inform the human, don't silently fix

**Plan implication:** Each task group should list which files it touches. If two task groups touch the same file, make the dependency explicit.

---

## Minimal Correct Changes

- Write the minimum code that satisfies the requirement
- Follow existing patterns — don't introduce new abstractions unless justified
- Prefer explicit over clever
- No premature optimization
- No "while I'm here" changes

**Plan implication:** Tasks describe the WHAT and WHERE, not a detailed HOW. The implementing agent reads the code and chooses the approach that fits existing patterns.

---

## Fail Fast, Communicate

- If a task can't be completed as written: STOP immediately
- If the codebase contradicts the plan: STOP, explain the contradiction
- If a dependency is missing: STOP, don't work around it silently
- Never produce partial/broken implementations to "move forward"

**Plan implication:** Task groups should have explicit dependencies. If Task Group 2 depends on Task Group 1, say so. Don't create tasks that assume prior tasks succeeded without checking.

---

## Commit Boundaries

- Each task group = one atomic commit
- A commit should leave the codebase in a working state (builds, tests pass)
- Don't mix feature code and test code in the same task group unless they're inseparable
- The commit message should be derivable from the task group title

**Plan implication:** Every task group should be independently committable. If removing Task Group 2's commit would break the code, then 1 and 2 should be one group.
