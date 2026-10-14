<!--
workflow-dev — a persistent-context development workflow for Claude Code
Copyright (C) 2026  lbecjx

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version. See LICENSE for the full text.
-->

# The model-tiering question

The configuration interceptor (`scripts/config-check.sh`) holds a workflow-dev
skill while a setup answer is missing; this is one of those answers, missing
while the agent roles are unbound or stale and no default model was chosen for
the repo or the story (`scripts/model-tiering-check.sh --status`). `init`'s
Phase 0 asks it too if it is still missing (`../skills/init/SKILL.md`). The
instructions live here, in one place (WD-0045, WD-0046, WD-0108). Read this,
put the question to the user with the other missing setup questions, record
the answer, then continue the skill.

## Ask the user

Use the ask-question tool, worded per `user-language.md` (next to this file),
with exactly these options in this order:

1. **Configure the agents.** Run `/workflow-dev:setup-models` yourself, as the
   main agent and not as a sub-agent: it is interactive.
2. **Default model for this story.** Add the row
   `| <today> | Tiering: default model | Human |` to the Decisions table of the
   active story's file in `.workflow-dev/context/`, and change nothing else.
   Offer this option only when the current git branch name carries that story's
   code (for example `wd-0045-…`), because the hook finds the story through the
   branch; otherwise offer only options 1 and 3.
3. **Default model for this repo.** In the project root, run
   `scripts/config-env.sh set tiering default` (at the plugin root), which
   writes `tiering=default` to `.workflow-dev/config.env` and keeps its other
   keys.

Some roles need strong reasoning, so `setup-models` lets the user keep the default
for any role, and a weak model there does more harm than the default.

## Rules

- The question is required, also in autonomous mode: while a human can answer,
  never choose an answer for the user.
- When nobody can answer (unattended, `inference-first.md`), bind the roles
  yourself, the human's chosen default (WD-0108): run `/workflow-dev:setup-models`
  and, at each choice it would ask, pick from the models this harness offers the
  one whose tier fits the role's class in its registry — the fast tier for an
  `operator` role, the top tier for a `judge` role. Infer the tiers from what
  you know of the models on offer; the plugin never names a model. When
  `setup-models` finds no model source to pick from, run
  `scripts/config-env.sh set tiering default` (at the plugin root) instead, so
  the run goes on with the default model and the question does not come back
  before every skill. Record either one as
  `| <today> | Tiering: roles bound by the agent (unattended) | Agent (inferred) |`
  in the story's Decisions.
- There is no machine-wide opt-out. Never write `~/.workflow-dev/tiering.json`;
  an old one is ignored.
- After the answer is recorded, continue the skill the user asked for; it is
  already loaded, so do not call it again. The interceptor is silent about
  tiering once the roles are bound or a default is recorded.
