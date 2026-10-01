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
| deliver a reminder | the same `scripts/*.sh` on both: `--message` prints it plain, the JSON envelope is Claude Code's |

## Invoking one skill from another

The same rule, one level up. A skill that tells the agent to *invoke another
skill* names the capability, and the skill being named has an
environment-specific **id**: `/workflow-dev:<name>` on Claude Code,
`workflow-dev-<name>` on OpenCode. The plugin relies on this — `implement` and
`validate` hand off to `summarize-changes`, and `init` runs `setup-models`
inline on the missing-or-stale path — so a handoff written now carries **both**
ids rather than assuming one harness's form. Handoffs that name only the Claude
Code form predate this rule and are not corrected here; the omission is a
wording gap, not a break.

It is a textual instruction to the agent, not a platform guarantee: nothing
forces skill B to run because skill A's documentation says so. Where a behavior
must hold regardless of which skill ran (or whether any did), it belongs in a
hook, not in a skill telling another skill what to do.

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

It also cannot reach text that is *right*. A file an agent reads may name a tool
correctly for the harness it describes — this repo's own notes on Claude Code's
`PreToolUse:Bash` hook do — and still prime that name in a session on OpenCode,
where no such tool exists. One of the `No tool named "bash"` errors on record
came right after an agent read exactly such a note, and no wording rule or guard
(`scripts/harness-vocab.test.sh` excludes those notes, deliberately) can fix
text that is not wrong.

On OpenCode the plugin covers part of that gap: in a workflow-dev project it
adds the session's live tool names to every model call (`opencode/plugin.ts`,
read from `event.tools`, never a list of its own). That steers the model at the
moment of the call; it does not bind it. Whether that plugin is actually running
is a separate question with its own check — `scripts/opencode-live-check.sh` —
because a plugin that failed to load is otherwise silent.

Browser and device tooling is a separate capability contract with its own
examples — `../skills/manual-qa/references/tool-mapping.md`.
