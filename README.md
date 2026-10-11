# workflow-dev

Guardrails for agent-driven development in [Claude Code](https://code.claude.com). You pilot and the agent executes, and every step leaves something you can check: each story's context stays on disk through compaction and new sessions, a quality gate runs before every commit, and you see what each story cost.

No issue tracker? Pair it with [`local-backlog`](https://github.com/lbecjx/local-backlog) ([more below](#recommended-alongside-this-plugin)).

## Quick start

```
/plugin marketplace add lbecjx/claude-plugins
/plugin install workflow-dev@lbecjx
```

1. **`/workflow-dev:init <story>`**: a Jira link or ID, or the path to a Markdown file. It reads the story, its linked docs and your repo, and writes the context the work runs on. It asks once whether to run the story step by step or [autonomously](#autonomous-mode-opt-in).
2. **`/workflow-dev:plan`**: splits the story's acceptance criteria into ordered task groups. Nothing starts until you approve them.
3. **`/workflow-dev:implement`**: runs the next task group one task at a time and explains each change.
4. **`/workflow-dev:validate`**: checks the change across several dimensions to make sure the story meets its quality bar, before you commit.
5. **`/workflow-dev:summarize-changes`**: drafts the commit message and PR text. Nothing is committed until you say yes.

Progress is tracked as you go. Decisions and discoveries are saved with `/workflow-dev:save`, and never without your review. In a new session, `/workflow-dev:resume` picks the story up where you left it.

## Requirements

- Claude Code.
- `gh` (GitHub CLI), if you want the agent to open pull requests.
- MCP servers for Jira, Confluence or GitHub, only if your stories or docs live there. Don't use them, or would rather not? Try [`local-backlog`](https://github.com/lbecjx/local-backlog): describe what you want built and you have a structured story in your repo in seconds, ready to hand to `init`. No account, no setup.
- `jq`, recommended.

**Platform.** workflow-dev was built, used day to day and tested on macOS. It has not been tested on Windows or Linux.

## What this is not

- **Not a spec or design tool** — it never *writes* specs or design documents; it *consumes* them (Jira stories, Confluence TDDs and ADRs, a local Markdown file) and turns them into working context.
- **Not a roadmap planner** — it doesn't propose epics, milestones, or phases on its own. The `/workflow-dev:plan` skill does one narrow thing: it splits *one story's* acceptance criteria into ordered task groups, only when you ask, and only after you approve.
- **Not autonomous** — you pilot, the agent executes. It works one task at a time and checks in before moving on, so it never lands a large change without you in the loop. (An opt-in [autonomous mode](#autonomous-mode-opt-in) exists for a single story; the default never changes.)

## Autonomous mode (opt-in)

Step by step is the default, and stays that way. For a story you want run end to end, start it with `/workflow-dev:init-auto <story>`, pick autonomous when `init` asks, or tell the agent "run this autonomously". It then goes through `init → plan → implement → validate → summarize` without stopping between steps.

It drops the per-step confirmations, not the guardrails:

- **It asks only before it starts, and only what would block it.** That means an ambiguous acceptance criterion, say, and whether commits may credit the agent as co-author when the repo has no answer yet. After that it asks nothing.
- **It never overrides a story you set to step by step.** It asks you first.
- **Every decision it makes for you is written down,** with its reason, and listed in the final report.
- **It has hard limits.** It never pushes a protected branch, never merges, never skips the adversarial check when it would run, never invents acceptance criteria, and never credits the AI unless you allowed it.
- **A blocking finding is never downgraded** to a warning to keep the run going.
- **It keeps your Mac awake only while it works.** The screen still turns off and locks.
- **It stops before committing.** It drafts the commit message and PR text; it commits or opens the PR only after your yes.

At the end you get a report: what it did, every decision it made for you, what it left for you, and the story's [cost](#story-cost).

## Story cost

Know what each story cost. workflow-dev adds up what its own skills spend on a story, including the plugin evals `validate` runs. The total carries across sessions, even after you close one. Chat outside the workflow's skills is not counted.

- **As you go:** each step ends with a line showing what it cost and the story's running total.
- **Any time:** `/workflow-dev:usage` shows the story's total and tokens, by stage, by session and by agent, with the model each agent ran on.
- **At the close:** `summarize-changes` ends with a cost report, one row per skill:

  ```
  Closing cost report: PROJ-123
    skill                runs  cost
    init                    1  $1.2031
    implement               1  ≈$18.8618
    validate                1  ≈≥$23.4937
        orchestrator           $18.4199  models claude-opus-5-5
        wd-adversary           ≥$3.9758  models claude-opus-5-5
        wd-operator            ≥$0.5354  models claude-haiku-4-5-20251001
    total                   3  ≈≥$43.5586
  ```

Some figures are estimates: `≈` marks an estimate and `≥` a minimum.

**In your status line.** Every story's cost is also kept in a read-only summary that a status line or dashboard can read; see [`references/usage-api.md`](./references/usage-api.md).

## Skills

| Skill | What it does |
|---|---|
| `/workflow-dev:init` | Reads the story (Jira, Confluence, GitHub or a local `.md` file) and your repo, and writes the context the work runs on |
| `/workflow-dev:init-auto` | Starts a story with `init` in [autonomous mode](#autonomous-mode-opt-in) — same input as `init` |
| `/workflow-dev:plan` | Splits the story into ordered task groups for you to approve |
| `/workflow-dev:implement` | Runs the next task group one task at a time, explaining each change |
| `/workflow-dev:validate` | Checks the change across several dimensions to make sure the story meets its quality bar, before you commit. It fails only on defects real use can reach, and stops fixing the same finding after a set number of rounds |
| `/workflow-dev:manual-qa` | Verifies a story's Acceptance Criteria in a real browser/device (run by validate when the story opts in) |
| `/workflow-dev:summarize-changes` | Drafts and reviews the commit message, PR title, and PR description before commit |
| `/workflow-dev:save` | Persists decisions, discoveries, and progress into the context files |
| `/workflow-dev:resume` | Loads the persistent context at the start of a new session |
| `/workflow-dev:refresh` | Checks every context source (Jira, Confluence, GitHub, the repo) for drift since the last save |
| `/workflow-dev:setup-models` | Binds each agent role to a model Claude Code offers, so mechanical sub-agent work runs on a fast model and judgment work on a strong one (one-time setup) |
| `/workflow-dev:usage` | Shows the active story's cost and tokens, totalled across sessions ([Story cost](#story-cost)) |
| `/workflow-dev:help` | Shows current status and suggests the next step |

## What you'll see along the way

workflow-dev also watches for the moments a step is easy to forget. It asks; it never acts on its own. The one exception is crediting an AI in a commit or PR, which is blocked unless you allowed it.

- **At the start of a session:** the next skill to run, based on where the story really is.
- **Before the context gets compacted:** a warning when a story is in progress, so decisions made only in chat are not lost.
- **When something is unsaved:** a reminder to run `/workflow-dev:save`.
- **Before a commit:** a check that `validate` passed on these exact changes, or a visible note when you chose to validate once at the end of the story.
- **Before a commit or PR:** a check that the message went through review. Commits and PRs never credit an AI unless you said yes for that repo; `summarize-changes` asks you once, and you can change the answer by telling the agent.
- **After a PR is opened:** its full URL, as plain text.
- **When the agent roles are not set up:** one question before the skill goes on (see [Model tiering](#model-tiering)).
- **When a new version is out:** a one-time note with the update command.

Questions and these dialogs come in the language you write in. The dialogs cover English, Spanish, French, Portuguese, German, Italian, Chinese, Japanese, Korean and Russian; any other language gets English.

## Attention sound

workflow-dev speaks only when it needs you, with a short line that tells you what is waiting before you look at the screen:

| You hear | When |
|---|---|
| "I need your input." | plan approval, the adversarial-depth choice in `validate`, any question asked through the ask-question tool in a workflow-dev project |
| "Hello? Are you there?" … "I need your input." | the same question in the middle of an autonomous run, when you are likely away |
| "I need your permission." | a permission prompt |
| "Ready to commit." | the commit message or PR text is ready for your yes |
| "Pull request created!" | the PR was just opened |
| "Task completed." | a task group closed in `implement`, a stand-alone `manual-qa` report with every check passing |
| "Validation passed." | `validate` passed |
| "Something went wrong." | `validate` failed, a manual check failed, or an autonomous run stopped on a problem |
| "Context saved." | a save you asked for finished |
| a fanfare, then "Congrats! Story complete." | the story is done |

It stays quiet the rest of the time: not after every response, and not in CI or a non-interactive session (`claude -p`). Each event sounds once.

**Turn it off or use your own sound** in the `env` block of `~/.claude/settings.json`, then restart Claude Code:

```json
{
  "env": {
    "WORKFLOW_DEV_ATTENTION": "off",
    "WORKFLOW_DEV_ATTENTION_SOUND": "/Users/you/Sounds/ding.wav"
  }
}
```

`WORKFLOW_DEV_ATTENTION` set to `off` silences it. `WORKFLOW_DEV_ATTENTION_SOUND` plays one file of yours for every event instead of the spoken lines.

**Where and how loud.** The first story you start on a machine asks where the alerts play (your own speakers, so you hear them even with a headset on, or the default output) and how loud. It remembers the answer for every repo. To change it, run from the installed plugin's folder:

```sh
scripts/attention-alert.sh devices                             # list outputs
scripts/attention-alert.sh set-device "MacBook Pro Speakers"   # or: set-device default
scripts/attention-alert.sh set-volume 50                       # 0-100
```

**Already have an alert sound in Claude Code?** A `Stop` or `Notification` hook of your own that plays a sound fires after every response and drowns this one out. Remove it from the `hooks` block of `~/.claude/settings.json` to hear only workflow-dev.

## Model tiering

Put the heavy thinking on a strong model and the routine checks on a fast one, and choose which is which. workflow-dev's sub-agents run under four roles (`wd-operator`, `wd-judge`, `wd-adversary` and `wd-architect`), and you bind each role to a model once:

```
/workflow-dev:setup-models
```

- **Not set up yet?** The first time, it asks whether to set the roles up or keep your default model. Until you do, everything runs on your default model, and it tells you so.
- **Keep the default model on purpose,** for a repo or a single story: pick that answer when it asks. For a repo, it is `"tiering": "default"` in `.workflow-dev/config.json`.
- **Models outside Claude** need a gateway in front of Claude Code.
- **Updates keep your choice.** If a release changes a role, it asks you to run `setup-models` again, and keeps the model you picked.
- `init` also recommends a model for the session itself, once per story.

## Recommended alongside this plugin

Keep your backlog where your code is. [`local-backlog`](https://github.com/lbecjx/local-backlog) creates and browses stories as plain Markdown in your repo, with auto-incrementing codes: no cloud account, no subscription, nothing to sync. `/workflow-dev:init` takes any of its stories as they are.

They're independent plugins: install either one on its own, or both.

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
