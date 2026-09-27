#!/bin/bash
# Scaffolds a scratch repo for the manual-QA wiring eval: an active story whose
# Working Memory records the manual-QA decision as "yes", plus a docs-only
# uncommitted change so /workflow-dev:validate reaches a PASS — and therefore
# its Step 7 (run manual-qa, then offer the next step).
set -e

git init -q
git config user.email "eval@example.com"
git config user.name "Eval Fixture"

mkdir -p .workflow-dev/context

cat > .workflow-dev/context/REPO.md <<'MD'
# REPO.md — eval fixture

## 1. What this is
A throwaway docs repo. No stack, no build step, no test suite — so
/workflow-dev:validate has nothing blocking to find on a docs-only change.
MD

cat > .workflow-dev/context/EVAL-0001.md <<'MD'
# EVAL-0001: docs tweak
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
| 2026-01-01 | Manual QA for this story: yes | Human |

## 3. Progress

### Implementation Status: In Progress
MD

cat > README.md <<'MD'
# Eval fixture

Baseline.
MD

git add README.md
git commit -q -m "chore: baseline"

# Uncommitted, docs-only change — makes validate's diff non-empty and low-risk
# (no build/tests to run; adversarial correctness SKIPs on a docs-only diff).
cat > README.md <<'MD'
# Eval fixture

Baseline.

Use the `--new-flag` flag.
MD

echo "fixture ready"
