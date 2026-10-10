---
type: tool_used
tool: Skill
input_match: '"skill"\s*:\s*"(?:[\w-]+:)?plan"'
---

PASS if the run goes on from init to the `plan` skill on its own, as
autonomous mode's "Chaining" rule requires.

FAIL if `plan` is never loaded: the run stopped after init and handed control
back, offering the next step instead of running it.
