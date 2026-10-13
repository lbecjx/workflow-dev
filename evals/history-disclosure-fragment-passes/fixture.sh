#!/bin/bash
# Scaffolds a scratch repo for the fragment PASS eval: one release-note fragment
# under changes/, rewritten (uncommitted) into a short note that states the net
# effect of the change. Part 12 must review it (it is in the diff) and pass it;
# a "not touched" SKIP would mean the fragment was never read.
#
# The fragment is committed first as a placeholder, so the rewrite is a change
# to a *tracked* file and falls inside validate's single-diff scope.
set -e

git init -q
git config user.email "eval@example.com"
git config user.name "Eval Fixture"

mkdir -p changes
cat > README.md <<'MD'
# Eval fixture

A throwaway repo whose release notes are kept as one file per change in
`changes/`, consolidated into the changelog at release time.
MD
echo "Placeholder note." > changes/ABC-4.feat.md

git add README.md changes
git commit -q -m "chore: baseline"

# The diff under review — uncommitted on purpose.
cat > changes/ABC-4.feat.md <<'MD'
The reports page can export the visible rows as a CSV file.
MD

echo "fixture ready"
