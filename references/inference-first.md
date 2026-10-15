<!--
workflow-dev — a persistent-context development workflow for Claude Code
Copyright (C) 2026  lbecjx

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version. See LICENSE for the full text.
-->

# Infer first, ask what you cannot infer

A question whose answer is already in the repo costs the human time and
teaches them to skim your questions. An answer you guess costs more: it
widens your authority without anyone seeing it. So, on a doubt, look for the
answer in the evidence first, and write down what you found. Ask only what the
evidence cannot settle, and never assume that answer, in any run mode (WD-0083).

This file is the one owner of that rule. `init`, `plan`, `implement`, and
`references/autonomous-mode.md` point here instead of restating it; a second
wording of the same rule is free to drift from the first.

## What this governs

**An ad-hoc doubt:** an open point that comes up while working a story. It
covers an item `init` marks ⬜, a decision point in
`../skills/implement/references/decision-points.md`, and a doubt `plan` meets
while it decomposes the story.

It does **not** govern the fixed questions a skill always asks, each with its
own owner and its own default: the run mode (`init`), the alerts
(`attention-alert.md`), agent co-authorship (`summarize-changes`), model
tiering (`tiering-question.md`), and the validation mode and manual QA (`plan`
Step 5). Those are the human's preferences, asked on purpose.

A fixed question's documented default is never evidence for an ad-hoc doubt.
"The skill's unattended branch says X" settles only that skill's own question.

## Infer first

Before you ask, look for the answer in this order:

1. The story: its source (the Jira issue or the `.md` file) and its context
   file, including its Decisions and Discoveries.
2. `REPO.md`.
3. The code: the files the doubt touches, and how the same thing is already
   done elsewhere in the repo.
4. Git history: `git log -S <term>`, `git log -- <path>`, `git blame` on the
   lines in question, and the messages of the commits that changed them.
5. The repo's own docs: README, `docs/`, ADRs, comments that explain why.
6. External docs, only when a tool for them is available in this session. A
   doubt about a library's API or version is looked up in its docs first
   (`library-docs.md`), before you assume it or ask.

Always read the code the doubt touches (source 3), even when the story or
REPO.md already seems to settle it: a convention written down can differ from
what the code does, and you only see that by reading both. Past that, stop at
the first source that settles the doubt. When two sources settle it
differently, that is contradictory evidence (below), not an answer.

## What is not inferable

A doubt is not inferable when it falls in any of these four classes. Each one
has a test; when the test holds, ask.

| Class | Test | Example |
|---|---|---|
| Product decision | Two reasonable owners of this product could choose differently, and the evidence names neither choice | A list must be sorted, and nothing says by date or by name |
| Human preference | The answer is a matter of the human's taste or habits, and the repo has no precedent for it | A tool, a library, or a name that nothing in the repo already uses |
| Data absent from the repo | The answer is a value nothing in the evidence states | A URL, a threshold, a limit, an account, a credential |
| Contradictory evidence | Two sources settle the doubt differently | REPO.md names one convention and the code follows another |

An ambiguous acceptance criterion falls in one of these classes, usually the
first. A doubt outside all four is inferable: settle it from the evidence.

## Recording an inferred answer

Write every answer you inferred to the story's Decisions table, with its
evidence, so the human can check it and correct it:

```markdown
| YYYY-MM-DD | <the doubt> → <the answer>. Evidence: <file:line, commit, or doc> | Agent (inferred) |
```

- The evidence is required. If you cannot name it, you did not infer the
  answer: you guessed it, and the doubt is not inferable.
- When the human corrects a row, rewrite it with their answer and `Human` as
  who decided. Never add a second row for the same doubt.
- Name each inferred answer in the report the skill hands back: the summary at
  the end of a stage, or, in autonomous mode, the end-of-run report
  (`autonomous-mode.md`).

## A doubt you cannot infer

First, write it to the story's Decisions table, so that a resumed session or a
new one finds it:

```markdown
| YYYY-MM-DD | Open question: <the doubt>. Not inferable: <class> | Pending (human) |
```

Then act by run mode. Check first whether the run is unattended (defined
below): unattended wins over the run mode, so a step-by-step or autonomous run
with nobody to answer takes the unattended branch.

- **Step by step:** ask the human with the ask-question tool, worded per
  `user-language.md`.
- **Autonomous, with a human who can answer:** ask with the ask-question tool,
  and wait for the answer. The run does not go on without it. While it waits,
  the Mac may sleep, and it is kept awake again once the run resumes
  (`autonomous-mode.md`, "Keeping the Mac awake").
- **Unattended** (no human can answer): stop this story. Do not start its next
  step. Report the open question as the reason for the stop, and arm the
  attention sound as `attention-alert.md` says for a stop on a problem.

When the answer comes, rewrite the `Open question:` row with the answer and
`Human` as who decided, then go on.

An `Open question:` row still `Pending (human)` blocks the story wherever it is
found. A skill that starts on the story (`resume`, `plan`, `implement`) puts
each such row to the human first, or stops when
unattended, before it plans or implements anything. An autonomous run never goes on past one,
whatever its `Autonomous mode` row says.

When you ask and the human rejects the question but types something, their
words are the answer or an instruction: follow them, and rewrite the row with
what they said and `Human` as who decided. If their words hand the choice back
to you ("you decide", "whatever"), that is their answer: pick from the
evidence, and write the row as `Agent (delegated by human)` with your choice
and why. Only an ask that returns
nothing from the human counts as no answer (below).

The definition below is for ad-hoc doubts only. When a skill says autonomous mode
"counts as unattended" for one of its fixed questions (`plan`'s validation
mode and manual QA, `validate`'s manual QA), that is about taking the fixed
question's default, never about a doubt: an autonomous run with a human present
still asks a doubt it cannot infer.

A run is unattended when any of these holds:

- The ask-question tool is not among your tools.
- You are a sub-agent: your caller owns every question to the human. Return
  the open question to the caller, which applies this rule itself.
- The session is not interactive: Claude Code sets
  `CLAUDE_CODE_SESSION_ATTENDED=0` under `claude -p`. Check it with the shell
  tool (`echo "${CLAUDE_CODE_SESSION_ATTENDED-unset}"`); unset means an older
  Claude Code, and counts as attended.
- You asked and the ask came back with nothing from the human: an error, or
  a dismissal with no words of theirs.

An autonomous run in an interactive session is not unattended. The human chose
not to approve each step, not to have their decisions made for them.

In every mode: never invent the answer, never pick a default for it, and never
go on with the most plausible reading. A wrong guess that nobody saw costs more
than the wait.
