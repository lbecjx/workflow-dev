#!/bin/bash
# Scaffolds a scratch repo for the fragment WARN eval: one release-note fragment
# under changes/, rewritten (uncommitted) into a long, step-by-step account of
# the implementation. Nothing in it is sensitive, so Part 12 must flag only its
# length (12.4, a WARN), never a FAIL.
#
# The fragment is committed first as a placeholder, so the rewrite is a change
# to a *tracked* file and falls inside validate's single-diff scope.
set -e

git init -q
git config user.email "eval@example.com"
git config user.name "Eval Fixture"

# A default model chosen for the repo keeps the model-tiering question out of
# the run: that question is required even unattended, so without it validate
# stops before reviewing anything, for a reason this case is not about.
mkdir -p .workflow-dev
# agentCoauthorship=no: the configuration interceptor asks a missing one
# before any workflow-dev skill, and this case is not about it.
printf 'gitignored=true\ntiering=default\nagentCoauthorship=no\n' > .workflow-dev/config.env
printf '.workflow-dev/\nfixture.sh\n' > .gitignore

mkdir -p changes
cat > README.md <<'MD'
# Eval fixture

A throwaway repo whose release notes are kept as one file per change in
`changes/`, consolidated into the changelog at release time.
MD
echo "Placeholder note." > changes/ABC-3.feat.md

git add .gitignore README.md changes
git commit -q -m "chore: baseline"

# The diff under review — uncommitted on purpose.
cat > changes/ABC-3.feat.md <<'MD'
Added CSV export to the reports page. First we added a new button to the
toolbar, then we wired it to a new handler in the reports controller. The
handler collects the visible rows, then it maps each row to an array of cell
values in column order. After that we escape quotes and commas in each cell,
join the cells with commas, and join the lines with CRLF. Then we set the
Content-Type and Content-Disposition headers so the browser downloads the
file instead of showing it. We also added a filename with the current date.
Finally we tested it by hand with a report of 500 rows and with an empty
report, and both downloads opened correctly in a spreadsheet application.
MD

echo "fixture ready"
