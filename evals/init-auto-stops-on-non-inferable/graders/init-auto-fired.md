---
type: tool_used
tool: Skill
input_match: '"skill"\s*:\s*"(?:[\w-]+:)?init-auto"'
---

PASS if the run loads the `init-auto` skill — the precondition for everything
else this case asserts.

FAIL if `init-auto` is never loaded.
