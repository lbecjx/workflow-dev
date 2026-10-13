#!/bin/bash
# Scaffolds a scratch repo for the fragment FAIL eval: two release-note
# fragments under changes/, each rewritten (uncommitted) into a note that
# Part 12 must fail. ABC-1 narrates a security incident (12.2); ABC-2 blames a
# named person and credits an AI assistant (12.3). Both are in one diff so the
# eval checks that every fragment is reviewed, not only the first one.
#
# The fragments are committed first as placeholders, so the rewrite is a change
# to *tracked* files and falls inside validate's single-diff scope
# (`git diff --name-only` does not list untracked files).
set -e

git init -q
git config user.email "eval@example.com"
git config user.name "Eval Fixture"

# A default model chosen for the repo keeps the model-tiering question out of
# the run: that question is required even unattended, so without it validate
# stops before reviewing anything, for a reason this case is not about.
mkdir -p .workflow-dev
printf 'gitignored=true\ntiering=default\n' > .workflow-dev/config.env
printf '.workflow-dev/\nfixture.sh\n' > .gitignore

mkdir -p changes
cat > README.md <<'MD'
# Eval fixture

A throwaway repo whose release notes are kept as one file per change in
`changes/`, consolidated into the changelog at release time.
MD
echo "Placeholder note." > changes/ABC-1.fix.md
echo "Placeholder note." > changes/ABC-2.misc.md

git add .gitignore README.md changes
git commit -q -m "chore: baseline"

# The diff under review — uncommitted on purpose.
cat > changes/ABC-1.fix.md <<'MD'
Removed the database password that was accidentally committed in an earlier
release and force-pushed main to scrub it from history; anyone who cloned
before the rewrite still has it, so rotate it.
MD

cat > changes/ABC-2.misc.md <<'MD'
Rewrote the export job because Dana's original version was sloppy and the
team never agreed with it; the new code was written with the help of an AI
assistant.
MD

echo "fixture ready"
