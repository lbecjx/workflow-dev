#!/bin/bash
# Scaffolds a scratch repo for the moderada eval: an active story whose
# Decisions record `Complexity: moderada`, plus a logic-bearing but low-risk
# uncommitted change (a pure function with edge cases, no write/concurrency/
# security surface). Without the level, §11.0 would suggest no-repro and ask.
# With `moderada`, validate must skip the adversarial pass and not ask.
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
# `fixture.sh` are ignored so the only change under review is the code below.
printf '{ "gitignored": true, "tiering": "default" }\n' > .workflow-dev/config.json
printf '.workflow-dev/\nfixture.sh\n' > .gitignore

cat > .workflow-dev/context/REPO.md <<'MD'
# REPO.md — eval fixture

## 1. What this is
A throwaway repo. No stack, no build step, no test suite.
MD

cat > .workflow-dev/context/EVAL-0001.md <<'MD'
# EVAL-0001: page window bounds
> Repo context: [REPO.md](./REPO.md)

## 1. Base Context

### 1.1 Story
**ID:** eval-fixture
**Status:** In Progress

**Acceptance Criteria:**
1. `pageWindow` returns empty bounds for a zero page size or an out-of-range page.

## 2. Working Memory

### Decisions
| Date | Decision | Decided by |
|------|----------|------------|
| 2026-01-01 | Validation mode for this story: once at the end | Human |
| 2026-01-01 | Manual QA for this story: no | Human |
| 2026-01-01 | Complexity: moderada — a pure function with edge cases; no write, concurrency or security surface | wd-judge |

## 3. Progress

### Implementation Status: In Progress
MD

cat > README.md <<'MD'
# Eval fixture

A throwaway repo used to check that a `moderada` story skips the adversarial pass.
MD

cat > page_window.js <<'JS'
// Returns the zero-based slice bounds [start, end) for one page of items.
function pageWindow(page, perPage, total) {
  return [0, Math.min(perPage, total)];
}

module.exports = { pageWindow };
JS

git add .gitignore README.md page_window.js
git commit -q -m "chore: baseline"

# The diff under review — uncommitted on purpose. Real logic, low risk.
cat > page_window.js <<'JS'
// Returns the zero-based slice bounds [start, end) for one page of items.
function pageWindow(page, perPage, total) {
  if (perPage <= 0) return [0, 0];
  const pages = Math.ceil(total / perPage);
  if (page < 1 || page > pages) return [0, 0];
  const start = (page - 1) * perPage;
  return [start, Math.min(start + perPage, total)];
}

module.exports = { pageWindow };
JS

echo "fixture ready"
