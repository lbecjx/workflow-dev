---
type: llm
focus: last_message
---

PASS if the validate report says the story's level was raised from `moderada`
to `compleja`, gives the reason (the diff adds a write path: it appends to a
file on disk), and handles Adversarial Correctness as today's flow does: a
recommended depth with a one-line reason and the no-repro/complete choice
presented, not a skip.

FAIL if Adversarial Correctness is marked SKIP because the stored level is
`moderada`, if the report keeps `moderada` without mentioning the write path,
or if it ran a depth without surfacing the choice. Trusting a stored level over
what the diff shows is the regression this case guards.
