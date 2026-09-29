# workflow-dev

A human-piloted, agent-executed development workflow for [Claude Code](https://code.claude.com). Bootstraps a persistent per-project context from Jira, Confluence, and GitHub via MCP — or from a local Markdown file when no issue tracker is available — then decomposes it into a task plan, executes it with enforced quality rules, and runs a multi-dimensional quality gate before every commit.

Context survives compaction and new sessions. Mechanical state (plan progress, files touched) is kept current automatically as work proceeds; decisions, discoveries, and progress notes are saved **on request** — never automatically, and never without your review.

## What this is not

- Not a spec framework — it doesn't produce design documents.
- Not a planner — it doesn't propose roadmaps or phases on its own.
- Not autonomous — it never writes a large change without checking in first.

## Skills

| Skill | What it does |
|---|---|
| `/workflow-dev:init` | Bootstraps persistent context for a story — from Jira, Confluence, GitHub, the repo, or a local `.md` file |
| `/workflow-dev:plan` | Decomposes a story into ordered, validation-aware task groups |
| `/workflow-dev:implement` | Executes the next task group under enforced coding standards, human-in-the-loop |
| `/workflow-dev:validate` | Runs a multi-dimensional quality gate (security, types, tests, architecture, an adversarial correctness pass) before commit |
| `/workflow-dev:manual-qa` | Verifies a story's Acceptance Criteria in a real browser/device (run by validate when the story opts in) |
| `/workflow-dev:summarize-changes` | Drafts and reviews the commit message, PR title, and PR description before commit |
| `/workflow-dev:save` | Persists decisions, discoveries, and progress into the context files |
| `/workflow-dev:resume` | Loads the persistent context at the start of a new session |
| `/workflow-dev:refresh` | Checks every context source (Jira, Confluence, GitHub, the repo) for drift since the last save |
| `/workflow-dev:setup-models` | Binds each agent role to a model the harness offers, so mechanical sub-agent work runs on a fast model and judgment work on a strong one (one-time setup) |
| `/workflow-dev:help` | Shows current status and suggests the next step |

## Hooks

This plugin also ships hooks that keep the workflow above easy to follow — none of them act on their own (they ask first), with one hard exception: AI/agent attribution in a commit or PR message is blocked outright.

- **`SessionStart`** — suggests the right next skill (`resume`, `plan`, `implement`...) based on the active story's real state, at the start of a new session.
- **`PreCompact`** — warns before context gets compacted if there's an in-progress story, since decisions made purely in conversation (no file changes) can otherwise be lost.
- **`UserPromptSubmit` / `PostToolUse`** — reminds you to `/workflow-dev:save` when there are pending changes to persist.
- **`PreToolUse`** (before `git commit`) — asks you to confirm `/workflow-dev:validate` passed on the current changes, or lets a deliberate deferral through with a visible note.
- **`PreToolUse`** (before `git commit` / `gh pr create` / `gh pr edit`) — asks you to confirm the message passed the Git History Disclosure review; blocks outright on any AI/agent attribution.
- **`PreToolUse`** (before a `workflow-dev` skill runs) and **`UserPromptExpansion`** (when you type one directly) — asks you to bind the agent roles to models, until you do or explicitly opt out.

On **OpenCode** these hooks do not run at all — `hooks/hooks.json` is Claude Code's own format, not a portable one. The reminder there is delivered by a plugin instead, and OpenCode's plugin API has no way to ask: it can only intercept a tool call, so the reminder arrives as a note attached to the skill's own output and the skill still runs. It targets OpenCode 2's plugin API (`export default { id, setup }`, `ctx.tool.hook(...)`); the v1 API described under `/docs/plugins` no longer loads. Installing it is part of the OpenCode setup — see [Installation](#installation).

## Tool names per harness

The skills name the **capability** — "run a command", "ask the human", "read a file" — and let your environment supply the name. The same capability is a different tool in each harness (`shell` on OpenCode, `Bash` on Claude Code; `question` / `AskUserQuestion`; `subagent` / `Agent` or `Task`), and the set varies per session too, so no hardcoded name stays right for long. The per-harness mapping is in [`references/harness-tools.md`](./references/harness-tools.md).

The same applies to how you invoke a skill: `/workflow-dev:init` on Claude Code is `workflow-dev-init` on OpenCode.

## Model tiering

`workflow-dev` spawns sub-agents for two very different jobs: running a fixed checklist (Verification, the Part 12 text review) and making a contested call (Security, Architecture, Adversarial Correctness). The plugin never names a model — it names **roles**, `wd-operator` and `wd-judge`, and you bind each role to a model your harness actually offers:

```
/workflow-dev:setup-models
```

Setup reads the live model list from the harness, asks for a provider and then a model per role (paged, with a hint that says what the role is for), and writes one agent file per role into your own config:

| Harness | Where the binding is written | What `model:` takes |
|---|---|---|
| Claude Code | `~/.claude/agents/<role>.md` | one of its aliases, a full model ID, or `inherit` |
| OpenCode | `~/.config/opencode/agents/<role>.md` | any `provider/model` it offers |

Each generated file carries a hash of the role registry, so a later run — or the reminder hook — can tell a current binding from a stale one.

**The Claude Code limit.** Claude Code routes a sub-agent to its own models. A non-Claude model per sub-agent needs a router or gateway in front of it, and that gateway is also the only way setup can *enumerate* models there (`GET <base>/v1/models`). Without one, setup asks you to type the name yourself — run `/model` to see it — rather than inventing a list. Documented as a fallback, not a promise; OpenCode has no such limit.

**Degrades honestly.** When the harness can't select a model per sub-agent — the roles are unbound or stale and you haven't opted out — the workflow says so and runs everything on your default model. It never pretends the tiering happened.

**Updating.** Roles live in the plugin; your bindings live in your config, which a plugin update doesn't touch. When a release changes a role's definition the reminder flags the binding as stale, and re-running setup regenerates it while keeping the model you picked. The plugin ships no `agents/` directory of its own, deliberately: a plugin agent gets a namespaced name and can't carry your model.

**Opting out.** To run everything on your default model and stop being asked, write:

```json
{ "optOut": true }
```

to `~/.workflow-dev/tiering.json`.

## Installation

**Claude Code:**

```
/plugin marketplace add lbecjx/claude-plugins
/plugin install workflow-dev@lbecjx
```

**OpenCode** has no marketplace step: the skills and the plugin are installed separately, by hand. Clone the plugin, link each skill into OpenCode's skills directory, and link the plugin entry point (OpenCode auto-loads plugins from `~/.config/opencode/plugins/`, and this checkout sits one level below it):

```
mkdir -p ~/.config/opencode/plugins/lbecjx ~/.config/opencode/skills

git clone https://github.com/lbecjx/workflow-dev \
  ~/.config/opencode/plugins/lbecjx/workflow-dev

for s in ~/.config/opencode/plugins/lbecjx/workflow-dev/skills/*/; do
  ln -sfn "../plugins/lbecjx/workflow-dev/skills/$(basename "$s")" \
          "$HOME/.config/opencode/skills/workflow-dev-$(basename "$s")"
done

ln -sfn ~/.config/opencode/plugins/lbecjx/workflow-dev/opencode/plugin.ts \
        ~/.config/opencode/plugins/workflow-dev.ts
```

The links use `-sfn`: `-f` replaces a link that is already there instead of failing, and `-n` keeps the target's own symlink from being followed, so re-running the block after an update is safe. After a change to the plugin — not to the skills — run `opencode service restart`. The background service caches each plugin's load result, so a plugin that fails to load once keeps failing (logged only as a warning) until the service restarts.

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
