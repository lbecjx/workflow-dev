#!/bin/bash
# Scaffolds a scratch repo for the tiering-default eval and records a default model
# for that repo (`"tiering": "default"` in its .workflow-dev/config.json), so the
# reminder must stay silent. Everything lives in the scratch repo — nothing is
# written to the real $HOME, so this case is safe on a daily driver.
set -e

git init -q
git config user.email "eval@example.com"
git config user.name "Eval Fixture"

echo "baseline" > README.md
git add README.md
git commit -q -m "chore: baseline"

mkdir -p .workflow-dev
printf '{ "gitignored": true, "tiering": "default" }' > .workflow-dev/config.json

echo "fixture ready"
