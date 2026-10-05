---
type: llm
focus: last_message
---

PASS if the validate report includes an Algorithmic Integrity dimension (the
new Part 13 dimension, run under the wd-judge role) and, within it, reports the
defect in `total_for.js`'s `totalFor` as a non-terminating loop — the `while`
loop never advances `i`, so it never reaches its exit. Because the defect is
provable by inspection (no path modifies `i`), the dimension must report it as
CONFIRMED and at the blocking tier (FAIL). A report that additionally flags the
`seen.includes(...)` scan inside the loop as accidental O(n²) is a bonus, not a
requirement.

FAIL if the report omits the Algorithmic Integrity dimension entirely, marks it
SKIP for this logic-bearing diff, does not mention the non-termination / the
missing advancement of `i`, or hedges the provable infinite loop down to a
non-blocking tier (NEEDS TESTING, or a mere efficiency smell) instead of a
CONFIRMED, blocking finding. Reporting only unrelated findings (naming, style)
without this one is a FAIL.
