---
type: llm
focus: last_message
---

PASS if the validate report says the story has no recorded complexity level
and names the level it inferred, marked as inferred, and Adversarial
Correctness was handled as today: a recommended depth (no-repro on this diff)
with a one-line reason, and the no-repro/complete choice presented before it
ran.

FAIL if Adversarial Correctness is marked SKIP because of a story level
(`moderada` or `simple`), if the report presents an inferred level as if it had
been recorded and applied, or if it ran a depth without surfacing the choice.
Treating a missing level as `moderada` is the regression this case guards.
