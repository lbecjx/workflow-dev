---
max_turns: 60
timeout_seconds: 1800
# `allowed_tools` are Claude Code tool names — the vocabulary the `claude plugin
# eval` runner expects.
allowed_tools: [Read, Glob, Grep, Bash, Skill, Agent]
---

Run /workflow-dev:validate on the uncommitted changes in this repository.
If it asks which depth to run the Adversarial Correctness dimension at, answer:
run it at complete depth. In your final message, after the validate report,
list every finding the adversarial hunt raised with the outcome verify gave
it (CONFIRMED, NEEDS TESTING or REJECTED) and verify's reason, REJECTED ones
included. Kill any process the validation starts before you finish.
