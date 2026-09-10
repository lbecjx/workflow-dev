---
name: refresh
description: Checks every context source (Jira, Confluence, GitHub, the repo) for updates since the persistent context was last saved, and proposes a plan to reconcile it. Use when the user says "refresh", "check for updates", "did anything change?", or at the start of a session to verify the context is still current.
---

<!--
workflow-dev — a persistent-context development workflow for Claude Code
Copyright (C) 2026  Luis Becjx

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version. See LICENSE for the full text.
-->

# Refresh

## What this does

Checks every source that originally fed the persistent context for drift, compares it against what's recorded in both files (REPO.md and [STORY-ID].md), and proposes an update plan showing what changed and what needs reconciling.

## When to use

- Start of a new session, to rule out overnight changes
- After a long break
- The human suspects something changed — the story was updated, a PR landed, a branch merged
- The human says "refresh," "did anything change?," "check for updates"

## Required MCPs

- **Jira** (atlassian) — story/epic changes
- **Confluence** (atlassian) — TDD/doc updates
- **GitHub** — new PRs, merged branches, repo changes

## Execution

### Step 1: Load the persistent context files

Read both from `.workflow-dev/context/`:
- **REPO.md** — repo-level context
- **[STORY-ID].md** — the active story's context (whichever file isn't REPO.md)

From the story file, extract: story ID, epic ID (if any), Confluence links (if any), last-update timestamp, branch info, files-touched list.

From REPO.md, extract: recorded stack versions, last-update timestamp, listed key files.

### Step 2: Check each source for drift

**Jira story**
- `jira_get_issue`, compared against what's saved: did the description or ACs change? New comments with decisions? Subtask status changes? Blockers added or removed? Scope change (an AC added or dropped)?

**Jira epic** (if one exists)
- New stories added to the epic? A sibling story completed, establishing a new pattern?

**Confluence** (if links exist)
- `confluence_get_page`, check the last-modified date. Did the TDD change since the last save? Did a relevant section change?

**Git / repo**
- `git fetch origin`
- `git log origin/[base-branch]..` — new commits on the base that affect this work?
- New PRs touching the same files? Was a previously conflicting PR merged or closed?
- Changes to any file used as an exemplar? Schema or migration changes?

**Repo-level checks** (for REPO.md)
- Manifest changes — did dependency versions move? New modules/directories? Config changes (tsconfig, eslint, etc.)? New patterns established by recent PRs?

**This branch**
- Is it behind its base (needs a rebase)? Any likely conflicts?

### Step 3: Present the refresh report

```
Context refresh — [STORY-ID]
Last updated: [timestamp]

Jira story:
- AC #4 changed: now reads "retry configurable" instead of "3 fixed retries"
- Subtask PROJ-1235 marked Done
- New comment from @lead: "add a retry-count metric"

Epic:
- No changes

Confluence TDD:
- Updated 2h ago — "Retry Strategy" section modified

Repo (affects REPO.md):
- Manifest: cache library upgraded to ^1.6.0
- Project structure unchanged

Repo (affects the story):
- 3 new commits on the base branch touching src/shared/queue.ts
- PR #245 merged: refactored the retry-queue wrapper
- No conflicts with this branch

Impact:
- HIGH: AC #4 changed — may affect the current implementation
- MEDIUM: the retry-queue wrapper changed — verify current usage is still valid
- LOW: new metric request — extra work, not blocking
- MEDIUM: cache library version bump — check whether REPO.md's practices still apply

Update the context with these changes?
```

### Step 4: Propose the update plan

On confirmation, show which sections would change, grouped by file:

```
Update plan:

REPO.md:
1. Stack — cache library ^1.5.0 → ^1.6.0
2. Good Practices > [cache library] — verify practices still hold for 1.6

[STORY-ID].md:
3. Base Context > Story > AC #4 — update the text
4. Base Context > Story > Subtasks — mark PROJ-1235 done
5. Working Memory > Discoveries — add: retry-queue wrapper refactored in PR #245
```

Options: update everything / let me choose / don't update.

### Step 5: Execute

Apply the confirmed changes to the corresponding file(s) and bump the timestamp on each one modified.

## Severity levels

| Level | Meaning | Action |
|-------|---------|--------|
| HIGH | Directly affects what's being implemented right now | Stop and adjust the approach |
| MEDIUM | Might affect it, needs verification | Review before continuing |
| LOW | New information, not blocking | Save it and move on |

## Principles

- Compare, don't re-fetch everything — check only for deltas.
- Classify by impact — not every change matters equally.
- Route each update to the right file — repo-level to REPO.md, story-level to the story file.
- The human decides what to update — never auto-apply.
- An unchanged source gets marked clean and moved past.
- A high-impact change gets flagged clearly — it may invalidate work already in progress.
- Always show the plan before executing it.
- If REPO.md doesn't exist yet but repo-level changes surfaced, suggest creating it via `/workflow-dev:init`.
