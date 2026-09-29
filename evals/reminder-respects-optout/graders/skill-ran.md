---
type: tool_used
tool: Skill
input_match: '"skill"\s*:\s*"(?:[\w-]+:)?help"'
---

PASS if the run actually loads a workflow-dev skill — without this, the case
would "pass" by never triggering the reminder at all, which proves nothing.
