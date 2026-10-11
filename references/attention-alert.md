<!--
workflow-dev — a persistent-context development workflow for Claude Code
Copyright (C) 2026  lbecjx

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version. See LICENSE for the full text.
-->

# The attention sounds — when a skill arms one, and which

Every skill points here instead of restating these rules (WD-0052). A second
wording of the same rule is free to drift from the first.

## What the sounds mean

workflow-dev speaks only when the human is needed: it is **waiting on the
human**, or it **finished something the human should review**. Claude Code's
own alerts fire after almost every response, so the human learns to ignore
them. These are worth trusting only because they stay quiet the rest of the
time. A sound at the wrong moment teaches the human to ignore it, so when in
doubt, do not arm.

Each kind is its own short spoken line, so the human knows what is waiting
before looking at the screen:

| Kind | The human hears | Meaning |
|---|---|---|
| `need` | "I need your input." | a question waits on the human |
| `away` | "Hello? Are you there?" … "I need your input." | the same, mid autonomous run (the hook picks it; never armed) |
| `permission` | "I need your permission." | a permission dialog is open |
| `commit` | "Ready to commit." | commit/PR text waits for the human's yes |
| `pr` | "Pull request created!" | the PR was just opened |
| `done` | "Task completed." | finished work is ready to review |
| `passed` | "Validation passed." | the quality gate passed |
| `fail` | "Something went wrong." | a check failed, or the run is stuck |
| `saved` | "Context saved." | a save the human asked for finished |
| `story` | fanfare, then "Congrats! Story complete." | the whole story is done |

## Who plays them

Hooks play them, never a skill (`scripts/attention-alert.sh`, see
`hooks/README.md`):

- **A question asked through the ask-question tool** plays `need` by itself
  (the `PreToolUse` hook), or `away` while an autonomous run keeps the Mac
  awake: the human walked away, so the line calls them back. Do nothing.
- **A permission prompt** plays `permission` by itself (the
  `Notification:permission_prompt` hook). Do nothing.
- **A turn that ends by handing control to the human in plain text** plays only
  when the skill **armed** it first, with the kind it armed. The `Stop` hook
  plays when the turn ends, and only for an armed session.

## How to arm

Run this right before the turn ends, after everything else the step does, with
the kind from the table above:

```sh
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd -P "<this skill's directory>/../.." && pwd -P)}"
"$PLUGIN_ROOT"/scripts/attention-alert.sh arm <kind>
```

It prints nothing and always exits 0, so it never stops the skill. A missing or
unknown kind plays `need`. Arming twice in one turn is harmless: the last kind
wins and the next `Stop` plays once. Never call `play`: it sounds at once,
before the human can see the text.

## When to arm, and with which kind

Arm only when the turn ends **and** the next move is the human's:

| Hand-back | Kind |
|---|---|
| a plain-text question that blocks the flow (approve the plan; pick an adversarial depth) | `need` |
| a task group closed, a stand-alone `manual-qa` report with every AC PASS | `done` |
| `validate`'s verdict: PASS (with or without warnings) | `passed` |
| `validate`'s verdict: FAIL; a `manual-qa` report with a FAIL or BLOCKED AC; any step that stops on an error it cannot fix | `fail` |
| the commit message or PR text handed back, waiting for the human's yes | `commit` |
| the PR was just opened and its URL handed back | `pr` |
| `save` finished a save the human asked for, and wrote something | `saved` |
| the story is complete: `save` just wrote `Implementation Status: Done` | `story` |

A turn arms one kind. When `save` writes `Implementation Status: Done` it arms
`story` and never `saved`; the last arm wins, so arming both would drop the
fanfare.

Do **not** arm:

- **from a sub-agent.** Only the main agent arms; a sub-agent's turn ending is
  not the human's turn.
- **when the run goes on by itself.** A step that chains into the next one in
  the same turn (`implement` → `validate` → the next task group) is normal
  execution, and a sound there is the noise this replaces.
- **when the skill is nested in another skill's run** (`manual-qa` inside
  `validate`, `validate` or `summarize-changes` inside `implement`). The outer
  run arms when it hands back. A `save` that a hook asked for after a
  compaction is nested too: only a save the human asked for arms `saved`.
- **when `save` wrote nothing.** Declining the summary, or nothing to save, hands
  back no news.

## In autonomous mode

An autonomous run (`references/autonomous-mode.md`) hands control back only
where it lets the Mac sleep again: the end-of-run report, and every stop listed
in "Keeping the Mac awake". Arm exactly there, right after
`autonomous-keep-awake.sh stop`, and nowhere else:

- the end-of-run report after every task group is done and the story-end
  `validate` passed → `story`;
- any stop on a problem (a FAIL it cannot fix, an ambiguous AC, a block) → `fail`;
- a stop the human asked for → `done`.

No per-step skill arms during the run.

## First story on a machine — where and how loud

The sounds play on the system's default output, which is often a headset the
human takes off when they walk away. So the first `init` on a machine (its
Phase 7, in either run mode, while the human is still there) asks two questions,
once, and saves the answers for every repo on this machine. Resolve
`PLUGIN_ROOT` as in "How to arm", then:

1. `"$PLUGIN_ROOT"/scripts/attention-alert.sh device` — if it prints anything
   but `unset`, a choice exists: ask nothing.
2. `"$PLUGIN_ROOT"/scripts/attention-alert.sh suggest` — the machine's own
   speakers (a built-in output), or nothing. On macOS the first call compiles a
   small helper with `swiftc` (a few seconds).
3. Ask, with the ask-question tool, worded per `references/user-language.md`:
   - **Question:** this plugin speaks short alerts when it needs your
     attention; where should they play?
   - **Option 1** (only when step 2 named an output): `Speakers (<name>)
     (Recommended)` — "Always these speakers, even with a headset on."
   - **Option 2:** `Default output` — "Whatever output you are using."
4. Ask, with the ask-question tool, in the same call:
   - **Question:** how loud?
   - Options, in this order: `Low (25%)`, `Medium (50%) (Recommended)`,
     `High (75%)`, `Full (100%)` — each a share of that output's own volume.
5. Save: `attention-alert.sh set-device "<name>"` (or `set-device default`) and
   `attention-alert.sh set-volume <25|50|75|100>`. When `set-device` prints
   `saved-default-output`, say in one line that this Mac cannot route to that
   output yet (no `swiftc`), so the alerts play on the default output.

In autonomous mode these two are part of the pre-autonomous checkpoint, not a
blocking question about the story: with no answer, save `default` and `50`, and
record them as `Agent (inferred)`. The human changes either later with the same
two commands, or overrides them in settings `env`
(`WORKFLOW_DEV_ATTENTION_DEVICE`, `WORKFLOW_DEV_ATTENTION_VOLUME`). A volume of
`0` is accepted and silences the alerts; turning them off is
`WORKFLOW_DEV_ATTENTION=off`.

## Off, CI and unattended

The human turns the sounds off, or swaps them for one file, in Claude Code's
settings `env` (`WORKFLOW_DEV_ATTENTION`, `WORKFLOW_DEV_ATTENTION_SOUND`; see
the README). They are silent in CI and in a non-interactive session. Arm the
same way regardless: the script decides whether anything plays.
