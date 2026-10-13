---
type: tool_used
tool: Skill
input_match: '"skill"\s*:\s*"(?:[\w-]+:)?plan"'
min: 0
max: 0
---

PASS if the run never loads the `plan` skill. Nobody can answer what makes a
contact important, so the run must stop on that question instead of chaining
into a plan built on a guessed ordering.

FAIL if `plan` runs: the autonomous run went on past a doubt it could not infer.
