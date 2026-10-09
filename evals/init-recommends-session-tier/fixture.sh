#!/bin/bash
# Scaffolds a scratch repo for the init session-tier eval (WD-0050): a minimal
# story to init, an existing REPO.md, and a default model chosen for the repo.
#
# REPO.md is pre-written with its Good Practices and Prohibitions sections, so
# init's repo-level step takes its "already exists" short path and spawns none
# of the research sub-agents — a bounded, deterministic run.
#
# The repo default (`"tiering": "default"`) is what makes the recommendation
# deterministic: with it, none of `wd-architect`, `wd-judge` and `wd-adversary`
# is bound, so init must recommend the top tier. A bound-and-current state would
# need real files under ~/.claude/agents/, and evals run as the user with no
# HOME isolation — that fixture would overwrite a real user's bindings. The
# repo default lives entirely in the scratch repo.
set -e

git init -q
git config user.email "eval@example.com"
git config user.name "Eval Fixture"

mkdir -p .workflow-dev/context

# Phase 0 already answered, so init asks nothing about tracking the folder.
# `fixture.sh` is ignored too: the scaffold harness's own file isn't part of the
# repo under test, and leaving it untracked would make init's repo check report a
# dirty tree — noise the case isn't about.
printf '{ "gitignored": true }\n' > .workflow-dev/config.json
printf '.workflow-dev/\nfixture.sh\n' > .gitignore

cat > .workflow-dev/context/REPO.md <<'MD'
# REPO.md — eval fixture

## 1. What this is
A throwaway repo with no stack, no build step and no test suite. It exists so
that /workflow-dev:init has a repo-level context to verify instead of build.

## 2. Stack
Nothing to enumerate — no manifest, no dependencies, no scripts.

## 3. Project structure
A single story file and nothing else.

## 4. Relevant files
| File | Purpose |
|---|---|
| `eval-story.md` | The story this repo is init'd against |

## 5. Good Practices
Nothing stack-specific to record — there is no stack here.

## 6. Prohibitions
Nothing repo-specific to record.

Sections 5 and 6 exist even though they are empty on purpose: init's repo-level
step runs its three research sub-agents when REPO.md is *missing* these sections,
not only when the file is absent, so a REPO.md without them would send this
fixture straight into the expensive path it is meant to avoid.
MD

cat > eval-story.md <<'MD'
# EVAL-0003 · A throwaway story for the init session-tier eval

| Field | Value |
|---|---|
| **Status** | Not Started |

## Description

A story with no research behind it, used to exercise `/workflow-dev:init`'s
session-model tier notice. It touches no writes, no concurrency and no security
surface, so the only input to the recommendation is the role binding.

## Acceptance Criteria

1. The eval fixture's story file is read and summarized in the context init
   writes.
MD

git add .gitignore eval-story.md
git commit -q -m "chore: baseline"

mkdir -p .workflow-dev
printf '{ "gitignored": true, "tiering": "default" }' > .workflow-dev/config.json

echo "fixture ready"
