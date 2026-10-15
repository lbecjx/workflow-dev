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
| `start` | "Ok, let's start!" | the alerts were just turned on on this machine (played by `init` with `play start`, never armed) |

Four of them also reach the human's phone when the phone notices are on (see
"Phone notifications"): `away`, `permission` and `fail` at high priority, and
`story` at the normal one. Those are the moments a human away from the Mac must
know about. The others only sound.

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
`autonomous-keep-awake.sh stop`, and nowhere else. A wait on a question is not
a stop: the ask plays its own sound (above), so it arms nothing. The arms:

- the end-of-run report after every task group is done and the story-end
  `validate` passed → `story`;
- any stop on a problem (a FAIL it cannot fix, a block, a doubt it cannot infer
  while unattended, `inference-first.md`) → `fail`;
- a stop the human asked for → `done`.

No per-step skill arms during the run.

## Alerts on this machine

The alerts are one yes or no for the whole machine: the answer lives in
`~/.workflow-dev/config.env` (`notifications=on` or `notifications=off`), holds
for every story of every repo, and nothing turns it off when a story ends. No answer means no sound at
all, `need` and `permission` included. Every sound plays on the system's
default output, so nothing else is asked. It is asked with the other missing
setup answers, before any skill works on the story and before the run mode is
chosen: by the configuration interceptor (`scripts/config-check.sh`), and by
`init`'s Phase 0 if still missing, but only while the machine has no answer. Resolve `PLUGIN_ROOT` as in "How to arm":

1. `"$PLUGIN_ROOT"/scripts/attention-alert.sh get` prints `on`, `off` or
   `unset`. `on` or `off`: say nothing about the alerts and go on.
2. `unset`: say first, in these two short sentences: *"Some processes take
   minutes. Turn the alerts on and I'll tell you when something ends or when I
   need you."*
3. Ask, with the ask-question tool, worded per `references/user-language.md`:
   **Turn the notifications on?** They tell the human when you need their
   answer or finish something, and they play at the system's volume. Options:
   `Yes (Recommended)` and `No`. Never recommend turning them off.
4. Save the answer, `No` included: `attention-alert.sh set on` or
   `attention-alert.sh set off`. On `Yes`, then run
   `attention-alert.sh play start`, and say this tip in one line: *"If you step
   away from the computer, turn on your speakers so you hear the alerts from
   afar."* If `set` prints `unavailable` (the folder `~/.workflow-dev` cannot
   be written), say so in one line and go on without the alerts.

Keep every sentence the human reads to one or two short ones.

It comes before the run mode is chosen, so no autonomous notice applies
(`autonomous-mode.md`, "Before the run starts").

When nobody can answer (unattended), in any run mode: run
`attention-alert.sh set on`, say the tip, and record it as `Agent (inferred)`.
On is the human's chosen default (WD-0108): a run nobody watches is exactly
when the alerts are how it reaches the human.

## Phone notifications

A sound only reaches a human near the Mac. The phone notices reach them
anywhere: a push through [ntfy](https://ntfy.sh), a free app for iPhone and
Android with no account. They follow their own yes or no, separate from the
sounds: a human may want the phone and no sound, or the reverse. The answer is
one per machine, in `~/.workflow-dev/config.env` (`phone=on` or `phone=off`),
beside a secret topic (`phone_topic=wd-xxxx-xxxx-xxxx`); the script keeps that
file at mode 600.

The topic is the only key to the notices: whoever knows it can read them and
send forged ones. So it goes in no file the agent writes (the story file,
REPO.md, a Decisions row, a commit, a PR) and in no QR. It is shown once, at
setup, for the human to put in the app.

It is asked with the other missing setup answers, before any skill works on the
story and before the run mode is chosen: by the configuration interceptor
(`scripts/config-check.sh`), and by `init`'s Phase 0 if still missing, but only
while the machine has no answer. A machine that already answered the sounds is
still asked this once. Resolve `PLUGIN_ROOT` as in "How to arm", and use the
plugin's script for every step:

1. `"$PLUGIN_ROOT"/scripts/attention-alert.sh phone get` prints `on`, `off` or
   `unset`. `on` or `off`: say nothing about the phone and go on.
2. `unset`: ask, with the ask-question tool, worded per
   `references/user-language.md`: **Do you want push notifications on your
   phone?** Options: `Yes (Recommended)` and `No`. With other setup questions
   missing, ask them in as few calls as the tool allows, this one last: its yes
   leads into the steps below.
3. `No`: run `attention-alert.sh phone off`. Nothing else is said.
4. `Yes`: ask which phone the human uses, `iPhone` or `Android`, and whether
   they already have a topic from another Mac (they paste it) or need a new one.
   Run `attention-alert.sh phone on`. For a topic from another Mac, ask the
   human to copy it on this Mac and run `pbpaste | attention-alert.sh phone on -`:
   the topic never appears in a command, whose text any local user can read
   with `ps`. Never type it into the command yourself. It prints
   `topic <t>` and `clipboard copied|unavailable`, then
   `remote-control active|inactive`. Or it prints one of:
   - `invalid-topic`: ask once more for the topic;
   - `linked-config`: `~/.workflow-dev/config.env` is a symlink, often into a
     dotfiles repo that gets pushed, so the secret is not written there; when
     the phone had no answer yet, the script saved `phone=off`, so the question
     does not come back (a phone already on is left on). Say so in
     one line: once the config is a plain file, ask the agent to run `phone on`.
     Go on without the phone;
   - `unavailable`: say in one line that `~/.workflow-dev/config.env` (or the
     file it links to) cannot be written, and go on without the phone.
5. Show the QR that installs the app, then the topic, in one short reply:
   - Paste the store's QR from the plugin's own file, verbatim, in a fenced code
     block, with its link under it: `assets/qr-app-store.txt` for an iPhone,
     `assets/qr-google-play.txt` for Android. Read the file and paste it into the
     reply; never open it in Preview or any other app, and never draw a QR of the
     topic.
   - Show the topic once, and say in one line: open ntfy, tap **+**, paste the
     topic and tap **Subscribe**. On an iPhone, say the topic is already on the
     Mac's clipboard when the script printed `clipboard copied` (Universal
     Clipboard pastes it on the phone). On Android, say to type it.
   - Say in one line that iOS Focus modes (Work, Do Not Disturb, …) hide ntfy
     unless it is among the allowed apps.
6. Send a test notice with `attention-alert.sh phone test` (`sent`, `failed` or
   `no-topic`) and ask: **Did it arrive?** `Yes` / `No`. On `No`, give the two
   likely causes in one line (ntfy's notification permission is off, or a Focus
   mode hides it) and offer one retry: run `phone test` again and ask once more.
   After that, go on either way: the setup is saved.
7. Last, when step 4 printed `remote-control inactive`, say in one line, in the
   conversation's language: *"Turn on Remote Control with `/rc` to open the
   session in one tap from the notification."* Say nothing when it printed
   `active`. Never change the human's Remote Control settings.

Record the answer in the story's Decisions as `Phone notifications: on` or
`Phone notifications: off`, never with the topic.

When nobody can answer (unattended), in any run mode: save nothing and say
nothing, and record `Phone notifications: not asked (unattended)` as
`Agent (inferred)`. The setup needs a human holding the phone, so `on` would
push to nobody, and `off` would be a permanent no the human never gave. The
question comes back at the next run a human can answer.

Later, the human changes it by asking the agent to run `attention-alert.sh
phone off` (the topic is kept), `phone on` (back on with the same topic; it
prints `topic kept` and never shows the topic again, since the phone is already
subscribed),
`phone reset` (a new topic, when the old one may be known to someone else;
repeat steps 5 to 7) or `phone test`.

What a notice says: the title `workflow-dev`, then the repo's folder name, the
story's code when the session works on exactly one, and one short line for the
kind, in the conversation's language. Never the question, code or a path:
ntfy.sh keeps what it relays for some hours. With Remote Control on, tapping
the notice opens the session.

## Off, CI and unattended

Whether anything sounds is decided once per machine (see "Alerts on this
machine"). The human changes it later by editing `notifications=on|off` in
`~/.workflow-dev/config.env`, or by asking the agent to run
`attention-alert.sh set on` or `set off`. No environment variable changes it. The alerts are silent in CI and in a non-interactive
session. Arm the same way regardless: the script decides whether anything plays.

The phone notices follow the same rule: nothing is pushed in CI or in a
non-interactive session (`claude -p`). A run the human walked away from is
still an interactive session, so an autonomous run, or a run nobody watches,
does push: that is when the phone matters most. Sending never holds a hook: it
runs in the background with a 5-second limit, and a network error changes
nothing the human sees.
