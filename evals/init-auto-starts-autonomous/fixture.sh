#!/bin/bash
# Scaffolds a scratch repo for the init-auto eval: a backlog story to init
# (with the local-backlog marker, so init's ECOSYSTEM hand-off fires), an
# existing REPO.md, and a default model chosen for the repo.
#
# REPO.md is pre-written with its Good Practices and Prohibitions sections so
# init takes its "already exists" short path and spawns no research sub-agents.
# The repo default (`"tiering": "default"`) keeps the tiering question out of
# the run: that one question is required even in autonomous mode, so leaving
# tiering unset would make "no questions" impossible for a reason this case is
# not about. Both live in the scratch repo; nothing touches the real $HOME.
set -e

git init -q
git config user.email "eval@example.com"
git config user.name "Eval Fixture"

mkdir -p .workflow-dev/context local-backlog

# Phase 0 already answered. `fixture.sh` is ignored so the tree is clean.
printf '{ "gitignored": true, "tiering": "default" }\n' > .workflow-dev/config.json
printf '.workflow-dev/\nfixture.sh\n' > .gitignore

printf '{ "prefix": "EVAL" }\n' > local-backlog/.backlog-config.json

cat > .workflow-dev/context/REPO.md <<'MD'
# REPO.md — eval fixture

## 1. What this is
A throwaway repo with no stack, no build step and no test suite.

## 2. Stack
Nothing to enumerate.

## 3. Project structure
A backlog folder with one story and a `notes.txt` file.

## 4. Relevant files
| File | Purpose |
|---|---|
| `notes.txt` | The one file the story changes |

## 5. Good Practices
Nothing stack-specific to record.

## 6. Prohibitions
Nothing repo-specific to record.
MD

printf 'first line\n' > notes.txt

cat > local-backlog/EVAL-0004-init-auto.md <<'MD'
# EVAL-0004 · Add a second line to notes.txt

| Field | Value |
|---|---|
| **Code** | EVAL-0004 |
| **Status** | Not Started |
| **Zone** | Backlog |

## Description

A story small enough to plan and implement in a few turns, used to exercise
`/workflow-dev:init-auto`.

## Acceptance Criteria

1. `notes.txt` has a second line that reads `second line`.

## History

- 2026-10-08T00:00:00Z — Created (Status: Not Started)
MD

git add .gitignore notes.txt local-backlog
git commit -q -m "chore: baseline"

echo "fixture ready"
