---
max_turns: 30
timeout_seconds: 900
# `allowed_tools` are Claude Code tool names — the vocabulary the `claude plugin
# eval` runner expects. OpenCode's equivalents for the same capabilities are
# `shell`, `question`, `skill` and `subagent`; see ../../references/harness-tools.md.
allowed_tools: [Read, Glob, Grep, Bash, Skill, Agent, AskUserQuestion]
---

Run the workflow-dev help skill. Then describe, in a sentence or two, what
happened during the run — in particular, whether anything interrupted it or
asked you to take another action before it completed.
