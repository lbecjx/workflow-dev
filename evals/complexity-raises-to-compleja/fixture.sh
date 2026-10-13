#!/bin/bash
# Scaffolds a scratch repo for the raise eval: an active story whose Decisions
# record `Complexity: moderada`, plus an uncommitted change that adds a write
# path (appending a line to a file on disk). A write path is one of §11.0's
# complete criteria, so validate must raise the story to `compleja` and run
# today's full flow instead of skipping the adversarial pass.
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
printf 'gitignored=true\ntiering=default\n' > .workflow-dev/config.env
printf '.workflow-dev/\nfixture.sh\n' > .gitignore

cat > .workflow-dev/context/REPO.md <<'MD'
# REPO.md — eval fixture

## 1. What this is
A throwaway repo. No stack, no build step, no test suite.
MD

cat > .workflow-dev/context/EVAL-0001.md <<'MD'
# EVAL-0001: record each visit
> Repo context: [REPO.md](./REPO.md)

## 1. Base Context

### 1.1 Story
**ID:** eval-fixture
**Status:** In Progress

**Acceptance Criteria:**
1. `recordVisit` appends one line per visit to the visits log.

## 2. Working Memory

### Decisions
| Date | Decision | Decided by |
|------|----------|------------|
| 2026-01-01 | Validation mode for this story: once at the end | Human |
| 2026-01-01 | Manual QA for this story: no | Human |
| 2026-01-01 | Complexity: moderada — a small helper | wd-judge |

## 3. Progress

### Implementation Status: In Progress
MD

cat > README.md <<'MD'
# Eval fixture

A throwaway repo used to check that a diff with a write path raises a `moderada` story.
MD

cat > visits.js <<'JS'
// Records a visit.
function recordVisit(page) {
  return page;
}

module.exports = { recordVisit };
JS

git add .gitignore README.md visits.js
git commit -q -m "chore: baseline"

# The diff under review — uncommitted on purpose. Adds a write path: every
# call appends to a file on disk.
cat > visits.js <<'JS'
const fs = require('fs');

// Records a visit by appending one line to the visits log.
function recordVisit(page, logPath = 'visits.log') {
  fs.appendFileSync(logPath, `${new Date().toISOString()} ${page}\n`);
  return page;
}

module.exports = { recordVisit };
JS

echo "fixture ready"
