#!/bin/bash
# Scaffolds a scratch repo for the algorithmic-integrity eval: a logic-bearing
# uncommitted change whose algorithm has a concrete, defensible defect — a
# `while` loop that never advances its index (never reaches its exit) and a
# linear scan inside the loop (accidental O(n²)). Both are exactly what Part 13
# exists to catch, and neither is a style smell Part 4 or a wrong-output bug
# Part 11 would find.
#
# The change modifies a *tracked* file (rather than adding an untracked one) so
# it is unambiguously inside validate's single-diff scope — `git diff --name-only`
# lists tracked modifications, but not untracked files.
set -e

git init -q
git config user.email "eval@example.com"
git config user.name "Eval Fixture"

cat > README.md <<'MD'
# Eval fixture

A throwaway repo. No stack, no build step, no test suite — so
/workflow-dev:validate finds nothing blocking beyond the algorithmic defect
this case is about.
MD

# Baseline version, committed — the stub the diff below replaces.
cat > total_for.js <<'JS'
// Recomputes a per-customer total for a batch of orders.
function totalFor(orders) {
  return 0;
}

module.exports = { totalFor };
JS

git add README.md total_for.js
git commit -q -m "chore: baseline"

# The diff under review — uncommitted on purpose. Real logic (not a SKIP) with a
# non-terminating loop (`i` is never advanced) and an accidental O(n²) scan
# (`seen.includes` inside the loop). No side effects, no I/O.
cat > total_for.js <<'JS'
// Recomputes a per-customer total for a batch of orders.
function totalFor(orders) {
  let total = 0;
  let i = 0;
  const seen = [];

  while (i < orders.length) {
    const order = orders[i];
    if (!seen.includes(order.customerId)) {
      seen.push(order.customerId);
      total += order.amount;
    }
  }

  return total;
}

module.exports = { totalFor };
JS

echo "fixture ready"
