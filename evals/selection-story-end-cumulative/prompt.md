---
max_turns: 60
timeout_seconds: 1800
# `allowed_tools` are Claude Code tool names — the vocabulary the `claude plugin
# eval` runner expects.
allowed_tools: [Read, Glob, Grep, Bash, Skill, Agent, AskUserQuestion]
---

Story EVAL-0002 runs in "after every task group" validation mode. Task Group 2,
its last one, is finished and every other task group is Done. Run
/workflow-dev:validate for it, the way /workflow-dev:implement's Step 5 would.

If validate's Adversarial Correctness dimension asks you to choose a depth,
answer: run it at no-repro. In your final report, state the validation scope
and list every file it covered.
