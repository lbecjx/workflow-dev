<!--
workflow-dev — a persistent-context development workflow for Claude Code
Copyright (C) 2026  Luis Becjx

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version. See LICENSE for the full text.
-->

# Template: .workflow-dev/context/[STORY-ID].md

```markdown
# [STORY-ID]: [short title]
> Persistent context — created: [date] | last updated: [date]
> Repo context: [REPO.md](./REPO.md)

---

## 1. Base Context

### 1.1 Story
**ID:** [Jira link | path to the source .md file]
**Status:** [whatever the source reports — Jira's own status field, or the source .md's own `Status` line if it came from `local-backlog` or elsewhere. Purely informational: this mirrors an external system we don't control and never drives our own logic. Don't confuse with Implementation Status below — the source can say "In Review" while every task group here is Done, or say "Done" while we still have work left; they're independent clocks.]
**Assignee:** [name | N/A if there's no Jira]
**Sprint:** [sprint name and dates | N/A if there's no Jira]

**Description:**
[full text — don't summarize, keep all the substance]

**Acceptance Criteria:**
1. [full criterion, with every detail]
2. [full criterion, with every detail]
3. ...

**Subtasks:**
- [x] XXXX-xxxx — [description] (done)
- [ ] XXXX-xxxx — [description] ← this is the one I'm working on

**Blockers / Linked issues:**
- [none | list with each one's status]

**Notes from ticket:**
- [relevant notes/constraints from the ticket]

### 1.2 Epic (if one exists)
**ID:** [link]
**Objective:** [what this epic is trying to achieve]
**Status:** [status]

**Description:** [the epic's objective and scope]

**Sibling stories:**
- XXXX-xxxx — [what it established / what pattern it left]

### 1.3 TDD / Documentation (if one exists)
**Source:** [link to Confluence]
[relevant sections of the TDD — constraints, contracts, sequence diagrams,
design decisions that directly affect this story.
Do NOT copy the whole doc — DO keep every relevant technical detail]

### 1.4 Relevant files (story-specific)
| Reference | Path | Used for |
|-----------|------|------------|
| [descriptive name] | `path/to/file.ts` | Pattern for AC #1 |
| [descriptive name] | `path/to/file.ts` | Pattern for AC #2 |
| [descriptive name] | `path/to/test.spec.ts` | How this gets tested |

### 1.5 Data model (story-specific)
[schemas/tables/types relevant to the story]
[relationships between entities]
[only what this story touches — general facts go in REPO.md]

---

## 2. Working Memory

### Decisions
| Date | Decision | Decided by |
|-------|----------|---------------|
| | | |

### Discoveries
- [things found during implementation that affect the work]

### Do Not
- [things that seem reasonable but are wrong here, and why]

### Failed Attempts
- [what was tried and didn't work — so it isn't repeated]

---

## 3. Progress

### Implementation Status: In Progress
Set to **In Progress** at creation, always — a context file existing at all means work has begun. Ends at either **Done** (every task group/AC here is complete) or **Won't Do** (the human decided to abandon this implementation effort) — set by `/workflow-dev:save` when either happens. This tracks OUR OWN work against OUR OWN plan — independent of the Story `Status` in section 1.1, which tracks the source ticket and can disagree with this at any point (source says "In Review" while we're Done; source says "Done" while we still have task groups left; etc.).

### Acceptance Criteria
| # | Criterion | Status | Notes |
|---|----------|--------|-------|
| 1 | [criterion] | ⬜ pending | |
| 2 | [criterion] | ⬜ pending | |

**States:** ⬜ pending | 🔧 in progress | ✅ done

### Estimated progress: 0%

### Next step
[what needs to happen next — updated every time something gets completed]

---

## 4. Files Touched

| File | Action | What was done |
|---------|--------|-------------|
| | new / modified / deleted | |

---
```

## Section ownership

Each fact belongs in exactly one file — never duplicate stack details or story specifics across both.

| Information type | File |
|-----------------|------|
| Stack, versions, technologies | REPO.md |
| Project structure (full tree) | REPO.md |
| Conventions (errors, deps, naming) | REPO.md |
| Good Practices (per library) | REPO.md |
| Prohibitions (security, performance) | REPO.md |
| Infrastructure / local dev setup | REPO.md |
| Key files (general-purpose) | REPO.md |
| Integration details (Airtable, DD) | REPO.md |
| Story description, ACs, epic | [STORY-ID].md |
| TDD/Confluence extracts | [STORY-ID].md |
| Exemplar files for THIS story's ACs | [STORY-ID].md |
| Data model relevant to THIS story | [STORY-ID].md |
| Decisions, discoveries, failures | [STORY-ID].md |
| Progress, files touched | [STORY-ID].md |
