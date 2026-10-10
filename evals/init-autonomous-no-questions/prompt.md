---
max_turns: 40
timeout_seconds: 1200
# `allowed_tools` are Claude Code tool names — the vocabulary the `claude plugin
# eval` runner expects; see ../../references/harness-tools.md.
allowed_tools: [Read, Write, Edit, Glob, Grep, Bash, Skill, Agent, AskUserQuestion]
---

Run /workflow-dev:init on `local-backlog/EVAL-0003-autonomous-init.md`. Run this
story autonomously — don't ask me each step — and stop once the plan is
written; don't implement it.

Do not commit anything. In your final message, list every question you asked
me during the run (or say there were none), say what you told me between init's
research and the start of plan, and say which workflow-dev skills ran after
init.
