<!--
workflow-dev — a persistent-context development workflow for Claude Code
Copyright (C) 2026  Luis Becerra

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version. See LICENSE for the full text.
-->

# Decision Points — When to STOP and Ask

During implementation, STOP and ask the human when any of these conditions is met. Never proceed silently past a decision point.

---

## Must Ask — Better Approach Detected

- **Cleaner solution exists:** If a more idiomatic, performant, or maintainable solution exists than what was planned — present both options with trade-offs
- **Plan has errors:** If the plan references code, types, files, or APIs that don't exist or describes an approach that won't work — STOP and explain what's wrong
- **Missing context:** If you need information not derivable from reading the code — ASK, don't infer
- **Ambiguous requirement:** If a task can be interpreted multiple ways — present interpretations, let human choose

---

## Must Ask — Risk Detected

- **Side effects outside scope:** If implementing would break or affect code outside the current task's files — STOP and inform before touching anything
- **Breaking existing contract:** If the implementation would change an API, interface, or behavior that other code depends on
- **Security concern:** If you notice the existing code has a vulnerability that the current task interacts with — inform (don't silently fix unless it's directly in scope)
- **Data loss potential:** If the change could corrupt, lose, or silently drop data under certain conditions

---

## Must Ask — Architecture Decisions

- **New pattern needed:** If the task requires creating a pattern/abstraction not established in the codebase
- **Multiple valid approaches:** If there are 2+ reasonable ways to implement and the choice has lasting consequences
- **Performance trade-off:** If there's a choice between readability/simplicity and performance that needs human judgment
- **Dependency addition:** If the cleanest solution requires adding a new dependency

---

## How to Ask

Present the decision clearly:

```
Decision needed:

The plan says: <what was planned>
What I found: <what the code actually shows>

Options:
→ Option A: <description + trade-off>
→ Option B: <description + trade-off>

My recommendation: <which and why>
```

Then WAIT. Don't proceed with your recommendation until the human confirms.

---

## When NOT to ask

Don't ask about:
- Obvious implementation details (variable names that follow existing conventions)
- Formatting choices (follow project formatter)
- Import ordering (follow project style)
- Anything the code already answers clearly

The goal is: ask when the human's judgment matters, don't ask when you're just being indecisive.
