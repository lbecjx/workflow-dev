---
type: tool_used
# `AskUserQuestion` is Claude Code's ask-question tool, the vocabulary the
# `claude plugin eval` runner records tool calls in — see
# ../../references/harness-tools.md.
tool: AskUserQuestion
min: 0
max: 0
---

PASS if the run never calls the ask-question tool. `init-auto` already says
how to run the story, so `init` must not ask the run mode, and the fixture
leaves nothing else to ask.

FAIL on any call.
