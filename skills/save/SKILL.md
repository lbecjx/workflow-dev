---
name: save
description: Saves pending information to the persistent context files, repo-level and/or story-level. Reviews what happened since the last save and updates every relevant section. Use when the user says "save", "update context", or wants to force-persist the current conversation state.
---

<!--
workflow-dev — a persistent-context development workflow for Claude Code
Copyright (C) 2026  lbecjx

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version. See LICENSE for the full text.
-->

# Save

## What this does

Forces a review of everything that happened since the last context update, and persists what matters. It's a manual trigger for "save now" without the human having to specify exactly what.

Context lives in **two files**:
- **REPO.md** — repo-level knowledge: stack, conventions, good practices, prohibitions, infra, integrations. Shared across every story.
- **[STORY-ID].md** — story-specific working memory: decisions, discoveries, progress, files touched. One per active story.

## When to use

- The human says "save," "update context"
- The conversation feels like it's drifted too far since the last save
- Before a break
- Compaction feels imminent
- As a checkpoint before a risky change

## Execution

### Step 1: Find the context files

Look for `.workflow-dev/context/` in the current project:
- **REPO.md** — repo-level context; should exist after the first `init`
- **[STORY-ID].md** — the active story's context (whichever file isn't REPO.md)

Neither found → tell the human there's no active context yet and suggest running `/workflow-dev:init` first.

### Step 2: Read the current context files

Load both so you know what's already recorded — this is what keeps you from duplicating an entry.

### Step 3: Review the conversation since the last save

**If `.workflow-dev/context/.compaction-backups/[STORY-ID]-*.jsonl` exists, read it before relying on anything else.** A compaction happened, and the summary Claude Code generated from it — the thing already sitting in your own context right now — is exactly what might have dropped the decisions/discoveries this backup exists to recover; treating that summary as sufficient defeats the entire point of having backed up the raw transcript. Read the backup file(s) and use them, not just the in-context summary, to find what actually needs persisting. If a backup is large enough that reading it whole is impractical, grep it for keywords tied to what the story is actively working on (open questions, the current task group, recent file names) rather than skipping it outright — a partial read of the real transcript beats a full read of a summary that already lost detail once.

State this to the human, at the top of the Step 4 summary, before the per-file changes: which backup file was found and that it was read (or grepped) as the source for this save — e.g. "Source: read compaction backup `EDS-13015-20260915T164222Z.jsonl`." Silently having used it isn't enough; the human should be able to tell this save is more thorough than a normal one, not just take it on faith.

Scan everything discussed since the "Last updated" timestamp and classify each item:

**Goes to REPO.md:**
| Look for | Destination section |
|-----------|---------------------|
| New stack facts (versions, libraries) | Stack |
| New repo patterns/conventions | Conventions |
| Good practices discovered for the stack | Good Practices |
| Dangerous patterns discovered | Prohibitions |
| Infrastructure/tooling discoveries | Infrastructure / Local Dev |
| Integration details (a datastore, a third-party API, etc.) | Integration sections |
| Key-file discoveries | Key Files |

**Goes to [STORY-ID].md:**
| Look for | Destination section |
|-----------|---------------------|
| A decision the human made | Working Memory > Decisions |
| A decision the agent proposed and the human approved | Working Memory > Decisions |
| Something discovered about the story's code flow | Working Memory > Discoveries |
| Something that failed or didn't work | Working Memory > Failed Attempts |
| Something explicitly forbidden for this story | Working Memory > Do Not |
| An AC completed | Progress |
| An AC started | Progress |
| Files created/modified/deleted | Files Touched |
| A clarification to the AC or story | Base Context > Story |
| A scope change | Base Context > Story |
| The human decides to abandon our implementation effort | Progress > `Implementation Status: Won't Do` |
| Every task group/AC here is complete | Progress > `Implementation Status: Done` |

### Step 4: Present the save summary

Show the human what's about to be saved, grouped by destination file:

```
Context — changes to save:

REPO.md:
- Good Practices > [library]: added `timeout: '1s'` recommendation
- Prohibitions: added "don't call .passthrough() on an input schema without sanitizing first"

[STORY-ID].md:
- Decisions: use a queue-based retry over a custom setTimeout loop
- Discoveries: the legacy retry helper is deprecated
- Progress: AC #1 done — retry on 5xx implemented
- Files touched: src/modules/payments/retry.service.ts (new)

Save all of this?
```

Show only the section that has changes if the other file has none.

### Step 5: Save

Confirmed → update both files with the identified changes and bump the "Last updated" timestamp on each modified file.

"No," or wants edits → ask what to remove or change, then save.

### Step 6: Clean up compaction backups this save actually used

Immediately after Step 5 writes the story file, delete only the specific backup file(s) Step 3 actually read (in full or grepped) for this save — never a wildcard over the whole story:

```bash
rm -f .workflow-dev/context/.compaction-backups/[EXACT-FILENAME].jsonl
```

Never `rm .../[STORY-ID]-*.jsonl` — that deletes every backup for the story regardless of whether this save reviewed it. A backup this save never opened (the human moved on without answering the reminder, or a second compaction created one after this save's review already started) still holds unrecovered content; deleting it here would destroy the only copy of something that was never actually persisted. Delete a backup only at the moment its own content is confirmed captured in the story file — one file at a time, tied to the read, not to "a save happened."

This is not optional cleanup — do it as part of completing Step 5, not as a "nice to have" afterthought. Once a specific backup's content is confirmed captured, that file (which can contain anything pasted into the conversation, credentials included) has no reason left to exist on disk. `rm`, never move to Trash — same reasoning that put this directory in `.gitignore` to begin with.

If any backups were deleted, name them in the confirmation shown to the human — but not by raw filename. Each filename encodes `[STORY-ID]-[UTC timestamp].jsonl` (e.g., `EDS-13015-20260915T164222Z`); parse that timestamp, convert it from UTC to the human's local timezone, and present it as a date and time, not a filename fragment — e.g. "Backup for EDS-13015, saved 2026-09-15 at 4:42 PM — its content is now in the story file." So they know exactly which raw copies are gone and that each one's content is actually safe elsewhere, in a form they can read at a glance — not a blanket "backups deleted" line, and not the filename verbatim either.

## Classification rules

**Repo-level** = true for every story in this repo; useful even on an unrelated feature.
- "The cache's grace period is the actual resilience mechanism" → REPO.md
- "The service runs on port 8085, not 3000" → REPO.md
- "The old validation helper is deprecated" → REPO.md

**Story-level** = true only in the context of this specific story; meaningless without it.
- "RF3: process rows one at a time" → story
- "AC2 done" → story
- "The handler doesn't have caching yet" → story (until the story adds it)

**When unsure:** about the codebase/stack → REPO.md. About the work being done right now → the story file.

## Principles

- Be thorough — scan the entire conversation since the last save, don't skim.
- Don't duplicate — check both files before adding an entry.
- Be specific — "use a queue-based retry" beats "chose a library for this."
- Respect the file structure — every entry has one correct section, in one correct file.
- Always show the summary before saving — the human confirms what gets persisted.
- Update the timestamp on every file you touch.
- If REPO.md doesn't exist yet but repo-level knowledge surfaced, create it — use an existing REPO.md as the structural reference.
