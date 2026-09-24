---
max_turns: 60
timeout_seconds: 1800
allowed_tools: [Read, Glob, Grep, Bash, Skill, Agent]
---

Run /workflow-dev:validate on the uncommitted changes in this repository.
If it recommends running the Adversarial Correctness dimension at FULL
depth and asks whether to proceed at FULL or downgrade to LITE, answer:
run it at FULL depth.
