#!/bin/bash
# Scaffolds a scratch repo for the reminder opt-out eval, and sets the opt-out
# so the reminder must stay silent. The opt-out file is a harmless "run on the
# default model, stop asking" marker, but it is left in place afterwards — run
# this case on a throwaway or CI machine, not a daily driver.
set -e

git init -q
git config user.email "eval@example.com"
git config user.name "Eval Fixture"

echo "baseline" > README.md
git add README.md
git commit -q -m "chore: baseline"

mkdir -p "$HOME/.workflow-dev"
printf '{"optOut": true}' > "$HOME/.workflow-dev/tiering.json"

echo "fixture ready"
