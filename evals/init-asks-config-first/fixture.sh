#!/bin/bash
# Scaffolds a scratch repo for the configuration-order eval: init starts with
# no stored answer for the `.workflow-dev/` gitignored choice nor for agent
# co-authorship, so both are missing when init's configuration block runs.
#
# REPO.md is pre-written so init takes its "already exists" short path and
# spawns no research sub-agents. `tiering=default` keeps the tiering question out of
# the run (see case.yaml). Everything lives in the
# scratch repo; nothing touches the real $HOME.
set -e

git init -q
git config user.email "eval@example.com"
git config user.name "Eval Fixture"

mkdir -p .workflow-dev/context local-backlog

printf 'tiering=default\n' > .workflow-dev/config.env
printf 'fixture.sh\n' > .gitignore

printf '{ "prefix": "EVAL" }\n' > local-backlog/.backlog-config.json

cat > .workflow-dev/context/REPO.md <<'MD'
# REPO.md — eval fixture

## 1. What this is
A throwaway repo with one shell script and no test suite.

## 2. Stack
Bash.

## 3. Project structure
`greet.sh` and a backlog folder.

## 4. Conventions
Nothing beyond plain Bash.

## 5. Good Practices
Nothing stack-specific to record.

## 6. Prohibitions
Nothing repo-specific to record.
MD

printf '#!/bin/bash\necho "Hello"\n' > greet.sh
chmod +x greet.sh

cat > local-backlog/EVAL-0008-greeting-name.md <<'MD'
# EVAL-0008 · Greet the user by name

| Field | Value |
|---|---|
| **Code** | EVAL-0008 |
| **Status** | Not Started |
| **Zone** | Backlog |

---

## Description

`greet.sh` always prints "Hello". It should greet whoever runs it.

## Acceptance Criteria

1. `greet.sh NAME` prints `Hello, NAME`.
2. `greet.sh` with no argument still prints `Hello`.

## History

- 2026-10-13T00:00:00Z — Created (Status: Not Started)
MD

# .workflow-dev/ stays out of the baseline: a real first init finds it untracked,
# and a committed one would read as evidence for "tracked".
git add -A -- . ':!.workflow-dev'
git commit -q -m "chore: baseline"

echo "fixture ready"
