---
type: tool_order
before: { tool: Bash, input_match: 'config-env\.sh set agentCoauthorship' }
after: { tool: Write, input_match: '\.workflow-dev/context/EVAL-0008' }
---

`agentCoauthorship` is saved before init writes the story's context file. The anchor is that
Write, not a read of the story or REPO.md: the agent reads files with Read, Bash
or Grep from one run to the next, and `tool_order` matches one tool per side,
while the context file is always created with Write.
