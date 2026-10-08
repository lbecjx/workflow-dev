---
type: llm
focus: last_message
---

PASS if the final message reports that init reached its story-context step and
was never interrupted on the way — in particular that it was NOT asked to bind
agent roles to models, configure model tiering, or run /workflow-dev:setup-models.

FAIL if it describes such an ask or interruption (the repo default was not honored),
if init stopped before reaching the story-context step, or if it never reports
on whether an interruption happened.
