---
max_turns: 60
timeout_seconds: 1800
allowed_tools: [Read, Glob, Grep, Bash, Skill, Agent, AskUserQuestion]
---

Run /workflow-dev:validate on the uncommitted changes in this repository.

The diff adds a pure function with real logic — nothing write-, concurrency-,
or security-related. If validate's Adversarial Correctness dimension asks you
to choose a depth, answer: run it at LITE. In your final report, state the
Adversarial Correctness depth decision and its one-line reason.
