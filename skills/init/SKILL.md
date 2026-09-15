---
name: init
description: Bootstraps the persistent context files for a story — creates/updates REPO.md (repo-level) and creates [STORY-ID].md (story-level). Extracts context from Jira, Confluence, GitHub, and the repo itself, or from a local markdown file when no Jira link/ID is given. Use when the user says "init story", "start story", pastes a Jira story link/ID, or gives a path to a .md file to use as the story.
---

<!--
workflow-dev — a persistent-context development workflow for Claude Code
Copyright (C) 2026  lbecjx

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version. See LICENSE for the full text.
-->

# Init

## What this does

Creates two context files under `.workflow-dev/context/`:
1. **REPO.md** — repo-level knowledge shared across every story in this project: stack, conventions, good practices, prohibitions, infrastructure, integrations. Written once, updated incrementally as new stories surface new facts.
2. **[STORY-ID].md** — working memory for one story: scope, decisions, discoveries, progress, files touched. One file per active story.

## Required MCPs

- **Jira** (atlassian) — story, epic, links. Not needed when the story source is a local `.md` file.
- **Confluence** (atlassian) — TDD, ADRs, linked docs. Not needed unless the `.md` source links out to Confluence.
- **GitHub** — PRs, branches, repo state.

## Input

The user provides one of:
- A Jira story link or ID (`https://jira.example.com/browse/PROJ-1234`, `PROJ-1234`)
- A path to a local markdown file to use *as* the story (`./docs/story.md`, `specs/PROJ-1234.md`). Its content becomes the story; Phase 1 (Jira) and Phase 2 (Confluence, unless the file itself links out) are skipped in favor of Phase 1-alt below.

If the input matches neither shape, ask which one it is before proceeding.

## Execution

**Read every file under `references/` before executing** — they carry the detailed workflow this SKILL.md only summarizes.

### Phase 0: Resolve the context-tracking preference

`.workflow-dev/context/` is a fixed path — do not detect or ask about `.claude/`, `.codex/`, or any other agent-specific convention. The only open question is whether this folder is tracked in git or gitignored, and that's answered once per project, not once per run.

1. Check for `.workflow-dev/config.json` at the project root.
2. **If it exists:** read `gitignored`. If `true`, confirm `.workflow-dev/` is actually listed in `.gitignore` (add it, and create `.gitignore` if the project has none, when it's missing). If `false`, do nothing further — the folder is meant to be tracked. Either way, don't ask the human again.
3. **If it doesn't exist** (first `init` run in this project): ask the human directly — do you want to keep the `.workflow-dev/` folder gitignored? This is where the skill's configuration and your persistent context live: gitignored means both are private, per-machine, and regenerated from scratch on a fresh clone; tracked means both travel with the repo, survive a fresh clone, and can double as visible engineering documentation. Write the answer to `.workflow-dev/config.json` as `{ "gitignored": true }` or `{ "gitignored": false }`, and update `.gitignore` accordingly.

If `gitignored: true`, the entire `.workflow-dev/` folder — including `config.json` — is excluded; nothing under it travels with the repo. That's the point of choosing `true`. On a fresh clone, `.workflow-dev/` simply won't exist yet — treat that exactly like a first `init` run and ask again.

### Phase 1: Extract from Jira (skip if a `.md` path was given — use Phase 1-alt instead)

1. Fetch the story: title, description, AC, subtasks, linked issues, blockers.
2. If it belongs to an epic, read the epic — objective, scope, sibling stories.
3. Collect any Confluence links attached to the story or epic.
4. Read the last 2–3 comments only if they contain decisions or corrections.

### Phase 1-alt: Extract from a local `.md` file (replaces Phase 1 when a file path was given)

1. Read the file in full.
2. Extract, best-effort, from its structure: title (first heading, else filename), description, acceptance criteria (look for headings or checkboxes like "AC" or "Acceptance Criteria," including non-English equivalents).
3. If the file doesn't cleanly separate description from ACs, treat the whole content as description and ask the human to point out the ACs — never invent ACs the file doesn't state.
4. Story ID = filename without extension (`PROJ-1234.md` → `PROJ-1234`, `checkout-refactor.md` → `checkout-refactor`). If the filename is generic (`notes.md`, `story.md`), ask for a story ID.
5. Status exists even without Jira: use whatever the file states explicitly, otherwise initialize as `Not Started` and keep it synced with the Progress section as ACs close.
6. Skip epic lookup unless the file names one that resolves in Jira.
7. Follow Phase 2 for any explicit Confluence links the file contains.

### Phase 2: Extract from Confluence (only if links exist)

1. Read the linked TDD — pull the relevant sections, not the whole document.
2. Read linked ADRs — constraints and decisions.
3. Read API contracts if referenced.
4. Never search Confluence speculatively; follow only explicit links.

### Phase 3: Verify repo state

1. Confirm you're in a git repository — if not, ask where the repo lives and suggest opening the session there.
2. Confirm it's the right repository for this story.
3. Run `git fetch` and verify the branch base is current.
4. Check for uncommitted changes and warn if the tree is dirty.
5. Identify or create the work branch.

### Phase 4: Repo-level context (REPO.md)

Check whether `.workflow-dev/context/REPO.md` already exists.

**If it exists:** read it, spot-check that the stack section still matches `package.json` (or equivalent), update anything stale, and skip straight to Phase 5 — a full repo audit isn't needed twice.

**If it doesn't exist,** run a full exploration:

1. Read the manifest/build config and extract the stack with exact versions.
2. Read the project structure (depth-3 tree).
3. Read root and module-level READMEs.
4. Read `docs/` if present.
5. Read configs: tsconfig, eslint, prettier, docker-compose, `.env.example`.
6. Read CI config — what blocks a merge, what runs, coverage thresholds.
7. Identify shared types, utilities, and error-handling patterns.
8. Identify schemas or migrations relevant to the repo.
9. Read test patterns: runner, style, fixtures, helpers.
10. Skim the last 10–20 commits.

Then draft Role, Good Practices, and Prohibitions (delegate to subagents for a genuinely complex stack — see `references/workflow.md`).

**REPO.md sections:**
1. What this is — system context, priorities, code tone
2. Stack — table with exact versions
3. Project structure — tree
4. Conventions — errors, dependencies, tests, naming, imports
5. Good practices — per technology
6. Prohibitions — security, performance, dangerous patterns, project-wide
7. Infrastructure / local dev
8. Key files — table
9. Integration sections as needed (Airtable, Datadog, etc.)

### Phase 5: Story-level context ([STORY-ID].md)

1. Create `.workflow-dev/context/[STORY-ID].md` from `references/template.md`.
2. Fill in story-specific findings.
3. Set section 3's Implementation Status heading exactly as the template has it — copy this literally, do not rephrase, restructure, or move the value to a separate line, since another workflow-dev hook matches this exact text:
   ```
   ### Implementation Status: In Progress
   ```
   Running `init` is itself the start of work. Never write "Not Started" here: a story that hasn't been init'd yet has no context file to write "Not Started" into in the first place, so by the time this file exists, work has begun. This is separate from section 1.1's `Status` field, which just mirrors whatever the source (Jira, or a local .md) reports — the two can disagree, and that's expected, not a bug.
4. Link to REPO.md at the top instead of duplicating repo-level facts.
5. Map exemplar files to the ACs they inform.
6. Mark anything unresolved with ⬜ and a note on what's missing.

### Phase 6: Ask the human

1. Collect every ⬜ across both files.
2. Turn them into specific questions grounded in what's actually missing — not a generic checklist.
3. Present them and update the context files with the answers.

## After init

Report back:
- Where the context files live (`.workflow-dev/context/`)
- What REPO.md covers, if it was newly created
- What the story file covers
- What's still open
- Suggest running `/workflow-dev:plan` next if the story is non-trivial, or ask what to do first if it's simple enough to skip planning

## Principles

- The human is the architect. Don't propose an implementation plan here.
- Extract substance, not summaries — an AC specifying "retry 3 times with exponential backoff: 1s, 4s, 16s" keeps every one of those numbers.
- Exemplar files map to specific ACs; different ACs often need different reference patterns.
- Confluence documents intent and rationale; the code is the current state of truth. Never take a doc's word over the repo's.
- Both context files are living documents, updated as work progresses.
- REPO.md accretes — each story may surface new facts about the repo; extend it, never regenerate it from scratch.
- Story files are disposable — once merged, a story's context file can be archived or deleted. REPO.md persists.
