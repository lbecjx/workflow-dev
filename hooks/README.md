<!--
workflow-dev — a persistent-context development workflow for Claude Code
Copyright (C) 2026  lbecjx

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version. See LICENSE for the full text.
-->

# hooks/

`hooks.json` registers this plugin's hooks with Claude Code.

- The matchers `"Bash"` and `"Skill"` are Claude Code *event* vocabulary — the
  tool an event fires on, not a tool name a skill should tell an agent to call
  (see `../references/harness-tools.md`).
- JSON takes no comments, which is why this note sits beside the file rather
  than inside it.
- Each hook's wording and its "is this warranted?" test live in its
  `scripts/*.sh`, never in `hooks.json`.
- Both commit/PR hooks ask `scripts/command-match.sh` whether a command is really
  a `git commit` / `gh pr create` / `gh pr edit`, so they act on the command
  itself and not on a command that only mentions one. It answers `real`, `maybe`
  (wrapped in `bash -c`, `eval` and similar) or `no`. `maybe` is treated as `real`
  by the reminders, which only ask; the attribution block never denies on it.
- Both commit/PR hooks word their permission dialog in the conversation's
  language (WD-0048). Claude Code shows `permissionDecisionReason` as is, and an
  `additionalContext` beside an `ask` reaches the agent only after the dialog,
  so the script finds the language itself, through `scripts/hook-language.sh`.
  The first of these that answers decides:
  1. the user's newest typed messages in the transcript — the first line of
     each, cut short, and on it the words before a colon first, since a pasted
     log or error follows them; agent notifications and compaction summaries do
     not count. The scan has a hard 2 s budget: a hook that outlives its own
     timeout does not block the call, so a slow scan must never cost the
     attribution deny;
  2. Claude Code's `language` setting (`.claude/settings.local.json` and
     `.claude/settings.json` under `CLAUDE_PROJECT_DIR`, then
     `~/.claude/settings.json`);
  3. `"language"` in the project's `.workflow-dev/config.json`, which `init`
     writes on every run;
  4. English.

  Ten languages ship: English, Spanish, French, Portuguese, German, Italian,
  Chinese, Japanese, Korean and Russian (the last four told apart by their
  script); any other language gets English. Adding one is one place in
  `scripts/hook-language.sh` (its header says what to add). The
  language changes only the words, never the decision: the attribution deny
  stays a deny in every language.
- The attribution block reads one thing besides the command: the human's
  co-authorship decision in the active story (`scripts/coauthor-decision.sh`,
  shared with `git-message-mark-reviewed.sh`). Only an explicit yes lets the
  harness's trailer and PR line through; any doubt is no.
- After a real `gh pr create`/`gh pr edit` succeeds, `scripts/post-pr-url-check.sh`
  hands back the PR's full URL (WD-0024). It reads
  `tool_response.exit_code`/`stdout` from the `PostToolUse` payload and stays
  quiet on a non-zero exit. `gh pr edit` whose own stdout carries no URL falls
  back to a read-only `gh pr view --json url`, the one script in this plugin
  that calls out to `gh` itself.
- `scripts/plugin-update-check.sh` tells the developer, at most once per
  session per version, when a newer copy of this plugin exists (naming the
  update command) or is already on disk and only needs a session restart
  (WD-0029). It emits only `additionalContext`, never a permission decision,
  on both the events it fires on.
- The compaction-state save point (`scripts/save-read-unsaved.sh`,
  `scripts/save-mark-saved.sh`) keeps how far each story's last save read in
  `.workflow-dev/context/.compaction-state/<STORY>.json`: the transcript path the
  hooks recorded and a line count into it.
- **Autonomous mode needs no change to these hooks, and none is made** (WD-0039).
  An autonomous run keeps the commit/PR hooks quiet through the markers the
  skills already write — `validate`'s diff marker and `summarize-changes`'
  reviewed-message marker — not through any signal the hooks parse. The
  AI/agent attribution block in `pre-commit-message-check.sh` has no marker and
  no bypass beyond the human's own co-authorship answer, so it
  blocks in autonomous mode exactly as it does in a human-piloted one. See
  `../references/autonomous-mode.md`.
- **The model-tiering reminder has the agent ask; it neither asks nor blocks**
  (WD-0042, WD-0045, WD-0046). The `PreToolUse:Skill` hook can
  return `allow`, `ask`, `deny` or `defer`, plus `permissionDecisionReason`,
  `updatedInput` and `additionalContext`. Each of the first two attempts failed on
  something the plugin cannot change:
  - `ask` opens a dialog whose buttons belong to Claude Code: "Yes" only lets the
    skill run, and "Yes, and don't ask again" saves a permission `allow` rule (for
    example `Skill(workflow-dev:resume)`) that silences the reminder without
    configuring anything or recording a choice. Rewording the text (WD-0042) could
    not fix that.
  - `deny` has no such button, and the agent did ask first, but Claude Code prints
    every hook deny behind `Error: PreToolUse:Skill hook error:`, which reads as a
    failure when nothing failed (WD-0045).

  So the hook now returns `allow` with an `additionalContext` that only the agent
  reads: do not start the skill's own steps, put one question to the user, then
  continue. The user sees no error line and no dialog. The context points at
  `references/tiering-question.md`, which holds the question: three answers in this
  order — configure the agents (the agent runs `/workflow-dev:setup-models`
  itself, as the main agent, since the flow is interactive), a default model for
  this story (a `Tiering: default model` row in the active story's Decisions, offered only on a branch
  that names the story), or a default model for this repo (`"tiering": "default"`
  in `.workflow-dev/config.json`). The hook reads both defaults and stays silent
  for them, and once the roles are bound; the story one is a table row, not a
  mention. The question is required in autonomous mode too. There is no
  machine-wide opt-out: the old `~/.workflow-dev/tiering.json` is ignored, because
  tiering is either configured once or defaulted per repo or story. The
  `UserPromptExpansion` path (the user typing `/workflow-dev:<skill>`) cannot block
  and carries the same context.

  **The cost, accepted:** nothing enforces the pause. The skill is already loaded
  when the context arrives, so an agent that ignores it runs the skill without the
  question. A single live run (a new scratch repo, `init`) showed the agent reading
  the question file and asking before any of `init`'s steps, with no error line.
- **The attention sounds play only when workflow-dev needs the human** (WD-0052).
  `scripts/attention-alert.sh` is registered four times, and each entry only
  ever plays a sound — it prints nothing, never asks or denies, and exits 0:
  - `Stop` → `--stop`. A plain `Stop` fires after every response, which is the
    noise these sounds replace, so it plays only when a skill ran
    `attention-alert.sh arm <kind>` before ending the turn, and it plays that
    kind (the rule for when, and which kind, is
    `../references/attention-alert.md`). The arm is one file per session in the
    marker store; `--stop` consumes it with one `mv`, so the next `Stop` is
    silent again.
  - `PreToolUse` matcher `AskUserQuestion` → `--ask` ("I need your input."), and
    `Notification` matcher `permission_prompt` → `--notify` ("I need your
    permission."): both are real "blocked on you" moments, and both play only
    in a workflow-dev project (`.workflow-dev/context` in the payload's `cwd` or
    a parent), since a hook cannot see which skill asked.
  - `UserPromptSubmit` → `--prompt` drops the session's arm: a turn the human
    interrupts ends without a `Stop`, and its arm must not sound at the end of
    the next, ordinary response.
  - `idle_prompt` is deliberately not registered: it fires after any response,
    blocked or not.
  - One event, one sound: every play drops the session's arm, and an ask
    followed within 5 s by a permission prompt counts as one event. Any other
    pair — two asks, a prompt then an ask, an armed `Stop` right after a
    prompt — is two events, and both sound.
  - `Stop` and `UserPromptSubmit` run after every response in every project, so
    with nothing armed they return before starting any external process.
  - One limit a command hook cannot close: Claude Code runs a session's `Stop`
    hooks side by side and tells none of them what the others decided. If
    another plugin's `Stop` hook blocks the stop, the turn goes on after the
    sound already played; it came early, never twice.
- Naming a capability instead of a tool: `../references/harness-tools.md`.
