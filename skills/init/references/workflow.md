<!--
workflow-dev — a persistent-context development workflow for Claude Code
Copyright (C) 2026  Luis Becerra

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version. See LICENSE for the full text.
-->

# Init — detailed workflow

## Philosophy

This is a human-piloted, agent-executed workflow:
- The **senior human pilots** — decides what to do, when, and how.
- The **agent executes** — armed with enough context to do it correctly on the first pass.
- The **context lives on disk** — it survives compaction and new sessions.

It is explicitly *not*:
- A spec framework — it doesn't produce design documents.
- A planner — it doesn't propose roadmaps or phases.
- Autonomous — it doesn't write 500 lines without checking in.

## Two-file architecture

Context splits into two files:

| File | Scope | Lifecycle |
|------|-------|-----------|
| `REPO.md` | Repo-level: stack, conventions, practices, prohibitions, infra, integrations | Persists across every story. Created once, updated incrementally. |
| `[STORY-ID].md` | Story-level: ACs, decisions, discoveries, progress, files touched | One per story. Archived or deleted once the story ships. |

**Why the split:** repo knowledge discovered in one story benefits every story that follows. Without it, each new story starts from zero and re-derives facts the agent already learned.

## Init flow

### Step 0: Resolve the context-tracking preference

`.workflow-dev/context/` is a fixed path — never detect or ask about `.claude/`, `.codex/`, or any other agent-specific convention. The only real question is whether the folder is tracked in git, and it's resolved once per project.

1. Check for `.workflow-dev/config.json` at the project root.
2. **Exists:** read `gitignored`. If `true`, confirm `.workflow-dev/` is actually listed in `.gitignore` (create `.gitignore` if the project has none, add the line if it's missing). If `false`, leave `.gitignore` untouched — the folder is meant to be tracked. Don't ask again either way.
3. **Doesn't exist** (first `init` in this project): ask directly — do you want to keep the `.workflow-dev/` folder gitignored? This is where the skill's configuration and your persistent context live: gitignored means both are private, per-machine, and regenerated from scratch on a fresh clone; tracked means both travel with the repo, survive a fresh clone, and can double as visible engineering documentation. Persist the answer to `.workflow-dev/config.json` as `{ "gitignored": true }` or `{ "gitignored": false }`, and update `.gitignore` to match.

If `gitignored: true`, the entire `.workflow-dev/` folder — including `config.json` — is excluded; nothing under it travels with the repo. That's the point of choosing `true`. On a fresh clone, `.workflow-dev/` simply won't exist yet — treat that exactly like a first `init` run and ask again.

### Step 1: Parse the input

Determine the story source from what the user gave you:
- Jira URL (`https://xxx.atlassian.net/browse/PROJ-1234`) → story ID `PROJ-1234` → Steps 2–4 (Jira/Epic/Confluence)
- Bare Jira ID (`PROJ-1234`) → same as above
- Path to a `.md` file (`./docs/story.md`, `specs/PROJ-1234.md`) → **Step 1-alt**, skipping Steps 2–4
- Anything that doesn't parse as either → ask

### Step 1-alt: Story from a local `.md` file (no Jira)

When the input is a file path rather than a Jira link or ID, that file *is* the story — there's nothing to query.

1. Read the file in full.
2. Extract, best-effort, based on its structure:
   - Title → first heading, or the filename if there's no heading
   - Description → the document's free text
   - Acceptance criteria → lists or checkboxes under headings like "AC" or "Acceptance Criteria," including non-English equivalents
   - Subtasks / blockers → only if explicit in the file
3. If the file doesn't cleanly separate description from ACs, treat the whole thing as description and ask the human which parts are the ACs. Never infer ACs the file doesn't state.
4. Story ID = filename without extension (`PROJ-1234.md` → `PROJ-1234`, `checkout-refactor.md` → `checkout-refactor`). A generic filename (`notes.md`, `story.md`, `untitled.md`) means asking the human what ID to use for `.workflow-dev/context/[STORY-ID].md`.
5. Status is not N/A just because there's no Jira — the story still has a real state. Use it if the file states one explicitly (front matter like `status: in-progress`, or a "Status: Done" heading); otherwise initialize as `Not Started`. This field stays local and updates in sync with section 3 (Progress) as ACs close — same rule as Jira-sourced stories, minus the external system reflecting it.
6. No epic lookup unless the file names one that's resolvable in Jira (in which case, treat it as Step 3).
7. Follow Step 4 for any explicit Confluence links the file contains.
8. Continue directly to **Step 5** (verify repo) — the remaining flow is identical.

### Step 2: Jira — story

Via the Jira MCP:
1. `jira_get_issue` for the story ID.
2. Extract summary, description, acceptance criteria.
3. Extract subtasks and linked issues (blocks, is-blocked-by, relates-to).
4. Extract the epic link if one exists.
5. Read the last 2–3 comments — only if they contain decisions or corrections.

**What matters:**
- Full ACs, with every detail — they're the contract.
- Subtask status — tells you what's already done.
- Blockers — must be resolved before work starts.

**What to ignore:**
- Administrative fields (sprint, story points, reporter).
- Stale comments or status-update noise.
- Generic labels.

### Step 3: Jira — epic (if one exists, independent of any TDD)

If the story belongs to an epic:
1. `jira_get_issue` for the epic ID.
2. Extract summary and description — the epic's objective.
3. Look for sibling stories already marked Done — they reveal established patterns.

### Step 4: Confluence — documentation (if links exist, independent of the epic)

Look for Confluence links in:
- The story's "Web Links" field
- The epic's "Web Links" field
- Anything referenced in the description or ACs

If links exist:
1. `confluence_get_page` for each relevant one.
2. Extract only the technical sections: feature design, constraints, service contracts, architecture decisions.
3. Skip intro material, background, stakeholders, timelines.

No links → skip entirely. Never search Confluence speculatively.

**Rule:** Confluence documents intent and rationale. The code is the current state of truth.

### Step 5: Verify repo state

1. `git rev-parse --is-inside-work-tree` — confirm you're inside a repo.
2. Not in a repo → tell the human: "This isn't a git repository. Where does the code live? I'd suggest opening the session there."
3. In a repo → confirm it's the right one for this story (cross-check against the story's own context).
4. `git fetch origin` for the latest state.
5. `git status` for uncommitted changes.
6. Identify the base branch (`main`, `develop`, `release/x`, …).
7. Check for an existing branch for this story (`git branch -a | grep [STORY-ID]`).

### Step 6: Repo-level context (REPO.md)

Check whether `.workflow-dev/context/REPO.md` already exists.

**Exists → quick verification:**
1. Read it.
2. Diff its stack versions against the current manifest — update anything stale.
3. Check whether the project structure shifted meaningfully.
4. Skip full exploration — it's already populated.

**Doesn't exist → full exploration:**

**6.1 Stack** (manifest / build config)
- Language and version (tsconfig target, engines, etc.)
- Framework, version, paradigm
- Key dependencies
- Available scripts (dev, test, build, lint)

**6.2 Structure**
- `find . -type f | head -200` or a depth-3 tree
- Where modules, tests, and shared code live

**6.3 Internal documentation**
- Root README
- Module/package READMEs
- `docs/`, if present
- CONTRIBUTING.md, ARCHITECTURE.md, if present

**6.4 Configuration**
- tsconfig.json / jsconfig.json
- .eslintrc or eslint.config
- Prettier config
- docker-compose.yml
- .env.example

**6.5 CI/CD**
- `.github/workflows/*.yml` or equivalent
- What runs: tests, coverage thresholds, lint gates

**6.6 Patterns**
- Shared types/interfaces
- Error handling (AppError, HttpException, or equivalents)
- Shared utils/helpers
- Middleware patterns

**6.7 Tests**
- One representative existing test
- Runner, assertion style, mocking approach, fixtures

**6.8 Integrations**
- External APIs the repo talks to
- Auth pattern per integration
- Key modules per integration

Then move to Step 7 to build Role, Good Practices, and Prohibitions for REPO.md.

### Step 7: Build Role + Good Practices + Prohibitions → REPO.md

**Only runs if REPO.md doesn't exist yet, or is missing these sections.**

Sections 1, 5, and 6 of REPO.md (What This Is, Good Practices, Prohibitions) require research. For a non-trivial stack, run three subagents in parallel:

#### Subagent 1: Role builder

**Base prompt:** "Based on this project context [inject: service type, stack, patterns, TDD/epic info], write a Role section for REPO.md covering:
- System/service context — what it is, who consumes it, what failing looks like
- Development priorities, ordered
- Code tone, based on observed patterns

Be specific to this repo, not generic."

#### Subagent 2: Good-practices researcher

**Base prompt:** "Research current best practices for this stack: [inject full stack with exact versions].

For each technology, find:
- Practices specific to this version, not generic advice
- Patterns the official docs recommend
- Production performance guidance
- Known mistakes reported for this version

Filter aggressively for actionability and version-specificity:
- Keep: 'In Prisma 5, use `$transaction` with an explicit timeout for multi-table operations.'
- Discard: 'Write clean code.'

Group by technology. 5–8 practices per technology, no more."

#### Subagent 3: Prohibitions researcher

**Base prompt:** "Research serious errors, security issues, and dangerous patterns for this stack: [inject full stack with exact versions]. This is a [service type derived from context].

For each technology, find:
- Known vulnerabilities for this version
- Patterns that cause production incidents
- OWASP Top 10 as it applies to this stack specifically
- Race conditions, memory leaks, data-corruption patterns

Each prohibition needs both halves: what not to do (with a bad-code example where useful) and the concrete production consequence of doing it anyway.

Be specific. 5–8 prohibitions per category, no more."

#### Running it

1. Launch the three subagents in parallel.
2. Collect results.
3. Compile them into REPO.md sections.
4. Present each section to the human **separately**, in order:

```
[Section name] — drafted from research:

[content]

Approve as-is, edit (tell me what to change), or rewrite it yourself and I'll save it?
```

5. The human decides per section, independently.
6. Save each approved version into REPO.md.

#### Subagents vs. doing it inline

**Use three parallel subagents when:**
- The stack has three or more primary technologies
- It's a critical service (payments, auth, sensitive data)
- Multiple external integrations are involved
- The TDD/epic signals high complexity
- REPO.md doesn't exist yet

**Do it inline (main agent, sequential) when:**
- The stack is simple — one framework, one datastore, internal tool
- It's a CRUD feature or similarly straightforward
- REPO.md exists and only needs a minor update
- The project's own documentation already covers most of this

This choice is an execution optimization the agent makes on its own — it doesn't change the outcome, so it doesn't need to be asked.

### Step 8: Generate the story context file ([STORY-ID].md)

1. Create `.workflow-dev/context/` if it doesn't exist.
2. Create `.workflow-dev/context/[STORY-ID].md` from the template.
3. Fill in the story-specific sections: details, ACs, epic, TDD extracts, exemplar files mapped to this story's ACs, and any data model this story touches.
4. Link REPO.md at the top: `> Repo context: [REPO.md](./REPO.md)`.
5. Don't duplicate anything REPO.md already covers.
6. Mark unresolved items with ⬜.

Whether this whole `.workflow-dev/` tree is tracked or gitignored was already settled in Step 0 — nothing further to decide here.

### Step 9: Questions for the human

Review everything marked ⬜ across both files and turn it into specific questions:
- Not: "anything else I should know?"
- Yes: "No exemplar found for AC #3 (dead-letter consumer). Is there one in the repo I should follow?"

Update the files with the answers.

### Step 10: Confirm

Report back:
- Files created/updated — REPO.md (new/updated/unchanged) and [STORY-ID].md (new)
- A summary of what was found
- Any pending questions
- That you're ready to work — ask what to do first

## Keeping it alive after init

Both files are living documents, updated as work happens.

### Events that require a context update

#### A. Confirmed updates (ask first)

| # | Event | Section | File |
|---|-------|---------|------|
| 1 | Human picks between options | Decisions | story |
| 2 | Human rejects an agent proposal | Decisions + Do Not | story |
| 3 | Human states a story-specific rule | Do Not | story |
| 4 | Human states a rule that applies repo-wide | Prohibitions or Conventions | REPO.md |
| 5 | Agent discovers something about the story's flow | Discoveries | story |
| 6 | Agent discovers something about the repo/stack | Relevant section | REPO.md |
| 7 | An approach fails, or fails to compile/pass tests | Failed Attempts | story |
| 8 | Conflict found with someone else's work | Discoveries | story |
| 9 | Human clarifies an ambiguous AC | Story (update the AC) | story |
| 10 | A TDD/doc turns out to be stale | Discoveries | story |
| 11 | Human points at a pattern to follow | Relevant Files | story |
| 12 | AC completed | Progress | story |
| 13 | Scope changes | Story | story |
| 14 | New good practice discovered for the stack | Good Practices | REPO.md |
| 15 | New integration detail discovered | Integration section | REPO.md |

#### B. Direct updates (no confirmation needed)

| # | Event | Section | File |
|---|-------|---------|------|
| 1 | File created/edited/deleted | Files Touched | story |
| 2 | A step finishes, the next one is defined | Progress → Next Step | story |
| 3 | Timestamp | Header | whichever file changed |
| 4 | AC status ⬜ → 🔧 (started) | Progress | story |
| 5 | Progress percentage updated | Progress | story |

### How to ask

**Structure:** what would be saved (one concrete line), where (section + file), and that it's a context update.

**Examples:**

> "Decision: use BullMQ instead of a custom `setTimeout`. Save to the story's context?"

> "Discovery: the service runs on port 8085, not 3000. Update REPO.md?"

> "Good practice: always call `fail()` in BentoCache factories. Update REPO.md?"

> "Failed attempt: extending `WebhookHandler` doesn't work — it's a final class. Save to the story's context?"

> "AC #2 done — exponential backoff implemented. Update progress?"

Always a yes/no choice.

### Frequency

- Don't ask every couple of messages — that's noise.
- Don't batch five things into one question — surface each as it happens.
- Do ask right after the event occurs.
- It's fine to ask about two or three things in a row if that many happened in the same turn.

### The test

**"If this conversation compacted right now, would this be lost?"**

Yes → save it to the right file. No — it's already in the code, it's trivial, or it's already recorded — don't ask.

## Recovering after compaction

1. Re-read `.workflow-dev/context/REPO.md`.
2. Re-read `.workflow-dev/context/[STORY-ID].md`.
3. You now know exactly what you're doing, what was decided, where things stand, and what's next.
4. Continue without re-asking anything already answered.

## Resuming in a new session

1. Re-read `.workflow-dev/context/REPO.md` — always.
2. Re-read `.workflow-dev/context/[STORY-ID].md`.
3. `git fetch` — check for upstream changes.
4. Quick check: did the story change in Jira?
5. Check for new, possibly conflicting PRs.
6. Update whatever changed.
7. "Resuming [STORY-ID]. We left off at [next step]. Continue?"
