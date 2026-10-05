#!/bin/bash
# Scaffolds a scratch repo for the reduced-set eval: an uncommitted change that
# touches documentation only — no logic — so validate's Step 3 gate must run the
# reduced set and skip every judgment dimension, Algorithmic Integrity included.
#
# The change modifies a *tracked* file so it is inside validate's single-diff
# scope (`git diff --name-only` lists tracked modifications, not untracked files).
set -e

git init -q
git config user.email "eval@example.com"
git config user.name "Eval Fixture"

cat > README.md <<'MD'
# Eval fixture

A throwaway repo used to check that a docs-only diff runs the reduced set.
MD

git add README.md
git commit -q -m "chore: baseline"

# The diff under review — uncommitted on purpose. Documentation only: no logic,
# no behavior, so nothing for a judgment dimension to judge.
cat > README.md <<'MD'
# Eval fixture

A throwaway repo used to check that a docs-only diff runs the reduced set.

This sentence was reworded. No code, no logic, no behavior changed.
MD

echo "fixture ready"
