<!--
workflow-dev — a persistent-context development workflow for Claude Code
Copyright (C) 2026  lbecjx

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version. See LICENSE for the full text.
-->

# Tool names per harness

Skills name the **capability**. The name a capability happens to have is the
environment's business — the OS, the harness, whatever the session actually
offers. Writing a harness-specific name as if it were universal is how the
plugin ends up telling an agent to call a tool that isn't there.

## The rule

Say what has to happen ("run a command", "ask the human"), not one harness's
name for it. List known names, if at all, as **examples** — never as the name.

The failure this prevents is not hypothetical. Recorded 2026-09-29: an agent
running under OpenCode called a tool named `bash` — OpenCode 1's name for the
shell, and Claude Code's `Bash` in lowercase — and got:

```
No tool named "bash" is currently available. Please use a tool from the available tool list.
```

`AskUserQuestion`, `Agent` and `Task` are the same class: real tool names in
Claude Code or OpenCode, absent in the other.

## Capability → names seen in the wild

Every entry here is an **example**. None of them is the name to hardcode.

| Capability | Names seen in the wild |
|---|---|
| run a command | `shell` (OpenCode), `Bash` (Claude Code), terminal / console / `bash` — whatever the SO and environment call it |
| read a file | `read` (OpenCode), `Read` (Claude Code) |
| write or edit a file | `write` / `edit` (OpenCode), `Write` / `Edit` (Claude Code) |
| find files by name | `glob` / `Glob` |
| search file contents | `grep` / `Grep` |
| spawn a sub-agent, naming its role as the type | `subagent` / `Agent` (also `Task`) |
| ask the human a question | `question` / `AskUserQuestion` |
| load a skill | `skill` / `Skill` |
| call an MCP server's tool | `<server>.<tool>` (OpenCode) / `mcp__<server>__<tool>` (Claude Code) |
| receive a lifecycle event | an OpenCode plugin / Claude Code's `hooks/hooks.json` (see `../hooks/README.md`) |

## The set is not fixed — treat every list as an example

Measured 2026-09-29 on OpenCode 2.0.19: one session advertised `edit` and
`write`; another advertised `patch` where that session had `edit`/`write`. The
catalog varies by harness, agent and model. When a harness exposes its live
catalog, read it rather than assuming — and where the only way to know is to
look, say so instead of naming a tool.

## What this achieves, and what it cannot

It stops this plugin from *priming* a name that doesn't exist in the harness
reading it. That is the whole of what a skill can do here: a skill is read
before the call, not at it, so it can shape the wording that reaches the model
and not the model's choice. It cannot make an agent call the right tool, and
nothing in this repo should claim otherwise.

Browser and device tooling is a separate capability contract with its own
examples — `../skills/manual-qa/references/tool-mapping.md`.
