---
name: summarize-changes
description: Drafts the commit message, PR title, and PR description for the current changes, reviews each against Git History Disclosure rules, and marks them reviewed. Use before suggesting a commit, when the user says "create the PR", confirms "yes" to an offer to open one, or asks to fill in a PR template/description.
---

<!--
workflow-dev — a persistent-context development workflow for Claude Code
Copyright (C) 2026  lbecjx

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version. See LICENSE for the full text.
-->

# Summarize Changes

Drafts the three pieces of text that describe a change for the permanent
git record — commit message, PR title, and PR description — and runs each
one through the Git History Disclosure review
(`../validate/references/rules.md` Part 12) before handing it back, so
nothing reaches an actual `git commit`/`gh pr create`/`gh pr edit`
unreviewed.

**Read `../validate/references/rules.md` Part 12 before executing.**

## When to use

- After `/workflow-dev:validate` passes on a task group's changes and a
  commit message is needed
- Any time a PR is about to be created or edited — a "create the PR"
  request, a plain "yes"/"sí" confirming an offer to open one, "fill in
  the PR template," or `gh pr create`/`gh pr edit` about to run for any
  other reason
- Whenever the human just wants a commit message and/or PR text drafted,
  independent of a full `/workflow-dev:validate` pass

## What this does not do

- Doesn't run `/workflow-dev:validate`'s other dimensions (build, tests,
  security, code quality, etc.) — assumes the code itself was already
  validated elsewhere; this skill only judges the text describing it
- Doesn't run `git commit`, `gh pr create`, or `gh pr edit` itself — hands
  the reviewed text back to whoever (human or calling skill) actually runs
  that command
- Doesn't require drafting all three every time — draft only what's
  actually needed (a plain commit with no PR yet only needs the commit
  message; editing an existing PR's description doesn't need a new title)

## Execution

### Step 1: Determine what's needed

- **Commit message** — when this is invoked because a commit is about to
  happen
- **PR title + PR description** — when this is invoked for PR creation or
  editing

### Step 2: Draft

Read `git diff` (staged + unstaged) for a commit message, or the commits
since the PR's base branch for PR text. Draft:

- **Commit message**: one-line summary + at most two short paragraphs of
  body (rules.md §12.4)
- **PR title**: one line — same formality/disclosure rules as the commit
  summary, no separate length allowance
- **PR description**: at most a couple of short paragraphs (§12.4)

### Step 3: Review — one independent pass per change-set

Run **one** independent review over the text this change-set produces — not a
fresh sub-agent per artifact. A plain commit reviews its single message; a commit
drafted together with a PR reviews both in the same pass. What matters is the
independence (the reviewer never wrote the draft — same reasoning as Part 11's
hunt/verify split: whoever wrote the text tends to re-confirm it); the
per-artifact fan-out does not, and a 1–3 line message does not need its own
session.

This review is a bounded checklist, not open-ended reasoning, so run it under
the **`wd-operator`** role (class `operator`) — see
`../setup-models/references/roles.md`. Name the role as the sub-agent's type;
never a model name. If the harness cannot select a model per sub-agent (roles
ungenerated or stale, and no opt-out), run it on the default and **say so**;
don't pretend.

- **FAIL** (12.2 security disclosure, 12.3 personal/internal exposure —
  including any AI/agent/LLM attribution) → rewrite and re-check. Never
  hand back text that failed.
- **WARN** (12.1 formality, 12.4 length) → rewrite toward compliance
  before presenting it. This is a draft being produced, not a report being
  filed — fix it, don't just flag it and move on.

### Step 4: Mark reviewed

Once each piece passes, mark the exact final text so
`pre-commit-message-check.sh` recognizes it at actual commit/PR time and
doesn't ask again:

```sh
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd -P "<this skill's directory>/../.." && pwd -P)}"
printf '%s' "<final commit message>" | "$PLUGIN_ROOT"/scripts/git-message-mark-reviewed.sh
```

PR title and description are marked **together**, concatenated exactly as
`<title>\n\n<description>` — the hook builds the same concatenation from
the actual `gh pr create`/`gh pr edit` command to check the hash, so the
two must match byte-for-byte:

```sh
printf '%s\n\n%s' "<final PR title>" "<final PR description>" | "$PLUGIN_ROOT"/scripts/git-message-mark-reviewed.sh
```

### Step 5: Hand back

Present the reviewed commit message and/or PR title/description. This
step isn't optional because the text already passed review here —
`pre-commit-message-check.sh` still fires at actual `git commit`/
`gh pr create`/`gh pr edit` time regardless of whether this skill ran, and
**denies outright** if AI/agent attribution slipped in anyway (§12.3), or
**asks for confirmation** if the marker doesn't match for any other
reason. Running this skill first just means that's a formality instead of
the first real look at the text.

Once the actual `gh pr create`/`gh pr edit` runs, give the human the PR's
full URL as plain text on its own line — not only as a Markdown link
label, not only a `#n`. `post-pr-url-check.sh` reminds for this after a
successful command (WD-0024), but the reminder only reaches the agent;
relaying it to the human is still this step's job.

## Principles

- **One skill, three outputs** — commit message, PR title, and PR
  description all go through the same review, because they're the same
  kind of artifact (text describing a change for the permanent git
  record), just used at different moments in the same change's life.
- **One pass, not one session per artifact** — the review is per change-set;
  independence is preserved without paying for a sub-agent per line of text.
- **Independent review, not self-review** — the agent that reviews a
  draft is never the one that wrote it.
- **Nothing is final until marked** — a draft that hasn't been marked
  reviewed gets no free pass at commit/PR time; the hook checks the
  marker's content hash, not stated intent.
