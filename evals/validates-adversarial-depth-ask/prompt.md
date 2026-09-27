---
max_turns: 60
timeout_seconds: 1800
allowed_tools: [Read, Glob, Grep, Bash, Skill, Agent, AskUserQuestion]
---

Run /workflow-dev:validate on the uncommitted changes in this repository.

The diff adds a pure function with real logic — nothing write-, concurrency-,
or security-related. Follow the validate skill exactly: when its Adversarial
Correctness dimension needs a depth, it must present the LITE/FULL choice
(a recommended depth plus a one-line reason), not run a depth silently. If it
asks you which depth to run, answer: run it at LITE.
