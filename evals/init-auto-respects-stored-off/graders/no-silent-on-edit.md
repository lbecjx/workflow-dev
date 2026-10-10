---
type: tool_used
tool: Edit
input_match: 'Autonomous mode: on'
min: 0
max: 0
---

PASS if the run never writes `Autonomous mode: on` with the Edit tool: the
stored `off` row stays, since no answer came.

FAIL on any such write: `init-auto` overwrote the human's `off` without an
answer.
