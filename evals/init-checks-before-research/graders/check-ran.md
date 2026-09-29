---
type: tool_used
tool: Bash
input_match: 'model-tiering-check\.sh\s+--status'
---

PASS if the run invoked the tiering check in its reporting mode — proving init's
detection step actually executed, and that it passed its payload as an argument
rather than falling through to stdin.

FAIL if the check is never invoked. This is the half that gives the case teeth:
a run that never checked its bindings is exactly as quiet as one that checked
and found the opt-out, so silence alone would pass a regression that dropped the
step entirely.
