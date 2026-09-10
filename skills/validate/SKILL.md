---
name: validate
description: Runs a multi-dimensional quality gate on uncommitted changes before commit. Use when the user says "validate", "check quality", or before suggesting a commit.
---

<!--
workflow-dev — a persistent-context development workflow for Claude Code
Copyright (C) 2026  Luis Becerra

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version. See LICENSE for the full text.
-->

# Validate

Runs a structured quality gate over the current uncommitted changes, using parallel sub-agents to check independent dimensions, and reports pass/fail per dimension with actionable findings.

**Read `references/rules.md` for the full set of validation dimensions before executing.**

## When to use

- Before committing (the user says "validate," "are we ready?")
- After finishing a chunk of implementation work
- Whenever the human wants confidence the changes are solid

## What this does not do

- Doesn't commit or push
- Doesn't auto-fix issues — it reports them and leaves the call to the human
- Doesn't validate business logic — that's manual testing / AC verification

## Execution

### Step 1: Discover project context

Determine the available verification commands:

1. Check `.workflow-dev/context/REPO.md` for documented test/lint/typecheck/build commands.
2. Absent that, infer from manifest files:
   - `package.json` → scripts (test, lint, typecheck, build)
   - `Makefile` → targets
   - `go.mod` + a `golangci-lint` config → `go vet`, `go test`, lint
   - `pyproject.toml` → pytest, ruff, mypy
   - `Cargo.toml` → `cargo test`, `cargo clippy`
3. Infer the test runner from lockfiles, configs, or source patterns.

Build a command map: `{ build: "...", typecheck: "...", lint: "...", format: "...", test: "..." }`. Any command that can't be discovered is skipped, not failed — note it in the report.

### Step 2: Determine scope

`git diff --name-only` (staged + unstaged) defines the validation scope. Only these files are judged — pre-existing issues elsewhere are out of scope, not failures.

### Step 3: Run validation dimensions in parallel

Spawn one independent sub-agent per dimension. Each receives the changed-file list and the relevant section of `references/rules.md`, and reports findings as a structured list (file, line, issue, severity).

| Sub-agent | Dimensions (from rules.md) |
|-----------|-----------------------------|
| **Verification** | Run the discovered commands (build, typecheck, lint, test); report failures. |
| **Security** | Parts 2–3. Read the changed files for vulnerabilities. |
| **Code quality** | Part 4. Smells, conventions, patterns. |
| **Testing** | Part 5. Coverage of changes, test quality. |
| **Architecture** | Parts 8–9. Separation of concerns, coupling, performance. |
| **Context hygiene** | Part 10. `.workflow-dev/` state matches `.workflow-dev/config.json`. |

### Step 4: Collect and present results

Once every sub-agent returns, present a unified report:

```
Validation Results:

| Dimension        | Result | Findings |
|-------------------|--------|----------|
| Verification      | PASS   | 0        |
| Security          | PASS   | 0        |
| Code Quality       | WARN   | 2        |
| Testing           | PASS   | 0        |
| Architecture      | PASS   | 0        |
| Context Hygiene    | PASS   | 0        |

Overall: PASS (2 warnings)

Warnings:
1. src/foo.ts:45 — function exceeds 50 lines (62 lines)
2. src/foo.ts:12 — magic number 1000 could be a named constant

Ready to commit.
```

### Step 5: Verdict

| Overall | Meaning |
|---------|---------|
| **PASS** | Every dimension passes. Safe to commit. |
| **PASS (N warnings)** | Non-blocking issues found. The human decides whether to fix them first. |
| **FAIL** | Blocking issues found — security, a broken build/tests, type errors. Must be fixed before committing. |

Blocking: security vulnerabilities, build failures, type errors, test failures, or `.workflow-dev/` git-tracking drift (Part 10).
Non-blocking: code smells, missing edge-case tests, style issues.

### Step 6: Record the validated diff (only on PASS)

On PASS (with or without warnings), write a marker so a later commit attempt can tell these exact changes were already validated, without asking again:

```bash
REPO_HASH=$(git rev-parse --show-toplevel | tr -d '\n' | shasum | cut -c1-12)
MARKER_DIR="${TMPDIR:-/tmp}/workflow-dev-validate"
mkdir -p "$MARKER_DIR"
DIFF_HASH=$(
  { git diff -- . ':!.workflow-dev'; git status --porcelain -- . ':!.workflow-dev'; } | shasum | cut -d' ' -f1
)
printf '{"diffHash":"%s","validatedAt":"%s"}' "$DIFF_HASH" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$MARKER_DIR/$REPO_HASH.json"
```

`.workflow-dev/` is excluded from the hash on purpose — a later `/workflow-dev:save` writing to the story file must never invalidate a validation that already passed on the actual code changes. Only `diffHash` matters for comparison; `validatedAt` is display-only metadata, never part of what gets hashed. This file is pure ephemeral machine state — it lives outside the repo, is never committed, and is safe to lose (worst case, the next commit attempt just doesn't find a match and asks the human to confirm validation happened).

## Principles

- **Stack-agnostic rules** — the dimensions are universal; only the verification commands are project-specific.
- **Scope-limited** — judge changed files only; don't surface pre-existing issues.
- **Parallel** — sub-agents run independently for speed.
- **Actionable** — every finding names a file, a line, and states the problem plainly.
- **Non-blocking by default** — only security, broken builds/tests, and context-hygiene drift block. Everything else is advisory.
- **Discoverable** — a command that can't be found is skipped gracefully, not treated as a failure.
