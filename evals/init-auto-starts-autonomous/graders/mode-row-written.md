---
type: tool_used
# init creates the story file whole in Phase 6, with the row in it.
tool: Write
input_match: 'Autonomous mode: on'
---

PASS if the run writes the story file with the `Autonomous mode: on` row in
it: starting with `init-auto` is recorded as the human's choice, not just acted
on.

FAIL if the row is never written.
