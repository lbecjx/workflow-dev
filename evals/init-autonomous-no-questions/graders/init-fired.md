---
type: tool_used
tool: Skill
input_match: '"skill"\s*:\s*"(?:[\w-]+:)?init"'
---

PASS if the run loads the `init` skill — the precondition for everything else
this case asserts.

FAIL if `init` is never loaded.
