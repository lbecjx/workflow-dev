#!/bin/bash
# Scaffolds a scratch repo for the inference eval: a story whose one open
# point (the greeting's language) is settled by a tracked config file that
# REPO.md names as its owner.
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

printf '{ "gitignored": true, "tiering": "default", "agentCoauthorship": "no" }\n' > .workflow-dev/config.json
printf '.workflow-dev/\nfixture.sh\n' > .gitignore

printf '{ "prefix": "EVAL" }\n' > local-backlog/.backlog-config.json

cat > .workflow-dev/context/REPO.md <<'MD'
# REPO.md — eval fixture

## 1. What this is
A throwaway repo with one shell script and no test suite.

## 2. Stack
Bash.

## 3. Project structure
`greet.sh`, `config/app.json`, and a backlog folder.

## 4. Conventions
- The project's language lives in `config/app.json` (`language`, an ISO 639-1
  code). Every user-facing text follows it.

## 5. Good Practices
Nothing stack-specific to record.

## 6. Prohibitions
Nothing repo-specific to record.
MD

mkdir -p config
printf '{ "language": "es" }\n' > config/app.json
printf '#!/bin/bash\necho "Hello"\n' > greet.sh
chmod +x greet.sh

cat > local-backlog/EVAL-0005-greeting.md <<'MD'
# EVAL-0005 · Greet in the project's language

| Field | Value |
|---|---|
| **Code** | EVAL-0005 |
| **Status** | Not Started |
| **Zone** | Backlog |

---

## Description

`greet.sh` greets in English today, whatever the project's language is.

## Acceptance Criteria

1. `greet.sh` prints its greeting in the project's language.

## History

- 2026-10-12T00:00:00Z — Created (Status: Not Started)
MD

git add -A
git commit -q -m "chore: baseline"

echo "fixture ready"
