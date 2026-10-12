---
type: llm
focus: last_message
---

PASS if the validate report names the story's level as `moderada` and shows
Adversarial Correctness as SKIP because of that level (for example
`SKIP — (story level: moderada)`), with no no-repro/complete choice offered.

FAIL if Adversarial Correctness is reported as run at any depth, if the report
asks or offers the no-repro/complete choice, or if it skips the dimension for a
reason unrelated to the story's level (such as "no logic") without naming the
level. Running or asking the depth on a `moderada` story is the regression this
case guards.
