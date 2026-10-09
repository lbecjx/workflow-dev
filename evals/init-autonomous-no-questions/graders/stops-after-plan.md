---
type: tool_used
tool: Skill
input_match: '"skill"\s*:\s*"(?:[\w-]+:)?implement"'
min: 0
max: 0
---

PASS if the run never loads the `implement` skill: the prompt asks it to stop
once the plan is written, and autonomous mode's "Chaining" rule lists a stop
the human asked for as one of the places a run stops.

FAIL if `implement` runs: the run ignored the human's stop and chained past it.
