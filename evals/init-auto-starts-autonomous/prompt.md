---
max_turns: 40
timeout_seconds: 1200
# `allowed_tools` are Claude Code tool names — the vocabulary the `claude plugin
# eval` runner expects; see ../../references/harness-tools.md.
allowed_tools: [Read, Write, Edit, Glob, Grep, Bash, Skill, Agent, AskUserQuestion]
---

Run /workflow-dev:init-auto on `local-backlog/EVAL-0004-init-auto.md`, and stop
once the plan is written; don't implement it.

Do not commit anything. In your final message, list every question you asked
me during the run (or say there were none).
