#!/bin/bash
# Scaffolds a scratch repo for the adversarial-depth-ask eval: a logic-bearing
# but low-risk uncommitted change — a pure function with real edge cases and no
# side effects. That is exactly the shape §11.0 says to handle by *suggesting*
# LITE and asking, not by running a depth inline: real logic means it isn't a
# SKIP, and the absence of any write path / concurrency / security surface
# means FULL isn't called for either.
set -e

git init -q
git config user.email "eval@example.com"
git config user.name "Eval Fixture"

cat > README.md <<'MD'
# Eval fixture

A throwaway repo. No stack, no build step, no test suite — so
/workflow-dev:validate has nothing blocking to find beyond the depth decision
this case is about.
MD

git add README.md
git commit -q -m "chore: baseline"

# The diff under review — uncommitted on purpose. A pure function with real
# edge cases (zero per-page, out-of-range page, partial last page) and no side
# effects: real logic, so not SKIP; nothing write/concurrency/security-related,
# so §11.0's suggestion is LITE and the human is asked to confirm.
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
