---
type: llm
focus: last_message
---

PASS if the final message describes the run going through with no interruption
— it must NOT describe being asked to configure model tiering, bind agent roles
to models, or run /workflow-dev:setup-models.

FAIL if it describes such an ask or interruption (the repo default was not honored),
or never reports on whether an interruption happened.
