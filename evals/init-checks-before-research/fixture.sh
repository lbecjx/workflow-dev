#!/bin/bash
# Scaffolds a scratch repo for the init tiering-detection eval: a minimal story
# to init, an existing REPO.md, and the tiering opt-out.
#
# REPO.md is pre-written — complete with the Good Practices and Prohibitions
# sections init checks for before it will skip its research pass — so init's
# repo-level step takes its "already exists" short path and spawns none of the
# three research sub-agents. That keeps the run bounded and its outcome
# deterministic, which is what lets the graders say anything meaningful about
# where it stopped.
#
# The opt-out is the state to use here, not a bound-and-current one. Reaching
# `ok` needs real files under ~/.claude/agents/, and evals run as the user with
# no HOME isolation and no teardown hook — so that fixture would overwrite the
# agent files a real user's models are bound in, restoring nothing. The opt-out
# is the reachable half of the same check. It is still written to the *real*
# $HOME: any pre-existing tiering.json is backed up beside it and has to be
# restored by hand. Run this case on a throwaway or CI machine.
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
# EVAL-0002 · A throwaway story for the init tiering-detection eval

| Field | Value |
|---|---|
| **Status** | Not Started |

## Description

A story with no research behind it, used to exercise `/workflow-dev:init`'s
role-binding check. It exists only so init has a story to initialize.

## Acceptance Criteria

1. The eval fixture's story file is read and summarized in the context init
   writes.
MD

git add .gitignore eval-story.md
git commit -q -m "chore: baseline"

OPTOUT="$HOME/.workflow-dev/tiering.json"
# First write wins. An unconditional `cp` here would clobber the real backup on a
# second run — the source is the fixture's own synthetic opt-out by then, so the
# user's original would be gone with no second copy anywhere. The same guard also
# keeps this case from overwriting the backup the sibling case leaves at the same
# path (`evals/reminder-respects-optout`), which would corrupt that one the same way.
if [[ -f "$OPTOUT" && ! -f "$OPTOUT.eval-backup" ]]; then
  cp "$OPTOUT" "$OPTOUT.eval-backup"
fi
mkdir -p "$HOME/.workflow-dev"
printf '{"optOut": true}' > "$OPTOUT"

echo "fixture ready"
