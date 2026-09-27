---
type: tool_used
tool: Skill
input_match: '"skill"\s*:\s*"(?:[\w-]+:)?manual-qa"'
---

PASS if the run loads the `manual-qa` skill — proving validate read the
story's "Manual QA: yes" decision on its PASS path and ran Step 7.

FAIL if `manual-qa` is never loaded (validate skipped Step 7, or re-asked a
question that plan had already answered).
