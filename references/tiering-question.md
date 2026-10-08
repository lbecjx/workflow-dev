<!--
workflow-dev — a persistent-context development workflow for Claude Code and OpenCode
Copyright (C) 2026  lbecjx

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version. See LICENSE for the full text.
-->

# The model-tiering question

`scripts/model-tiering-check.sh` blocks a workflow-dev skill call while the agent
roles are unbound or stale and no default model was chosen for the repo or the
story. Its one-line reason points the agent here, so the user sees a short
message and the instructions live in one place (WD-0045). Read this, put the
question to the user, record the answer, then call the skill again.

## Ask the user

Use the ask-question tool, in the user's language, with exactly these options in
this order:

1. **Configure the agents.** Run `/workflow-dev:setup-models` yourself, as the
   main agent and not as a sub-agent: it is interactive.
2. **Default model for this story.** Add the row
   `| <today> | Tiering: default model | Human |` to the Decisions table of the
   active story's file in `.workflow-dev/context/`, and change nothing else.
   Offer this option only when the current git branch name carries that story's
   code (for example `wd-0045-…`), because the hook finds the story through the
   branch; otherwise offer only options 1 and 3.
3. **Default model for this repo.** Set `"tiering": "default"` in
   `.workflow-dev/config.json`, keeping its other keys.

Some roles need strong reasoning, so `setup-models` lets the user keep the default
for any role, and a weak model there does more harm than the default.

## Rules

- The question is required, also in autonomous mode: never choose an answer for
  the user.
- There is no machine-wide opt-out. Never write `~/.workflow-dev/tiering.json`;
  an old one is ignored.
- After the answer is recorded, call the skill the user asked for again. The hook
  is silent once the roles are bound or a default is recorded.
