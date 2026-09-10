<!--
workflow-dev — a persistent-context development workflow for Claude Code
Copyright (C) 2026  Luis Becerra

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version. See LICENSE for the full text.
-->

# Coding Standards — Universal

These rules apply to ALL code, regardless of language or framework. They are loaded every time the agent writes code.

---

## Engineering Mindset

Think and implement like a Senior Software Engineer:

**Architecture awareness:**
- Understand where this code lives in the system's dependency graph
- Respect layer boundaries (don't leak domain logic into handlers, don't put UI logic in services)
- Consider how this code will be extended, tested, and debugged
- Keep interfaces small and focused

**Defensive coding:**
- Validate at system boundaries (user input, external APIs, config)
- Handle errors explicitly — never swallow, always propagate or handle meaningfully
- Anticipate nil/null/undefined in any data from external sources
- Consider concurrent access when shared state is involved

**Readability and maintainability:**
- Name things precisely — a function name should make its purpose obvious
- Prefer explicit over clever — readable code beats compact code
- Keep functions focused — if you need a comment to separate sections, extract a function
- Structure files logically — related code together, public before private

**Performance consciousness:**
- Know the cost of operations (DB calls, network, allocations in hot paths)
- Don't optimize prematurely, but don't introduce obvious N+1 patterns
- Be aware of dependency size when adding new ones
- Cache expensive computations when access patterns justify it

---

## Zero-Inference Policy

Nothing should be inferred. Everything must be given by the human or read from code:

- Don't assume naming conventions — read existing code
- Don't assume error handling strategy — match existing patterns
- Don't assume data shapes or types — read actual interfaces
- Don't assume business logic — ask
- Don't assume the plan is correct — verify against actual codebase

---

## Scope Discipline

- Only modify files relevant to the current task
- Don't "fix" unrelated issues noticed along the way (inform the human instead)
- Don't refactor code that works unless explicitly asked
- Don't add features beyond what the requirement states
- Don't introduce new abstractions unless justified by the current task
- Three similar lines is better than a premature abstraction

---

## Minimal Correct Changes

- Write the minimum code that satisfies the requirement
- Follow existing patterns in the codebase — don't introduce your own style
- Prefer editing existing files over creating new ones
- No "while I'm here" cleanup
- No half-finished implementations or TODO stubs
- No backwards-compatibility shims when you can just change the code

---

## Security (Non-Negotiable)

These are ALWAYS blocking. No exceptions:

- No string interpolation for queries (SQL, NoSQL, GraphQL, shell commands) — use parameterized
- No unsanitized user input in URLs, paths, headers, or templates
- No eval(), Function(), or dynamic code execution with external input
- No API keys, tokens, passwords, or connection strings in code
- No hardcoded credentials (even "temporary" ones)
- No raw upstream error bodies returned to clients
- No PII in logs or error messages
- No deserialization of untrusted data without validation

---

## Error Handling

- Errors are handled at the appropriate level — not too early (losing context), not too late (crashing)
- External failures (network, API, DB) always have explicit handling
- Internal logic errors should fail loudly (throw), not return ambiguous values
- Error messages should help debugging — include what was attempted, what failed, and relevant identifiers
- Don't catch errors just to log and re-throw (unless adding context)
- Don't add error handling for scenarios that can't happen

---

## Testing

- New behavior needs tests — either in the same task or explicitly planned
- Tests verify outcomes, not implementation details
- Tests are isolated — no shared mutable state between tests
- Each test has at least one meaningful assertion
- Don't test framework behavior or trivial getters/setters
- Edge cases to consider: null/empty, boundary values, error paths

---

## Comments

- Default to writing no comments
- Only add one when the WHY is non-obvious: hidden constraint, subtle invariant, workaround for specific bug
- Never explain WHAT the code does (well-named identifiers do that)
- Never reference the current task/ticket (that belongs in the commit message)
- Never write multi-paragraph docstrings or comment blocks

---

## Human-in-the-Loop

- After implementing each discrete change: explain what changed and why (2-3 sentences)
- Wait for confirmation before proceeding to the next change
- Never batch multiple unrelated changes silently
- If unsure about an approach: present options, don't guess
- If something contradicts the plan or expectations: STOP and explain
