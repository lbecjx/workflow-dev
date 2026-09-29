#!/bin/bash
# Scaffolds a scratch repo for the reminder opt-out eval, and sets the opt-out
# so the reminder must stay silent. The opt-out file is a harmless "run on the
# default model, stop asking" marker, but this fixture writes it to the *real*
# $HOME (evals run as the user, with no HOME isolation), and there is no
# teardown hook — so it backs up any pre-existing tiering.json before
# overwriting it, leaving `~/.workflow-dev/tiering.json.eval-backup` to restore
# from. Run this case on a throwaway or CI machine, not a daily driver.
set -e

git init -q
git config user.email "eval@example.com"
git config user.name "Eval Fixture"

echo "baseline" > README.md
git add README.md
git commit -q -m "chore: baseline"

OPTOUT="$HOME/.workflow-dev/tiering.json"
if [[ -f "$OPTOUT" ]]; then
  cp "$OPTOUT" "$OPTOUT.eval-backup"
fi
mkdir -p "$HOME/.workflow-dev"
printf '{"optOut": true}' > "$OPTOUT"

echo "fixture ready"
