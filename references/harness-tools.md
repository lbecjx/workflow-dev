<!--
workflow-dev — a persistent-context development workflow for Claude Code
Copyright (C) 2026  lbecjx

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version. See LICENSE for the full text.
-->

# Name the capability, not the tool

Skills name the **capability**. The name a capability happens to have is the
session's business: tool names change between releases (`Task` became
`Agent`), MCP tools carry a per-session server prefix, and the catalog an agent
sees depends on its configuration. Writing one tool name as if it were
universal is how the plugin ends up telling an agent to call a tool that isn't
there.

## The rule

Say what has to happen ("run a command", "ask the human"), not one name for it.
List known names, if at all, as **examples** — never as the name.

The failure this prevents is not hypothetical. Recorded 2026-09-29: an agent
called a tool named `bash` — a lowercase spelling of Claude Code's `Bash`, picked
up from text written for a different tool set — and got:

```
No tool named "bash" is currently available. Please use a tool from the available tool list.
```

`AskUserQuestion`, `Agent` and `Task` are the same class: names that are real in
one session and absent in another.

## Capability → names seen in Claude Code

Every entry here is an **example**. None of them is the name to hardcode.

| Capability | Names seen |
|---|---|
| run a command | `Bash` |
| read a file | `Read` |
| write or edit a file | `Write` / `Edit` |
| find files by name | `Glob` |
| search file contents | `Grep` |
| spawn a sub-agent, naming its role as the type | `Agent` (formerly `Task`) |
| ask the human a question | `AskUserQuestion` — word it per `user-language.md` |
| load a skill | `Skill` |
| call an MCP server's tool | `mcp__<server>__<tool>` |
| receive a lifecycle event | `hooks/hooks.json` (see `../hooks/README.md`) |

## Invoking one skill from another

The same rule, one level up. A skill that tells the agent to *invoke another
skill* names the capability; the skill's id is `/workflow-dev:<name>`. The plugin
relies on this — `implement` and `validate` hand off to `summarize-changes`, and
`init` runs `setup-models` inline on the missing-or-stale path.

It is a textual instruction to the agent, not a platform guarantee: nothing
forces skill B to run because skill A's documentation says so. Where a behavior
must hold regardless of which skill ran (or whether any did), it belongs in a
hook, not in a skill telling another skill what to do.

## The set is not fixed — treat every list as an example

The catalog varies by agent, model and configuration: a session can advertise a
tool another session lacks. Read the live catalog rather than assuming — and
where the only way to know is to look, say so instead of naming a tool.

## What this achieves, and what it cannot

It stops this plugin from *priming* a name that doesn't exist in the session
reading it. That is the whole of what a skill can do here: a skill is read
before the call, not at it, so it can shape the wording that reaches the model
and not the model's choice. It cannot make an agent call the right tool, and
nothing in this repo should claim otherwise.

Browser and device tooling is a separate capability contract with its own
examples — `../skills/manual-qa/references/tool-mapping.md`.
