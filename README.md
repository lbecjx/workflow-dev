# workflow-dev

A human-piloted, agent-executed development workflow for [Claude Code](https://code.claude.com). Bootstraps a persistent per-project context from Jira, Confluence, and GitHub via MCP — or from a local Markdown file when no issue tracker is available — then decomposes it into a task plan, executes it with enforced quality rules, and runs a multi-dimensional quality gate before every commit.

Working on a side project, freelancing, or just prefer to keep everything local? [`local-backlog`](https://github.com/lbecjx/local-backlog) keeps your stories as plain Markdown right next to your code — no cloud account, no subscription, nothing to sync. It is a Claude Code plugin too, and the two are built to work together: `init` picks up any local `.md` file as its story source out of the box.

Context survives compaction and new sessions. Mechanical state (plan progress, files touched) is kept current automatically as work proceeds; decisions, discoveries, and progress notes are saved **on request** — never automatically, and never without your review.

## Save point

`save` tracks how far the last save read, so a later save only reads what is genuinely new. The position is stored per story in `.workflow-dev/context/.compaction-state/<STORY>.json`: the session transcript the hooks recorded, plus a line count into it. When no transcript is known, `save` says so rather than reporting "nothing unsaved".

## What this is not

- **Not a spec or design tool** — it never *writes* specs or design documents; it *consumes* them (Jira stories, Confluence TDDs and ADRs, a local Markdown file) and turns them into working context.
- **Not a roadmap planner** — it doesn't propose epics, milestones, or phases on its own. The `/workflow-dev:plan` skill does one narrow thing: it splits *one story's* acceptance criteria into ordered task groups, only when you ask, and only after you approve.
- **Not autonomous** — you pilot, the agent executes. It works one task at a time and checks in before moving on, so it never lands a large change without you in the loop. (An opt-in [autonomous mode](#autonomous-mode-opt-in) exists for a single story; the default never changes.)

## Autonomous mode (opt-in)

The workflow is human-piloted by default and stays that way — see [What this is not](#what-this-is-not). For a story you want to run end-to-end without approving each step, there is an **opt-in** autonomous mode: tell the agent "ve autónomo" / "run this autonomously" — or pick it when `init` asks how the story should run — and it records `Autonomous mode: on` in the story's Decisions (the row lives in the story file, so it survives new sessions and `resume` shows it) and runs `init → plan → implement → validate → summarize` without pausing between tasks.

Autonomous mode removes the per-step confirmations, not the guardrails:

- **Decisions are inferred, recorded, and reported.** Each decision point the human would normally answer is resolved with an explicit rule, written to the story's Decisions table, and surfaced in an end-of-run report. Nothing is silently skipped.
- **A hard boundary always applies.** It never pushes a protected branch, never merges, never skips the adversarial pass when it would run, never invents acceptance criteria, and never bypasses the AI/agent attribution block — the one rule with no bypass, autonomous or not.
- **The quality gate is load-bearing.** A blocking finding stops the run; it is never downgraded to a warning so the run can continue.
- **It drafts, it never opens the PR.** The commit message and PR text are drafted and marked reviewed, then handed to you in the report. `git commit` and `gh pr create` remain your call.

At the end it reports what it did, every decision it made for you (with the inferred reason), what it deferred, and the story's cost from the durable ledger. Full rules in [`references/autonomous-mode.md`](./references/autonomous-mode.md).

## Skills

| Skill | What it does |
|---|---|
| `/workflow-dev:init` | Bootstraps persistent context for a story — from Jira, Confluence, GitHub, the repo, or a local `.md` file |
| `/workflow-dev:plan` | Decomposes a story into ordered, validation-aware task groups |
| `/workflow-dev:implement` | Executes the next task group under enforced coding standards, human-in-the-loop |
| `/workflow-dev:validate` | Runs a multi-dimensional quality gate (security, types, tests, architecture, algorithmic integrity, an adversarial correctness pass) before commit |
| `/workflow-dev:manual-qa` | Verifies a story's Acceptance Criteria in a real browser/device (run by validate when the story opts in) |
| `/workflow-dev:summarize-changes` | Drafts and reviews the commit message, PR title, and PR description before commit |
| `/workflow-dev:save` | Persists decisions, discoveries, and progress into the context files |
| `/workflow-dev:resume` | Loads the persistent context at the start of a new session |
| `/workflow-dev:refresh` | Checks every context source (Jira, Confluence, GitHub, the repo) for drift since the last save |
| `/workflow-dev:setup-models` | Binds each agent role to a model Claude Code offers, so mechanical sub-agent work runs on a fast model and judgment work on a strong one (one-time setup) |
| `/workflow-dev:usage` | Shows the active story's total cost and tokens, totalled from its durable ledger across sessions |
| `/workflow-dev:help` | Shows current status and suggests the next step |

## Hooks

This plugin also ships hooks that keep the workflow above easy to follow — none of them act on their own (they ask first), with one hard exception: AI/agent attribution in a commit or PR message is blocked outright.

- **`SessionStart`** — suggests the right next skill (`resume`, `plan`, `implement`...) based on the active story's real state, at the start of a new session.
- **`PreCompact`** — warns before context gets compacted if there's an in-progress story, since decisions made purely in conversation (no file changes) can otherwise be lost.
- **`UserPromptSubmit` / `PostToolUse`** — reminds you to `/workflow-dev:save` when there are pending changes to persist.
- **`PreToolUse`** (before a real `git commit`) — asks you to confirm `/workflow-dev:validate` passed on the current changes, or lets a deliberate deferral through with a visible note.
- **`PreToolUse`** (before a real `git commit` / `gh pr create` / `gh pr edit`) — in a workflow-dev project, asks you to confirm the message passed the Git History Disclosure review; blocks outright on any AI/agent attribution, in any repo.

  "Real" means the command itself, not a command that mentions one: an `echo`, a `grep`, a heredoc that writes about a commit, `git commit-tree` and the like stay silent. `git -C <dir> commit`, `git -c k=v commit` and a commit after other commands are caught. When a command is wrapped where it cannot be read (`bash -c`, `eval`), it asks rather than guessing, and never blocks.
- **`PostToolUse`** (after a real `gh pr create` / `gh pr edit` succeeds) — reminds you of the PR's full URL, so it gets relayed as plain text instead of staying buried in a Markdown link label. `gh pr edit` whose own output carries no URL falls back to a read-only `gh pr view --json url`.
- **`PreToolUse`** (before a `workflow-dev` skill runs) and **`UserPromptExpansion`** (when you type one directly) — has the agent ask you one question about the agent roles before the skill goes on: bind them to models, or keep the default for this story or this repo.
- **`PreToolUse`** (before a `workflow-dev` skill runs) and **`UserPromptExpansion`** (when you type one directly) — tells you, at most once per session per version, when a newer copy of this plugin is on GitHub (with the update command) or already on disk and only needs a session restart. Purely informational: it never asks, blocks, or denies.

## Naming tools

The skills name the **capability** — "run a command", "ask the human", "read a file" — and let the session supply the tool, since tool names change between releases and MCP tool names depend on how each server was configured. The examples are in [`references/harness-tools.md`](./references/harness-tools.md).

## Model tiering

`workflow-dev` spawns sub-agents for four jobs: running a fixed checklist (Verification, the Part 12 text review), making a contested call (Security, Architecture, Algorithmic Integrity), hunting adversarially for the input that breaks a change (Adversarial Correctness), and studying the story and the repo to draft the plan (`init`'s research, `plan`'s task groups). The plugin never names a model — it names **roles**, `wd-operator`, `wd-judge`, `wd-adversary` and `wd-architect`, and you bind each role to a model Claude Code actually offers:

```
/workflow-dev:setup-models
```

Setup reads the live model list (from a configured gateway, or asks you), asks for a model per role (paged, with a hint that says what the role is for), and writes one agent file per role into your own config, `~/.claude/agents/<role>.md`. Its `model:` takes one of Claude Code's aliases, a full model ID, or `inherit`.

Each generated file carries a hash of the role registry, so a later run — or the reminder hook — can tell a current binding from a stale one.

**The Claude Code limit.** Claude Code routes a sub-agent to its own models. A non-Claude model per sub-agent needs a router or gateway in front of it, and that gateway is also the only way setup can *enumerate* models there (`GET <base>/v1/models`). Without one, setup asks you to type the name yourself — run `/model` to see it — rather than inventing a list. Documented as a fallback, not a promise.

**Degrades honestly.** When a sub-agent's model can't be selected — the roles are unbound or stale and you haven't chosen the default for this repo or story — the workflow says so and runs everything on your default model. It never pretends the tiering happened.

**Init self-heals.** Before `init` spawns its research sub-agents it runs this same check itself, and when the roles are missing or stale it walks you through setup **in the same session** before carrying on — no detour to a second command and back. Bindings current, and it says nothing. A run outside Claude Code or an unreadable role registry is reported and it proceeds on the default, as above. When the roles are unbound the hook has the agent put one question to you before the skill goes on, also in autonomous mode: configure the agents (`/workflow-dev:setup-models`, listed first), keep the default model for this story, or keep it for this repo. The two defaults are recorded where the hook reads them (the story's Decisions, or `tiering` in `.workflow-dev/config.json`) and silence the reminder; the skill goes on after you answer. The hook opens no dialog, so there is no "don't ask again" button. `init` also checks the roles itself (below) as a backstop. One caveat: an agents directory being created for the first time isn't picked up until you restart, so a first-time binding takes effect from the next session rather than the rest of this one — init says so when that applies.

**The session's own model.** The session itself still talks with you and implements each task group, so `init` recommends a tier for it once per story, without asking: intermediate when `wd-architect`, `wd-judge` and `wd-adversary` are bound to a top-tier model (the heavy reasoning already runs there), top tier otherwise or when the story touches writes, concurrency or security, and never the fast tier. It says nothing when the session already runs at that tier.

**Updating.** Roles live in the plugin; your bindings live in your config, which a plugin update doesn't touch. When a release changes a role's definition the reminder flags the binding as stale, and re-running setup regenerates it while keeping the model you picked. The plugin ships no `agents/` directory of its own, deliberately: a plugin agent gets a namespaced name and can't carry your model.

**Keeping the default model.** There is no machine-wide opt-out: either you bind the agents once, or you keep the default per repo or per story. For a repo, set `"tiering": "default"` in `.workflow-dev/config.json`; for a story, add a `Tiering: default model` row to its Decisions. The reminder's question offers both, and records the one you pick. A `~/.workflow-dev/tiering.json` left by an older version is ignored.

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
