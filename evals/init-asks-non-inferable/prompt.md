---
max_turns: 40
timeout_seconds: 1200
# `allowed_tools` are Claude Code tool names — the vocabulary the `claude plugin
# eval` runner expects; see ../../references/harness-tools.md.
allowed_tools: [Read, Write, Edit, Glob, Grep, Bash, Skill, Agent, AskUserQuestion]
---

Run /workflow-dev:init on `local-backlog/EVAL-0006-important-contacts.md`. Run
it step by step. Don't turn the alerts on for this story. Stop once init is
done; don't plan or implement anything.

Do not commit anything. In your final message, list every question you asked me
or left open for me (or say there were none), and quote every row you wrote to
the story's Decisions table. Last, paste the full story context file you wrote
(`.workflow-dev/context/EVAL-0006.md`) as it is on disk, or say that you wrote none.
