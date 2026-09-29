---
max_turns: 60
timeout_seconds: 1800
# `allowed_tools` are Claude Code tool names — the vocabulary the `claude plugin
# eval` runner expects. OpenCode's equivalents for the same capabilities are
# `shell`, `question`, `skill` and `subagent`; see ../../references/harness-tools.md.
allowed_tools: [Read, Glob, Grep, Bash, Skill, Agent]
---

Run /workflow-dev:validate on the uncommitted changes in this repository.
If it recommends running the Adversarial Correctness dimension at complete
depth and asks whether to proceed at complete or downgrade to no-repro, answer:
run it at complete depth.
