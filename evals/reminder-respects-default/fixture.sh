#!/bin/bash
# Scaffolds a scratch repo for the tiering-default eval and records a default model
# for that repo (`tiering=default` in its .workflow-dev/config.env), so the
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
# agentCoauthorship=no: the configuration interceptor asks a missing one
# before any workflow-dev skill, and this case is not about it.
printf 'gitignored=true\ntiering=default\nagentCoauthorship=no\n' > .workflow-dev/config.env

echo "fixture ready"
