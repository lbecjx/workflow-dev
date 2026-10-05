---
type: llm
focus: last_message
---

PASS if the validate report states it ran the reduced set (the diff is
documentation only, with no real logic) and therefore did not run the judgment
dimensions. In particular, it must not report an Algorithmic Integrity dimension
as run/passed/failed; omitting that dimension, or stating it was not run because
the reduced set applies, are both acceptable.

FAIL if the report claims the full set ran, or reports Algorithmic Integrity (or
any other judgment dimension — Code quality, Testing, Architecture, Adversarial
Correctness) as run or passed for this docs-only diff. Spawning a judgment
dimension on a docs-only change is exactly the regression this case guards.
