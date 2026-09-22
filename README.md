# workflow-dev

A human-piloted, agent-executed development workflow for [Claude Code](https://code.claude.com). Bootstraps a persistent per-project context from Jira, Confluence, and GitHub via MCP — or from a local Markdown file when no issue tracker is available — then decomposes it into a task plan, executes it with enforced quality rules, and runs a multi-dimensional quality gate before every commit.

Context survives compaction and new sessions. It's saved explicitly on request — never automatically, and never without your review.

## What this is not

- Not a spec framework — it doesn't produce design documents.
- Not a planner — it doesn't propose roadmaps or phases on its own.
- Not autonomous — it never writes a large change without checking in first.

## Skills

| Skill | What it does |
|---|---|
| `/workflow-dev:init` | Bootstraps persistent context for a story — from Jira, Confluence, GitHub, or a local `.md` file |
| `/workflow-dev:plan` | Decomposes a story into ordered, validation-aware task groups |
| `/workflow-dev:implement` | Executes the next task group under enforced coding standards, human-in-the-loop |
| `/workflow-dev:validate` | Runs a multi-dimensional quality gate (security, types, tests, architecture, an adversarial correctness pass) before commit |
| `/workflow-dev:save` | Persists decisions, discoveries, and progress into the context files |
| `/workflow-dev:resume` | Loads the persistent context at the start of a new session |
| `/workflow-dev:refresh` | Checks Jira/Confluence/GitHub for drift since the last save |
| `/workflow-dev:help` | Shows current status and suggests the next step |

## Hooks

This plugin also ships three hooks that make the workflow above easier to keep up with — all advisory, none of them ever act without your confirmation:

- **`SessionStart`** — suggests the right next skill (`resume`, `plan`, `implement`...) based on the active story's real state, at the start of a new session.
- **`PreCompact`** — warns before context gets compacted if there's an in-progress story, since decisions made purely in conversation (no file changes) can otherwise be lost.
- **`PreToolUse`** (on `git commit`) — a non-blocking reminder to confirm `/workflow-dev:validate` passed on the current changes, if no matching record is found.

## Installation

```
/plugin marketplace add lbecjx/claude-plugins
/plugin install workflow-dev@lbecjx
```

## Recommended alongside this plugin

If you don't have a cloud-based issue/story tracker, we suggest also installing [`local-backlog`](https://github.com/lbecjx/local-backlog) — it creates and browses stories locally, in plain Markdown, with auto-incrementing codes. `/workflow-dev:init` natively accepts any local `.md` file as a story source, so anything `local-backlog` creates works as input here.

They're independent plugins, though — install either one on its own, or both; neither depends on the other.

## License

Licensed under the GNU General Public License v3.0 or later — see [LICENSE](./LICENSE) for the full text.

```
workflow-dev — a persistent-context development workflow for Claude Code
Copyright (C) 2026  lbecjx

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program. If not, see <https://www.gnu.org/licenses/>.
```

Author: lbecjx ([@lbecjx](https://github.com/lbecjx))
