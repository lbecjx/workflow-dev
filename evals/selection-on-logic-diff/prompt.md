---
max_turns: 60
timeout_seconds: 1800
# `allowed_tools` are Claude Code tool names — the vocabulary the `claude plugin
# eval` runner expects.
allowed_tools: [Read, Glob, Grep, Bash, Skill, Agent, AskUserQuestion]
---

Run /workflow-dev:validate on the uncommitted changes in this repository.

If validate's Adversarial Correctness dimension asks you to choose a depth,
answer: run it at no-repro. In your final report, show which validations ran
and which were skipped, with the reason for each skip.
