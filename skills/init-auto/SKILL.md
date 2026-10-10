---
name: init-auto
description: Starts a story with init in autonomous mode — same input as init (a Jira story link/ID or a path to a .md file), and the whole story then runs end-to-end without asking each step. Use only when the user runs /workflow-dev:init-auto or asks for it by name.
---

<!--
workflow-dev — a persistent-context development workflow for Claude Code
Copyright (C) 2026  lbecjx

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version. See LICENSE for the full text.
-->

# Init Auto

**Text shown to the user follows `references/user-language.md` (at the plugin root, not this skill's own `references/`)** — its language, wording, and length.

**No cost checkpoint.** This skill only starts `init`, and the `init` it invokes records the run (`references/run-cost.md` at the plugin root).

## What this does

A thin wrapper around `/workflow-dev:init`. Running it is the human saying "run
this autonomously" for that story, as an explicit command instead of a phrase.
Run it only when the human asked for it in their own message; never pick it
on your own inference, since `init` records the start as the human's choice
(`references/autonomous-mode.md`, "The signal").

Everything else is `init`'s and `references/autonomous-mode.md`'s (at the
plugin root): this skill restates none of their steps or rules, so `init` stays
the one source of truth.

## Execution

1. **Take the input as given.** It is exactly `init`'s input (`../init/SKILL.md`,
   "Input"). With no input, say so and show the usage
   (`/workflow-dev:init-auto <story>`); never guess one.
2. **Invoke `/workflow-dev:init`** with that input, unchanged, followed by
   `— run this autonomously`. `init` reads that as the human saying how to run
   this story (`../init/SKILL.md`, "Before Phase 0: Resolve the run mode") and
   carries on from there, including the case where the story was already set
   to step by step.
