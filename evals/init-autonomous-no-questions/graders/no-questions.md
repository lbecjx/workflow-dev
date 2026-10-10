---
type: llm
focus: last_message
---

PASS if the final message says the run asked the human no questions, and that
`plan` ran after init.

FAIL if it lists any question asked of the human (the run mode, a Planner or
note question, a gitignore question, a plan approval, a validation-mode or
manual-QA question, or a "shall I continue?"), if it says the run stopped after
init to suggest or announce the next step, or if it does not say whether any
question was asked.
