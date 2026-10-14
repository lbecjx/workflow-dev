---
max_turns: 40
timeout_seconds: 1200
# `allowed_tools` are Claude Code tool names — the vocabulary the `claude plugin
# eval` runner expects; see ../../references/harness-tools.md.
allowed_tools: [Read, Write, Edit, Glob, Grep, Bash, Skill, Agent, AskUserQuestion]
---

Run /workflow-dev:init on `local-backlog/EVAL-0008-greeting-name.md`. Run it
step by step. My setup answers for this repo: keep the `.workflow-dev/` folder
gitignored: yes. For the agents' models, use the default model for this
repo. Credit the agent as co-author in commits and PRs: yes. Turn the
notifications on for this machine: yes. Stop once init is done; don't
plan or implement anything, and do not commit anything.
