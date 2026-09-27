---
type: llm
focus: last_message
---

PASS if the run's final message offers the next step after a PASS — i.e. it
offers or runs `/workflow-dev:summarize-changes` (draft the commit message /
PR). It counts whether the offer is made through the ask-question tool or as
a plain question in the final message.

FAIL if the run never reaches the PASS path, never runs `/workflow-dev:validate`,
or ends after reporting validation without offering to draft the commit
message / PR (the flow dead-ended, which is exactly what Step 7 exists to
prevent).
