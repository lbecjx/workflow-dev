---
max_turns: 40
timeout_seconds: 1200
# `allowed_tools` are Claude Code tool names — the vocabulary the `claude plugin
# eval` runner expects; see ../../references/harness-tools.md.
allowed_tools: [Read, Write, Edit, Glob, Grep, Bash, Skill, Agent, AskUserQuestion]
---

Run /workflow-dev:init on `local-backlog/EVAL-0008-greeting-name.md`. Run it
step by step. Stop once init is done; don't
plan or implement anything.

Do not commit anything. In your final message, list in order every step the
run took until the story context file was written, including each question you
asked me or each setting you decided without asking, and say for each one what
the run had already done before it. Then paste `.workflow-dev/config.env` as it
is on disk, and quote every row you wrote to the story's Decisions table.
