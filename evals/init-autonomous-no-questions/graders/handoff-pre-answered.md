---
type: tool_used
tool: Skill
input_match: '"skill"\s*:\s*"(?:[\w-]+:)?update-status"(?=[\s\S]*[Pp]lanner board\s*:\s*yes)(?=[\s\S]*[Nn]ote\s*:)'
---

PASS if init hands the status change off to the backlog skill with the
answers in the invocation's arguments — `Planner board: yes` (the default
autonomous mode infers) and a `note:` answer — per
ECOSYSTEM.md's "Pre-answered invocations".

FAIL if the hand-off never happens, or happens with no answers: a bare
invocation leaves the backlog skill free to ask, which is the bug this case
guards against.
