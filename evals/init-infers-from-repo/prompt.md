---
max_turns: 40
timeout_seconds: 1200
# `allowed_tools` are Claude Code tool names — the vocabulary the `claude plugin
# eval` runner expects; see ../../references/harness-tools.md.
allowed_tools: [Read, Write, Edit, Glob, Grep, Bash, Skill, Agent, AskUserQuestion]
---

Run /workflow-dev:init on `local-backlog/EVAL-0005-greeting.md`. Run it step by
step. Don't change the alerts setting. Stop once init is done; don't
plan or implement anything.

Do not commit anything. In your final message, list every question you asked me
(or say there were none), and quote every row you wrote to the story's
Decisions table.
