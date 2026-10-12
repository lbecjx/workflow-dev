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
| `start` | "Ok, let's start!" | the alerts were just turned on for this story (played by `init` with `play start`, never armed) |

## Who plays them

Hooks play them, never a skill (`scripts/attention-alert.sh`, see
`hooks/README.md`):

- **A question asked through the ask-question tool** plays `need` by itself
  (the `PreToolUse` hook), or `away` while an autonomous run keeps the Mac
  awake: the human walked away, so the line calls them back. A `caffeinate`
  kept on for Remote Control after the run counts too, until the session ends.
  Do nothing.
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

## Alerts for this story

The alerts are per story: a story sounds only while it has an entry in the
repo's `.workflow-dev/config.json` (`notifications`), and no entry means no
sound at all, `need` and `permission` included. `init` makes the entry (its
Phase 7, in either run mode, while the human is still there), and the last
output the human chose is kept in `~/.workflow-dev/config.json`, for the next
story. Resolve `PLUGIN_ROOT` as in "How to arm", with the story ID known:

1. `"$PLUGIN_ROOT"/scripts/attention-alert.sh prune` drops the entries of
   stories that are no longer in progress.
2. `"$PLUGIN_ROOT"/scripts/attention-alert.sh offer` prints the state on its
   first line: `first`, `suggest<TAB><output>`, or `list`. The other lines are
   the outputs (`recommended|-`, `default|-`, name), then `nospeaker` or
   `default-only`. On macOS the first call compiles a small helper with `swiftc`
   (a few seconds).
3. State `first`: say first, in these two short sentences: *"Some processes take
   minutes. Turn the alerts on and I'll tell you when something ends or when I
   need you."* This message comes with every story until the human has turned
   the alerts on once.
4. Ask, with the ask-question tool, worded per `references/user-language.md`:
   **Activate alerts for this story?** — `Yes (Recommended)` and `No`. Never
   recommend turning them off, and never save a `No`: it holds for this story
   only, and the next story asks again. On `No`, stop here.
5. On `Yes`, pick the output:
   - `suggest`: ask which output with `<output> (Suggested)` and
     `Choose source`; `Choose source` goes on to the list.
   - `list`, or `first`: ask **Which source will play them?** with the outputs,
     the recommended one first and marked `(Recommended)`. The ask-question tool
     takes four options at most: show the first three and leave the rest to
     "Other", where the human types the name. End the question with two short
     notes: *"Choose your speakers: when I call you, you may not have your
     headphones on."* and *"With low volume or on mute, you won't hear me."*
     With `nospeaker`, the first note becomes *"It will only sound in your
     headphones: keep them on."*
   - `default-only`: nothing can be chosen. Say in one line that this Mac plays
     the alerts on the current output, and use `default` as the output.
6. Save: `attention-alert.sh set-pref "<output>"`, then
   `attention-alert.sh activate <STORY-ID> "<output>"`, then
   `attention-alert.sh play start "<output>"`. If either save prints `unavailable` (no
   `jq` or `perl`, or an unreadable `config.json`), say in one line that the
   alerts need `jq` or `perl` and go on without them.

Keep every sentence the human reads to one or two short ones.

In autonomous mode this is part of the pre-autonomous checkpoint, not a
blocking question about the story: with no answer, use the saved output when
`offer` said `suggest`, else the default output (`default`), run
`attention-alert.sh activate <STORY-ID> "<output>"` and
`attention-alert.sh play start "<output>"`, and record the choice as `Agent (inferred)`.
Save no preference (`set-pref`) from that fallback: it is not the human's choice.

## Off, CI and unattended

Whether a story sounds, and on which output, is decided once per story by its
entry in the repo's `config.json` (see "Alerts for this story"). No environment
variable changes it. The alerts are silent in CI and in a non-interactive
session. Arm the same way regardless: the script decides whether anything plays.
