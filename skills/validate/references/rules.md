<!--
workflow-dev — a persistent-context development workflow for Claude Code
Copyright (C) 2026  lbecjx

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version. See LICENSE for the full text.
-->

# Validation Rules — Universal Dimensions

These rules are language- and stack-agnostic; they apply to any codebase. Each dimension is checked independently by a sub-agent that receives the list of changed files and reads them directly.

---

## Part 1: Scope Compliance

- [ ] Only files relevant to the current task were modified
- [ ] No unrelated changes mixed in (refactors, style fixes, unrelated features)
- [ ] If a story/task context exists (.workflow-dev/context/*.md), changes align with stated scope

**Verdict:** WARN if unrelated files touched. Never blocks.

---

## Part 2: Security

### 2.1 Injection & Input Handling

- [ ] No string concatenation/interpolation for queries (SQL, NoSQL, GraphQL, shell commands)
- [ ] No unsanitized user input in URLs, paths, headers, or templates
- [ ] No eval(), Function(), or dynamic code execution with external input
- [ ] No deserialization of untrusted data without validation

### 2.2 Secrets & Credentials

- [ ] No API keys, tokens, passwords, or connection strings in code
- [ ] No hardcoded credentials (even "temporary" or "test" ones in non-test files)
- [ ] No internal URLs, IPs, or infrastructure details exposed in client-facing code
- [ ] Environment variables or secret managers used for all sensitive values

### 2.3 Data Exposure

- [ ] No raw upstream error bodies returned to clients (wrap in structured errors)
- [ ] No PII logged or exposed in error messages
- [ ] No overly permissive CORS, auth bypass, or disabled security checks
- [ ] Response bodies don't leak internal structure (field names, stack traces, IDs)

**Verdict:** FAIL if any 2.x check fails. Security is always blocking.

---

## Part 3: Data Shape Integrity

- [ ] New types/enums/variants handled exhaustively in all switch/case/match statements
- [ ] Cache keys, dedup keys, unique identifiers remain unique with new data shapes
- [ ] No silent type coercion that could produce incorrect comparisons
- [ ] Default/fallback values are distinguishable from valid data (not empty string for "missing")

**Verdict:** FAIL if exhaustiveness broken (will crash at runtime). WARN otherwise.

---

## Part 4: Code Quality

### 4.1 Smells

- [ ] No duplicated logic (same block in 3+ places without extraction)
- [ ] Functions focused and reasonably sized (guideline: <50 lines)
- [ ] No excessive nesting (guideline: max 4 levels)
- [ ] No magic numbers/strings without context (named constants preferred)
- [ ] No dead code (commented-out blocks, unreachable branches, unused imports)
- [ ] No overly complex functions (too many responsibilities, too many params)

### 4.2 Conventions

- [ ] Follows existing project naming conventions (file names, variables, types)
- [ ] Follows existing project patterns (error handling, logging, dependency injection)
- [ ] Imports follow project style (relative vs absolute, ordering)
- [ ] Error handling appropriate — not excessive (defensive against impossible cases) and not missing (ignoring failures)

### 4.3 Type Safety (typed languages)

- [ ] No type escape hatches (any, as, !, unsafe) without clear justification
- [ ] Null/nil/undefined handled explicitly at boundaries
- [ ] Generic types used correctly (not over-abstracted, not under-constrained)

**Verdict:** WARN for smells and conventions. Never blocks alone.

---

## Part 5: Testing

### 5.1 Coverage of Changes

- [ ] New functions/methods have at least one test exercising the happy path
- [ ] New error paths have at least one test proving the error is handled
- [ ] Behavioral changes to existing code have tests updated or added
- [ ] Edge cases considered: null/empty input, boundary values, concurrent access

### 5.2 Test Quality

- [ ] Each test has at least one meaningful assertion (not just "doesn't throw")
- [ ] Tests verify outcomes, not implementation details (not just "mock was called")
- [ ] Tests are isolated — no dependency on execution order or shared mutable state
- [ ] Test names describe the scenario being verified
- [ ] No copy-paste from production logic into expected values (independently computed)

### 5.3 What NOT to require

- Do NOT require tests for trivial getters/setters, type definitions, or pure config
- Do NOT require 100% coverage — focus on behavior that matters
- Do NOT flag missing tests for code that's already tested at a higher level (integration)

**Verdict:** WARN if new behavior lacks tests. FAIL only if existing tests now fail.

---

## Part 6: Verification Commands

Run whatever the project provides. Map to these categories:

| Category | What it proves | Blocking? |
|----------|---------------|-----------|
| Build | Code compiles/bundles without errors | FAIL |
| Type check | Static types are consistent | FAIL |
| Lint | Style and lint rules pass | WARN |
| Format | Code is formatted per project standard | WARN |
| Tests | All tests pass, no regressions | FAIL |

**If a command is not available** (can't be discovered), note it as "skipped" — don't fail.

**Pre-existing failures:** If a command fails on code NOT in the changed files, note it but don't block. Only NEW failures in changed code block.

---

## Part 7: CI/CD Anticipation

Think about what CI will check after push:

- [ ] No new lint warnings that CI treats as errors
- [ ] No decrease in coverage on changed files (if CI enforces)
- [ ] Commit message follows project convention (if enforced)
- [ ] No files that should be gitignored (build artifacts, .env, node_modules, etc.)

**Verdict:** WARN. Anticipation is advisory — CI is the source of truth.

---

## Part 8: Architecture

- [ ] Changes respect existing layer boundaries (don't mix concerns)
- [ ] Dependencies flow in the correct direction (no circular, no reaching up layers)
- [ ] New abstractions are justified (not premature, not over-engineered)
- [ ] No tight coupling introduced (changes in file A shouldn't force changes in file B without reason)

**Verdict:** WARN. Architecture is judgment, not binary.

---

## Part 9: Performance

- [ ] No queries/API calls inside loops without batching consideration
- [ ] No unbounded growth patterns (arrays/maps that grow without limits)
- [ ] No blocking operations in hot paths (sync I/O, heavy computation in request handlers)
- [ ] Resource cleanup in place (connections closed, listeners removed, timers cleared)

**Verdict:** WARN unless it's clearly a production incident waiting to happen (e.g., N+1 in a loop processing thousands of items) → FAIL.

---

## Part 10: Context Hygiene

Applies only when `.workflow-dev/config.json` exists in the project.

- [ ] Read `gitignored` from `.workflow-dev/config.json`.
- [ ] If `true`: `.workflow-dev/` must actually be excluded via `.gitignore`, and `git status` must show nothing under it as staged or tracked.
- [ ] If `false`: `.workflow-dev/` must actually be tracked — not silently excluded by an unrelated `.gitignore` pattern (e.g. a broad `*.local` or `context/` rule shadowing it).

**Verdict:** FAIL if the declared preference and the actual git state disagree — this is silent, easy-to-miss drift (someone hand-edits `.gitignore`, or a broad ignore rule shadows the folder) that a human won't notice until content quietly stops syncing.

---

## Severity Guide

| Severity | Meaning | Blocks commit? |
|----------|---------|----------------|
| FAIL | Will break production, expose vulnerabilities, or crash at runtime | Yes |
| WARN | Degrades quality, maintainability, or performance. Might bite later. | No (human decides) |
| SKIP | Dimension couldn't be checked (missing command, no test runner found) | No |

**Overall verdict:**
- Any FAIL → Overall FAIL
- Only WARN/PASS/SKIP → Overall PASS (with warnings listed)
