---
type: tool_used
tool: Skill
input_match: '"skill"\s*:\s*"(?:[\w-]+:)?update-status"'
---

PASS if init hands the story's status change off to the backlog skill — the
first piece of work on the story that the other graders order the
configuration against.

FAIL if the hand-off never happens: "before the hand-off" would then mean
nothing.
