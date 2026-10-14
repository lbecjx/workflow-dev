#!/bin/bash
# Scaffolds a scratch repo for the selection eval on a logic-bearing diff: a
# pure function gains real edge cases (zero per-page, out-of-range page, partial
# last page). Validate's selection judge must pick checks that read logic, not
# only Security.
#
# The change modifies a *tracked* file so it is inside validate's single-diff
# scope (`git diff --name-only` lists tracked modifications, not untracked files).
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

A throwaway repo with one pure function and no test suite.
MD

cat > page_window.js <<'JS'
// Returns the zero-based slice bounds [start, end) for one page of items.
function pageWindow(page, perPage, total) {
  return [0, Math.min(perPage, total)];
}

module.exports = { pageWindow };
JS

git add README.md page_window.js
git commit -q -m "chore: baseline"

# The diff under review — uncommitted on purpose. Real logic, no side effects.
cat > page_window.js <<'JS'
// Returns the zero-based slice bounds [start, end) for one page of items.
function pageWindow(page, perPage, total) {
  if (perPage <= 0) return [0, 0];
  const pages = Math.ceil(total / perPage);
  if (page < 1 || page > pages) return [0, 0];
  const start = (page - 1) * perPage;
  return [start, Math.min(start + perPage, total)];
}

module.exports = { pageWindow };
JS

echo "fixture ready"
