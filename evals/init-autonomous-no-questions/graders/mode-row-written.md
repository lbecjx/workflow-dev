---
type: tool_used
# init creates the story file whole in Phase 6, with the row in it.
tool: Write
input_match: 'Autonomous mode: on'
---

PASS if the run writes the story file with the `Autonomous mode: on` row in it — the mode
the human stated in the prompt is recorded, not just acted on.

FAIL if the row is never written: later skills and a resumed session read the
row, so a run that only remembered the mode in conversation would lose it.
