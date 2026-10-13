---
max_turns: 60
timeout_seconds: 1800
# `allowed_tools` are Claude Code tool names — the vocabulary the `claude plugin
# eval` runner expects.
allowed_tools: [Read, Glob, Grep, Bash, Skill, Agent, AskUserQuestion]
---

Run /workflow-dev:validate on the uncommitted changes in this repository.
The active story's context is in .workflow-dev/context/. Follow the validate
skill exactly. If validate's Adversarial Correctness dimension asks you to
choose a depth, answer: run it at no-repro. In your final report, state the
story's complexity level (and where it came from) and the Adversarial
Correctness depth decision with its one-line reason.
