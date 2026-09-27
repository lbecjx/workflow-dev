---
max_turns: 60
timeout_seconds: 1800
allowed_tools: [Read, Glob, Grep, Bash, Skill, Agent, AskUserQuestion]
---

Run /workflow-dev:validate on the uncommitted changes in this repository.
The active story's context (in .workflow-dev/context/) records the manual-QA
decision as "yes" — follow the validate skill exactly, including its PASS-path
steps.
