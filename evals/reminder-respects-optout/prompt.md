---
max_turns: 30
timeout_seconds: 900
allowed_tools: [Read, Glob, Grep, Bash, Skill, Agent, AskUserQuestion]
---

Run the workflow-dev help skill. Then report whether anything asked you to
configure model tiering or bind agent roles to models. Answer with exactly one
of: "asked" or "not asked".
