<!--
workflow-dev — a persistent-context development workflow for Claude Code
Copyright (C) 2026  lbecjx

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version. See LICENSE for the full text.
-->

# Text shown to the user

Every skill points here instead of restating these rules (WD-0043). A second
wording of the same rule is free to drift from the first.

## The language

Write all text the user reads in the language of the conversation. Infer it
each time from what the user writes. A skill never fixes it in advance.

This covers every message you write for the user:

- questions put through the ask-question tool: the question, its header, and
  each option's label and description
- the short line before a tool call
- progress reports and the summary at the end of a stage
- the final report of a run

Keep one language inside one option. Do not put an English label next to a
Spanish description.

## Quoted questions are templates

When a skill quotes a question and its options, the quote gives the meaning,
not the wording. Write that meaning in the user's language. Keep the order of
the options, and keep the mark on the recommended one.

## Say what the choice means to the user

A label and its description say what happens to the user after they pick it.
They do not describe what the agent writes or reads to make it happen.

- Do not name internal mechanics: a row in the Decisions table, a marker file,
  a skill's internal step.
- Do not use workflow jargon in a label: say "step by step", not "HITL".
- Keep the mechanics in the skill's own steps, where the agent reads them.

## Length

Keep each option description to one terminal line: about 60 characters, never
more than 80. A longer description is cut off in the picker, and the user sees
only part of it. Keep a label to a few words.

When the text comes from data, such as a story title in a list of stories,
shorten that data to fit. Do not let it wrap.

## Out of scope

These stay as they are, in any language:

- Text the harness writes: permission prompts, tool names, tool errors.
- Text a plugin script prints and the harness shows unchanged, such as a hook's
  `permissionDecisionReason`. A script cannot know the language of the
  conversation.
- Technical terms, code, file paths, commands, and exact error strings.
- Recorded values that other skills read: Decisions rows such as
  `Autonomous mode: on`, canonical Status and Resolution values, story IDs. Show
  them as they are, and explain them in the user's language.
