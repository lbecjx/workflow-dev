---
name: resume
description: Loads the persistent context at session start. Reads REPO.md and the active story file, shows current state, and resumes work. Use when the user says "resume", "continue", "load context", or wants to continue working on a story.
---

<!--
workflow-dev — a persistent-context development workflow for Claude Code
Copyright (C) 2026  Luis Becjx

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version. See LICENSE for the full text.
-->

# Resume

## What this does

Loads the persistent context into the agent's working memory at the start of a session. The agent reads both context files, understands where work left off, and is immediately ready to continue — no re-asking, no re-exploring.

## When to use

- A new terminal is opened and the user wants to pick up a story
- The user says "resume," "continue," "load context"
- After a long break, to pick up exactly where things left off

## Execution

### Step 1: Find the context files

Look for `.workflow-dev/context/` in the current project and list its `.md` files:
- **REPO.md** — repo-level context, excluded from the story list
- **Everything else** — candidate story-context files

**No story files found:** tell the human: "No active stories in `.workflow-dev/context/`. Run `/workflow-dev:init <STORY-ID>` to start one." Stop here.

### Step 2: Ask which story to resume

Use `AskUserQuestion` to present the candidates:
- **Label:** the story ID (e.g. `PROJ-12710`). The most recently updated one gets a "(Recommended)" suffix.
- **Description:** the story title (its H1 header) plus its progress percentage.
- No preview needed.

```
Question: "Which story do you want to resume?"
Options:
- label: "PROJ-12710 (Recommended)", description: "Extend GET /invoices with cursor pagination and OpenAPI docs — 100%"
- label: "PROJ-12845", description: "Add retry logic to webhooks — 35%"
```

**Only one story file exists:** skip the question and load it directly.

### Step 3: Read the context files

**Always** use the Read tool explicitly on both files, even if they seem to already be in context (e.g. via a system reminder or an earlier read). The reads need to be visible in the execution trace so the human can confirm the context was actually internalized.

1. Read **REPO.md** — internalize repo knowledge: stack, conventions, prohibitions, good practices.
2. Read the **selected story file** — internalize its state: ACs, decisions, discoveries, progress, next step.
3. **Check for related stories:** if the story file names blockers, linked issues, or sibling stories (in "Blockers / Linked Issues," epic phases, etc.), look for their context files — in the same `.workflow-dev/context/` directory, or in a related repo if the dependency is cross-project (check paths noted in the story's own notes). Read whatever exists; it carries contract details, decisions, and discoveries that bear on the current story.

### Step 4: Quick repo check

1. `git status` — any uncommitted changes?
2. `git log --oneline -5` — any commits landed since the last session?
3. Is the branch behind its base? (`git rev-list --count HEAD..origin/[base]`)

### Step 5: Present status

Give the human a concise summary:

```
Context loaded — [STORY-ID]: [short title]

Status:  [progress %] — [current AC or next step]
Branch:  [branch name] [up to date | X commits behind base]
Last saved: [timestamp]

Pending:
- [next step from the persistent context]

Continue?
```

Call out uncommitted changes or a behind-base branch if either applies.

### Step 6: Ready to work

The agent is now fully contextualized:
- What the project is and how it works (REPO.md)
- What the story is about — decisions, failed attempts, current state (the story file)
- The current git state

From here, the human directs; the agent executes with full context.

## What this does not do

- Doesn't check external sources — Jira, Confluence, GitHub PRs. That's `/workflow-dev:refresh`.
- Doesn't propose changes to the context files, only loads them.
- Doesn't start working autonomously — it waits for direction.

## When to suggest `/workflow-dev:refresh` instead

If Step 4 turns up any of the following:
- The branch is significantly behind (5+ commits)
- The last save was more than two days ago
- There are merge conflicts

Suggest: "It's been [X days] since the last save. Want to run `/workflow-dev:refresh` to check whether anything changed upstream?"

## Principles

- Fast — this is seconds, not minutes: read the files, run a quick git check, done.
- Silent internalization — don't dump the whole context back at the human. They wrote it; just show status.
- No re-asking — the context files already have the answer. Never ask "where were we?"
- Reach for `AskUserQuestion` only when there's an actual choice (multiple stories); skip it when there's just one.
