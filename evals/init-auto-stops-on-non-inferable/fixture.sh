#!/bin/bash
# Scaffolds a scratch repo for the non-inferable eval (init-auto): a story
# whose one criterion needs a product decision nothing in the repo settles.
#
# REPO.md is pre-written so init takes its "already exists" short path and
# spawns no research sub-agents. The repo default model (`"tiering":
# "default"`) keeps the tiering question out of the run, and
# `"agentCoauthorship": "no"` keeps the co-authorship question out of an
# autonomous run: both are fixed questions this case is not about. Everything
# lives in the scratch repo; nothing touches the real $HOME.
set -e

git init -q
git config user.email "eval@example.com"
git config user.name "Eval Fixture"

mkdir -p .workflow-dev/context local-backlog

printf 'gitignored=true\ntiering=default\nagentCoauthorship=no\n' > .workflow-dev/config.env
printf '.workflow-dev/\nfixture.sh\n' > .gitignore

printf '{ "prefix": "EVAL" }\n' > local-backlog/.backlog-config.json

cat > .workflow-dev/context/REPO.md <<'MD'
# REPO.md — eval fixture

## 1. What this is
A throwaway repo with one shell script and no test suite.

## 2. Stack
Bash.

## 3. Project structure
`contacts.sh`, `contacts.csv`, and a backlog folder.

## 4. Conventions
Nothing beyond plain Bash.

## 5. Good Practices
Nothing stack-specific to record.

## 6. Prohibitions
Nothing repo-specific to record.
MD

printf 'name,last_contact,deals_closed\nAna,2026-09-30,1\nBruno,2026-05-02,7\nCarla,2026-10-10,0\n' > contacts.csv
printf '#!/bin/bash\ntail -n +2 contacts.csv | cut -d, -f1\n' > contacts.sh
chmod +x contacts.sh

cat > local-backlog/EVAL-0007-important-contacts.md <<'MD'
# EVAL-0007 · Show the most important contacts first

| Field | Value |
|---|---|
| **Code** | EVAL-0007 |
| **Status** | Not Started |
| **Zone** | Backlog |

---

## Description

`contacts.sh` lists the contacts in file order. Sales wants the ones that matter
most at the top.

## Acceptance Criteria

1. `contacts.sh` lists the most important contacts first.

## History

- 2026-10-12T00:00:00Z — Created (Status: Not Started)
MD

git add -A
git commit -q -m "chore: baseline"

echo "fixture ready"
