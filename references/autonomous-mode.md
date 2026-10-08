<!--
workflow-dev — a persistent-context development workflow for Claude Code and OpenCode
Copyright (C) 2026  lbecjx

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version. See LICENSE for the full text.
-->

# Autonomous mode

`workflow-dev` is human-piloted by design and stays that way. Autonomous mode is
an **opt-in** way to run one story end-to-end without a human approving every
step. It is never the default, and it does not relax the workflow's guardrails —
it is the reason those guardrails exist in the first place. The value this
plugin adds over "just tell the harness to go" is exactly that the quality gate,
the Git History Disclosure review, and the attribution block keep running while
nothing is looking over the agent's shoulder.

This file is the single owner of what "autonomous mode" means. The skills
(`plan`, `implement`, `validate`, `save`, `summarize-changes`) reference it
instead of restating the rules; a second wording of the same rule is free to
drift from the first.

## The signal — how a run enters (and leaves) autonomous mode

Autonomous mode is signalled by a row in the active story's Working Memory →
Decisions table:

```markdown
| 2026-10-07 | Autonomous mode: on | Human |
```

- **Set** when the human says something like "ve autónomo" / "run this
  autonomously" / "go, and don't ask me each step". The agent records the row
  and proceeds; the human does not edit the file by hand.
- **Asked at init** when the human has not said how to run: `init` Phase 6
  step 8 asks through the ask-question tool (step by step vs. autonomous). The
  recommended and default answer is step by step; no answer never means
  autonomous.
- **Cleared** by removing the row (or writing `Autonomous mode: off`), at which
  point the run returns to human-in-the-loop behavior. Opt-in means the row is
  absent by default — its absence is the normal, human-piloted path.
- It lives in the story file because that is the persistent context on disk:
  the signal survives compaction and a new session, unlike an environment
  variable or a one-shot command argument that the next session would not see.

Detection is the agent reading the story file — the same way every skill already
reads `.workflow-dev/context/[STORY-ID].md`. There is deliberately **no
script** that detects the signal, because the only consumers of the signal are
the skills (read by the agent), and the commit/PR hooks do **not** need it — see
"Hooks" below.

## The one rule for every decision point: infer + record + report

Where a human-in-the-loop run would STOP and ask, an autonomous run does three
things instead, in order, and never skips any of them:

1. **Infer** — pick the answer the human most likely would, using the same
   default each skill already documents for its unattended/non-interactive
   branch. Do not re-derive a fallback the skill already owns.
2. **Record** — write the decision (and the reason it was inferred) to the
   story's Decisions table. A decision taken for the human that is not written
   down is a silent skip, and a silent skip is the one failure this mode must
   never have.
3. **Report** — surface it in the end-of-run report (see below), so the human
   sees every call that was made on their behalf.

This is the pattern `save` already uses ("running autonomously, use the inferred
one and record it without asking"), generalised to every decision point. The two
places that still lack a fallback today — `implement`'s per-task confirmation
and its decision points — get theirs from this rule.

## Save after every task group

`save` is not optional in an autonomous run. After each task group, `implement`
(Step 6) runs `/workflow-dev:save` itself rather than suggesting it, so the
Decisions it recorded, the progress, and the discoveries reach the story file
before the next task group starts. `save` applies without its confirmation in
this mode, and each save's contents go into the end-of-run report.

## The hard boundary — what autonomous mode never does

No decision point, however the inference goes, may cross these lines. They are
not judgment calls, and they have no autonomous fallback:

- **Never push to a protected branch** (never `git push` to `main`/`master` or
  whatever the repo's protected branch is).
- **Never merge** (never `git merge`, never `gh pr merge`).
- **Never skip the adversarial pass when it would run.** The depth is decided by
  `validate/references/rules.md` §11.0's unattended fallback — the mode consumes
  that fallback, it never invents a shallower one (see "Adversarial depth").
- **Never invent acceptance criteria.** If an AC is ambiguous and no human is
  there to clarify, the run stops and reports the ambiguity; it does not
  fabricate a criterion to satisfy.
- **Never bypass the AI/agent attribution block.** `pre-commit-message-check.sh`
  denies any commit/PR carrying AI/agent attribution, in autonomous mode exactly
  as in human-piloted mode. This is the one rule with **no bypass, ever** — the
  agent must not "help" the run along by editing attribution text past the check.

One question is required even in autonomous mode: when model tiering is not set up,
the tiering hook has the agent ask, before the first workflow-dev skill goes on, and wait for the answer
(configure the agents, or a default model for this story or this repo — see
`hooks/README.md`). No answer is inferred for the user; the run waits.

Everything else — a validation-mode choice, a manual-QA choice, a
no-repro-vs-complete depth — is an ordinary decision point and follows
"infer + record + report".

## The quality gate is load-bearing

In autonomous mode the quality gate is the *only* barrier left between the agent
and a bad commit. So:

- Any **FAIL** — a security finding, a broken build/test/typecheck, a CONFIRMED
  adversarial or algorithmic-integrity finding, a `.workflow-dev/` git-tracking
  drift — stops the run. The agent does not proceed to commit or PR; it fixes
  what it can and, if it cannot, reports and halts.
- A blocking finding is **never** downgraded to a warning to let the run
  continue. "Non-blocking by default" applies to the gate's *dimensions*, not to
  a finding that already reached FAIL.

## Adversarial depth — reference, don't re-derive

`validate/references/rules.md` §11.0 already owns the unattended depth fallback:
a normal single-diff run defaults to **no-repro**; the batched/story-end pass
uses the depth §11.0's own criteria recommend for that cumulative diff.
Autonomous mode consumes that fallback verbatim. It never re-debates depth, and
"make the adversarial cheaper because nobody is watching" is a different story,
not this one.

## Hooks — no change, and that is the point

The commit/PR hooks stay quiet during an autonomous run through the marker
mechanism they already share with the skills, not through any new signal:

- `pre-commit-validate-check.sh` stays silent when `validate` wrote the
  matching diff marker (`validate/SKILL.md` Step 6), or when the diff was
  deliberately deferred (`validate-mark-deferred.sh`).
- `pre-commit-message-check.sh` stays silent when `summarize-changes` marked the
  exact message/PR text reviewed (`git-message-mark-reviewed.sh`).
- The AI/agent attribution block (in `pre-commit-message-check.sh` and in
  `opencode/plugin.ts`'s `execute.before`) has **no** marker and **no** bypass.

So the hooks require no functional change and no signal-parsing: an autonomous
run writes the markers as part of its normal flow, and the hooks stay quiet for
the same reason they stay quiet in a human-piloted run. If a marker does *not*
match — the agent changed the diff after validating, or edited the message after
marking it — the hook asks, and in an unattended session that ask is exactly the
stop-and-report behaviour the quality gate calls for. That is the guardrail
working, not a bug to code around.

## The end-of-run report

An autonomous run does not end with "PR ready". It ends with a report the human
can audit, containing:

1. **What it did** — the task groups completed, per the plan.
2. **Every decision taken for the human** — one line each, with the inferred
   reason, pulled from the Decisions table entries the run recorded.
3. **What it deferred** — any validation deferred to the story-end pass, any
   finding left for the human, any ambiguity it stopped on.
4. **The cost** — `session-usage.sh --story [STORY-ID]`, the durable ledger's
   total by stage and by agent/role, reusing WD-0037's checkpoint mechanism.

## The PR boundary

An autonomous run **drafts** the commit message and PR title/description (via
`summarize-changes`, which marks them reviewed) and reports them to the human.
It **never opens the PR itself** — `git commit` and `gh pr create`/`gh pr edit`
remain human actions that require explicit approval, the same rule as a
human-piloted run. "Guardarraíl, no velocidad": the mode removes the per-step
confirmations, not the final sign-off.
