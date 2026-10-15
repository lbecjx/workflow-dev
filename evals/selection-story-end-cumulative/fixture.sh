#!/bin/bash
# Scaffolds a scratch repo for the story-end eval: a story in "after every task
# group" mode whose first task group is already committed on the story branch
# and whose last one is uncommitted. Validate must judge the story's cumulative
# diff since `main` (docs/setup.md and docs/usage.md), not only the last group's.
# Both changes are documentation, to keep the pass cheap.
set -e

git init -q -b main
git config user.email "eval@example.com"
git config user.name "Eval Fixture"

# The setup answers the configuration interceptor (config-check.sh) would
# otherwise ask before /workflow-dev:validate; this case is not about them.
# `.git/info/exclude` keeps the folder out of the diff without a tracked change.
mkdir -p .workflow-dev/context docs
printf 'gitignored=true\ntiering=default\nagentCoauthorship=no\n' > .workflow-dev/config.env
printf '.workflow-dev/\n' >> .git/info/exclude

cat > .workflow-dev/context/REPO.md <<'MD'
# REPO.md — eval fixture

## 1. What this is
A throwaway docs repo. No stack, no build step, no test suite. Pull requests
target `main`.
MD

cat > .workflow-dev/context/EVAL-0002.md <<'MD'
# EVAL-0002: document setup and usage
> Repo context: [REPO.md](./REPO.md)

## 1. Base Context

### 1.1 Story
**ID:** eval-fixture
**Status:** In Progress

**Acceptance Criteria:**
1. docs/setup.md explains how to install the tool.
2. docs/usage.md explains how to run it.

## 2. Working Memory

### Decisions
| Date | Decision | Decided by |
|------|----------|------------|
| 2026-01-01 | Validation mode for this story: after every task group | Human |
| 2026-01-01 | Manual QA for this story: no | Human |

## 3. Progress

### Implementation Status: In Progress

## 5. Plan

### Task Group 1: Document setup
**Validates:** AC #1

### Task Group 2: Document usage
**Validates:** AC #2

### Plan Progress
| # | Task Group | Status |
|---|-----------|--------|
| 1 | Document setup | Done |
| 2 | Document usage | In Progress |
MD

printf '# Setup\n\nTBD.\n' > docs/setup.md
printf '# Usage\n\nTBD.\n' > docs/usage.md
git add docs
git commit -q -m "chore: baseline"

git checkout -q -b eval-0002-docs

# Task Group 1 — committed on the story branch.
printf '# Setup\n\nInstall the tool with `npm install -g example-tool`.\n' > docs/setup.md
git commit -q -am "Document setup"

# Task Group 2 — the last one, uncommitted on purpose.
printf '# Usage\n\nRun `example-tool --help` to list the commands.\n' > docs/usage.md

echo "fixture ready"
