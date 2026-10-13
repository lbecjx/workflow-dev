#!/bin/bash
# Scaffolds a scratch repo for the simple eval: an active story whose Decisions
# record `Complexity: simple` with an empty pick-list (`none`), plus a
# documentation-only uncommitted change. Without a level, a docs-only diff runs
# the reduced set and Security is SKIP (reduced-set-on-docs-only). With
# `simple`, Security must still run.
#
# The change modifies a *tracked* file so it is inside validate's single-diff
# scope (`git diff --name-only` lists tracked modifications, not untracked files).
set -e

git init -q
git config user.email "eval@example.com"
git config user.name "Eval Fixture"

mkdir -p .workflow-dev/context

# The repo default (`"tiering": "default"`) keeps the model-tiering question out
# of the run, a question this case is not about. `.workflow-dev/` and
# `fixture.sh` are ignored so the only change under review is the README below.
printf 'gitignored=true\ntiering=default\n' > .workflow-dev/config.env
printf '.workflow-dev/\nfixture.sh\n' > .gitignore

cat > .workflow-dev/context/REPO.md <<'MD'
# REPO.md — eval fixture

## 1. What this is
A throwaway docs repo. No stack, no build step, no test suite.
MD

cat > .workflow-dev/context/EVAL-0001.md <<'MD'
# EVAL-0001: document the new flag
> Repo context: [REPO.md](./REPO.md)

## 1. Base Context

### 1.1 Story
**ID:** eval-fixture
**Status:** In Progress

**Acceptance Criteria:**
1. The README mentions the new `--new-flag` flag.

## 2. Working Memory

### Decisions
| Date | Decision | Decided by |
|------|----------|------------|
| 2026-01-01 | Validation mode for this story: once at the end | Human |
| 2026-01-01 | Manual QA for this story: no | Human |
| 2026-01-01 | Complexity: simple — one README sentence; no code, no security surface | wd-judge |
| 2026-01-01 | Validations for simple: none | wd-judge |

## 3. Progress

### Implementation Status: In Progress

## 5. Plan

### Task Group 1: Document the flag
**Validates:** AC #1

### Plan Progress
| # | Task Group | Status |
|---|-----------|--------|
| 1 | Document the flag | In Progress |
MD

cat > README.md <<'MD'
# Eval fixture

Baseline.
MD

git add .gitignore README.md
git commit -q -m "chore: baseline"

# The diff under review — uncommitted on purpose. Documentation only.
cat > README.md <<'MD'
# Eval fixture

Baseline.

Use the `--new-flag` flag.
MD

echo "fixture ready"
