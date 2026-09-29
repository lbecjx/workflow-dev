---
max_turns: 40
timeout_seconds: 1200
# `allowed_tools` are Claude Code tool names — the vocabulary the `claude plugin
# eval` runner expects. OpenCode's equivalents for the same capabilities are
# `shell`, `question`, `skill` and `subagent`; see ../../references/harness-tools.md.
allowed_tools: [Read, Glob, Grep, Bash, Skill, Agent, AskUserQuestion]
---

Run /workflow-dev:init on the story file `eval-story.md` in this repository.

Answer anything init asks with a sensible default, and do not commit anything.
In your final message, say what the run reached by the end and whether it was
ever interrupted before it got there.
