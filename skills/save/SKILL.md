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

**Text shown to the user follows `references/user-language.md` (at the plugin root, not this skill's own `references/`)** — its language, wording, and length.

## What this does

Forces a review of everything that happened since the last context update, and persists what matters. It's a manual trigger for "save now" without the human having to specify exactly what.

**Auto vs manual — what's automatic and what isn't.** Mechanical story state
(Plan Progress, Files Touched, the next step) is updated **directly as work
proceeds**, by `implement`'s own step — not here, and without asking. This skill
covers the rest: decisions, discoveries, and progress that live **only** in the
conversation. It runs **on request**, shows what it will write before writing,
and never saves silently — so the human always sees what gets persisted. (The
*compaction-state save point* is a separate, automatic thing: it only tracks how
far the last save read, so a future save doesn't re-read or skip content.)

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

Read ECOSYSTEM SECTION.

### Step 1: Find the context files

Look for `.workflow-dev/context/` in the current project:
- **REPO.md** — repo-level context; should exist after the first `init`
- **[STORY-ID].md** — the active story's context (whichever file isn't REPO.md)

Neither found → tell the human there's no active context yet and suggest running `/workflow-dev:init` first.

### Step 2: Read the current context files

Load both so you know what's already recorded — this is what keeps you from duplicating an entry.

### Step 3: Review the conversation since the last save

**Run this before relying on anything else, substituting the real story ID.** Run
it with the shell tool — name the capability, not a tool name that can change
(`references/harness-tools.md` at the plugin root — not this skill's own
`references/`):

```sh
# Resolve the plugin root — CLAUDE_PLUGIN_ROOT reaches hooks, not a skill's shell
# calls, so fall back to this skill's own directory (…/skills/save → …).
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd -P "<this skill's directory>/../.." && pwd -P)}"

"$PLUGIN_ROOT"/scripts/save-read-unsaved.sh --digest [STORY-ID]
```

The `--digest` flag prints a **readable line per message** (channel + text, with
tool-call payloads and reasoning stripped) — the raw JSON is available with
`--raw`, but the digest is what you review, and pulling raw JSON into context is
itself a cost.

This prints everything in the live conversation transcript since the last time this story was actually saved — reading directly from the original transcript file, not a copy of it, and only the portion past what's already captured (so it stays small in the normal case of saving promptly, and only large if several compactions were skipped in a row). The in-context compaction summary — the thing already sitting in your own context right now — is exactly what might have smoothed over or dropped the decisions/discoveries this extract exists to recover; treating that summary as sufficient defeats the point of running this. Use the extract, not just the summary, to find what actually needs persisting. If the script says there's nothing unsaved or no prior save point exists, that's fine — proceed with just the in-context summary as usual.

If the extract had content, state this at the top of the Step 4 summary, before the per-file changes — e.g. "Source: read N lines of unsaved transcript for [STORY-ID]." Silently having used it isn't enough; the human should be able to tell this save is more thorough than a normal one, not just take it on faith.

**The save point.** `.workflow-dev/context/.compaction-state/[STORY-ID].json` keeps the Claude Code transcript the hooks recorded and a line count into it. A state written by an older version — one that also recorded a second source — still reads: its Claude Code position is used, and the extra keys are dropped on the next save.

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

In autonomous mode (`Autonomous mode: on` in the story's Decisions —
`references/autonomous-mode.md` at the plugin root), do not block on the "Save
all of this?" confirmation: apply the changes, and carry what was saved into the
end-of-run report. The human still gets the record — just after the fact, in the
report, not as a per-save interrupt.

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

### Step 6: Advance the story's save point

Only if Step 3 actually ran `save-read-unsaved.sh` and got a real extract (not "nothing unsaved" or "no prior save point"), immediately after Step 5 writes the story file, run this exact command, substituting the real story ID:

```sh
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd -P "<this skill's directory>/../.." && pwd -P)}"
"$PLUGIN_ROOT"/scripts/save-mark-saved.sh [STORY-ID]
```

This is not optional — do it as part of completing Step 5, not as a "nice to have" afterthought, and only after Step 5's write actually happened (never before — marking content as caught up when it was never actually persisted means a future read would silently skip it forever). Don't hand-roll this by writing the state file yourself: the save point advances to precisely the line Step 3's read stopped at, not a value recomputed now, since the live transcript may have grown further since Step 3 ran — get this arithmetic wrong and content nobody actually saved goes missing from every future read. A script gets it right every time; a model re-deriving it from prose is exactly the kind of task that drifts.

Relay the script's own stdout verbatim as part of the save confirmation — it already reports what line the story is now marked saved through, in local time, e.g.:

```
Marked [STORY-ID] as saved through line 1234 (2026-01-01 at 5:00 PM) — future reads will only include what comes after.
```

This has actually happened, wrong, in a real session: the confirmation shown to the human used a shorter line Claude wrote itself instead of relaying the script's output, sourcing the raw UTC `dateTime` from `.compaction-state/[STORY-ID].json` and displaying it as if it were already local — several hours off from the real local time. Never read that JSON file's `dateTime` field yourself for this purpose, no matter how tempting it is to write a shorter or differently-styled summary line — that field exists in UTC specifically for `save-mark-saved.sh` to convert, not for direct display, and the script's own sentence above is what belongs in the confirmation, unedited.

Then record the save checkpoint (WD-0037):
`"$PLUGIN_ROOT"/scripts/session-usage.sh --snapshot [STORY-ID] --stage save`,
and show the line it prints (this step's spend and the story's running total); when it also prints a `spend verified ✓` line, tell the human the story's spend is now verified.
`save` is the safety net — it runs on compaction and on session close — so this
is the checkpoint that most often survives a session that is later deleted.
`PLUGIN_ROOT` resolves exactly as `save-mark-saved.sh` above does.

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

## ECOSYSTEM SECTION

Full contract and how-to: see `../../ECOSYSTEM.md`.

Rules:
1. If Step 5 just wrote `Implementation Status: Done` or `Implementation Status: Won't Do`, the story source is a local `.md` file whose path matches `local-backlog/<CODE>-*.md` (`<CODE>` is only the `<PREFIX>-XXXX` part of the filename, e.g. `LB-0018`), and `local-backlog/.backlog-config.json` exists at the repo root, invoke `/local-backlog:update-status <CODE> "Done"`. Always infer the resolution from what the story's context shows happened — one of `Done`, `Won't Do`, `Duplicate`, `Cannot Reproduce`; `Implementation Status: Done` with its ACs complete is `Done`, and `Implementation Status: Won't Do` is `Won't Do` — not from wording in the story's own text. With a human present, ask which resolution applies, listing the inferred one first marked `(Recommended)` so they can accept it or pick another — each resolution value stays as it is, and its description explains it in the user's language (`references/user-language.md`); running autonomously, use the inferred one and record it without asking. If the marker file doesn't exist, skip.
