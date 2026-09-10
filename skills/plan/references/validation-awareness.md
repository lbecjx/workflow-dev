<!--
workflow-dev — a persistent-context development workflow for Claude Code
Copyright (C) 2026  Luis Becjx

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version. See LICENSE for the full text.
-->

# Validation Awareness

The plan is written knowing that `/workflow-dev:validate` will be run after each task group. This means:

1. **Every task group must leave the codebase in a state that passes validation**
2. **The plan should not create work that will obviously fail validation**
3. **The plan should include tasks that MAKE validation pass (tests, type fixes, etc.)**

---

## What `/workflow-dev:validate` checks (summary)

| Dimension | What it looks for | Blocking? |
|-----------|-------------------|-----------|
| **Verification** | Build compiles, types pass, lint clean, tests pass | Yes (build/types/tests) |
| **Security** | No injection, no secrets in code, no data exposure | Yes |
| **Data Shape** | Type exhaustiveness, no key collisions, explicit nulls | Yes (if crashes at runtime) |
| **Code Quality** | No smells, follows conventions, type-safe | No (advisory) |
| **Testing** | New behavior has tests, tests are meaningful | No (advisory) |
| **Architecture** | Layer boundaries, dependency direction, coupling | No (advisory) |
| **Performance** | No N+1, no unbounded growth, resource cleanup | Rarely (only obvious incidents) |

---

## How this shapes the plan

### Security-aware tasks

If the task involves:
- User input → include validation/sanitization in the same task
- API keys/credentials → task says "read from env, not hardcoded"
- Error responses → task says "wrap in StructuredError, don't leak upstream body"
- New endpoints → task includes auth/authz consideration

### Type-safety-aware tasks

If the task introduces:
- New types/enums → include a task to handle them in all existing switch/case
- New nullable fields → include explicit null handling
- New interfaces → include type for return values (no implicit `any`)

### Test-aware tasks

For each task group that adds behavior:
- Include a test task in the SAME group, or
- Create a dedicated test task group that covers all new behavior
- Never leave a task group without test consideration

### Build-aware tasks

- Don't create tasks that reference files/modules that don't exist yet (unless an earlier task creates them)
- Don't create tasks that would break imports between task groups
- Each task group should compile independently after completion

---

## Anti-patterns to avoid in the plan

| Anti-pattern | Problem | Fix |
|-------------|---------|-----|
| "Add feature" without test task | Validation will WARN on missing tests | Add explicit test task |
| Task that introduces `any` or type escape | Validation will WARN on type safety | Task should specify the correct type |
| Task that hardcodes a value | Validation may flag as magic number/string | Task should specify constant extraction |
| Two task groups that break each other if committed alone | Validation will FAIL on builds/tests | Merge into one task group |
| Test task group at the end, far from implementation | Context lost, tests are afterthought | Tests alongside or immediately after |

---

## The contract

When an agent executes the plan:
1. Complete task group N
2. Run `/workflow-dev:validate`
3. If FAIL → fix issues within scope
4. If PASS (maybe with WARNs) → human decides to commit or fix warnings
5. Move to task group N+1

The plan is designed so that step 3 (fix issues) is RARE — because the plan already accounts for what validation checks.
