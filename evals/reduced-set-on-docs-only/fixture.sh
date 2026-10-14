#!/bin/bash
# Scaffolds a scratch repo for the reduced-set eval: an uncommitted change that
# touches documentation only — no logic — so validate's Step 3 gate must run the
# reduced set and skip every judgment dimension, Algorithmic Integrity included.
#
# The change modifies a *tracked* file so it is inside validate's single-diff
# scope (`git diff --name-only` lists tracked modifications, not untracked files).
#
# The baseline also commits a release-note fragment the diff never touches, so
# Git History Disclosure must still SKIP: only fragments in the changed-file
# list are reviewed, and a changes/ directory alone triggers nothing.
set -e

git init -q
git config user.email "eval@example.com"
git config user.name "Eval Fixture"

# The setup answers the configuration interceptor (config-check.sh) would
# otherwise ask before /workflow-dev:validate; this case is not about them.
# `.git/info/exclude` keeps the folder out of the diff without a tracked change.
mkdir -p .workflow-dev
printf 'gitignored=true\ntiering=default\nagentCoauthorship=no\n' > .workflow-dev/config.env
printf '.workflow-dev/\n' >> .git/info/exclude

cat > README.md <<'MD'
# Eval fixture

A throwaway repo used to check that a docs-only diff runs the reduced set.
MD
mkdir -p changes
echo "Fixed the date shown on the reports page." > changes/OLD-1.fix.md

git add README.md changes
git commit -q -m "chore: baseline"

# The diff under review — uncommitted on purpose. Documentation only: no logic,
# no behavior, so nothing for a judgment dimension to judge.
cat > README.md <<'MD'
# Eval fixture

A throwaway repo used to check that a docs-only diff runs the reduced set.

This sentence was reworded. No code, no logic, no behavior changed.
MD

echo "fixture ready"
