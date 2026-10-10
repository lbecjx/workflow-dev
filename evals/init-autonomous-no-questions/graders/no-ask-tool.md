---
type: tool_used
# `AskUserQuestion` is Claude Code's ask-question tool, the vocabulary the
# `claude plugin eval` runner records tool calls in — see
# ../../references/harness-tools.md.
tool: AskUserQuestion
min: 0
max: 0
---

PASS if the run never calls the ask-question tool — no run-mode question, no
backlog question, no plan approval, nothing. The fixture story has no blocking
question, so the pre-autonomous checkpoint has nothing to ask either.

FAIL on any call. This is the half of "no questions" that does not depend on
the run's own report: `no-questions.md` grades what the run says, this grades
what it did.
