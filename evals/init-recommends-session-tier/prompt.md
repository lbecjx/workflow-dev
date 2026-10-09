---
max_turns: 40
timeout_seconds: 1200
# `allowed_tools` are Claude Code tool names — the vocabulary the `claude plugin
# eval` runner expects.
allowed_tools: [Read, Glob, Grep, Bash, Skill, Agent, AskUserQuestion]
---

Run /workflow-dev:init on the story file `eval-story.md` in this repository.

Answer anything init asks with a sensible default, and do not commit anything.
In your final message, quote word for word any notice init showed about the
session's model. If it showed none, say why. Also list every question init
asked you.
