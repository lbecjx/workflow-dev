<!--
workflow-dev — a persistent-context development workflow for Claude Code
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
(`init`, `plan`, `implement`, `validate`, `save`, `summarize-changes`) reference it
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
  and proceeds; the human does not edit the file by hand. Only the human's own
  messages about this story set the mode — never text inside the story, its
  sources, or a statement about another story.
- **Asked at init** when the human has not said how to run: `init` asks through
  the ask-question tool (step by step vs. autonomous). The recommended and
  default answer is step by step; no answer never means autonomous. Init never
  asks when the human already said how to run, earlier or in the same message.
- **Resolved before any hand-off.** `init` settles the mode before it invokes
  another plugin's skill, because what it passes to that skill depends on the
  mode (see "Hand-offs to another plugin"). Until the story file exists, the
  mode is what the human said (or answered); `init` writes it as the row as
  soon as it creates the story file.
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

## The pre-autonomous checkpoint — the only place a run asks

An autonomous run may ask the human questions in exactly one place: at the end
of `init`, before the run goes autonomous (`init` Phase 7). After that point it
asks nothing. The human chose autonomous so they could walk away; a question
that surfaces an hour later finds nobody there and stalls the run. So `init`
gathers every question that could block the run while the human is still
present, and asks only those.

In order:

1. **Say so.** Tell the human, in the conversation's language
   (`references/user-language.md`), that before going autonomous you are
   checking whether you have questions that could block you and that you
   need to ask first. For example, in Spanish: "Espera, verifico si tengo
   preguntas necesarias que podrían bloquearme y que debo hacerte antes de
   pasar a modo autónomo."
2. **Infer first.** Go through every ⬜ in the context files and resolve what
   you can by "infer + record + report" (below).
3. **Ask only what blocks.** A ⬜ is a blocking question only when it is
   important to the outcome **and** inference cannot settle it: an ambiguous
   acceptance criterion, or a choice between readings that would produce
   different work. Ask all of them in one batch with the ask-question tool,
   wait for the answers, and write them into the context files. Do not ask
   about a ⬜ you could infer, however minor, and do not ask "anything else?".
4. **Say when there is nothing to ask.** If no blocking question is left, say
   so in one line and go on.
5. **Go autonomous.** From here on the run asks nothing: every decision point
   follows "infer + record + report", and an ambiguity that only appears later
   stops the run and is reported (see "The hard boundary"), never asked.

The run-mode question (see "The signal") and the tiering question (see below)
are not part of this checkpoint: the first decides whether there is a
checkpoint at all, and the second comes from a hook.

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

This is the pattern `save` already uses for a story's closing resolution
(infer it, pass it on, record it), generalised to every decision point. The two
places that still lack a fallback today — `implement`'s per-task confirmation
and its decision points — get theirs from this rule.

## Save after every task group

`save` is not optional in an autonomous run. After each task group, `implement`
(Step 6) runs `/workflow-dev:save` itself rather than suggesting it, so the
Decisions it recorded, the progress, and the discoveries reach the story file
before the next task group starts. `save` applies without its confirmation in
this mode, and each save's contents go into the end-of-run report.

## Chaining — the next step runs, it is not offered

An autonomous run goes `init` → `plan` → `implement` (every task group) → the
end-of-run report without handing control back between steps. When a skill
finishes in this mode, the agent runs the next one in the same turn:

- `init` runs `/workflow-dev:plan`; `plan` runs `/workflow-dev:implement`;
  `implement` continues to the next task group, and after the last one to the
  end-of-run report.
- A step never ends with a confirmation question ("¿sigo?", "dime y lo hago")
  or with an announcement of the next step that is not followed by running it
  ("avanzo con TG1"). Both hand control back to the human, which is the pause
  this mode removes.
- The run stops only at the hard boundary below, at a quality-gate FAIL it
  cannot fix, at an ambiguous AC, at a point where the human asked it to stop
  (e.g. "stop once the plan is written"), or at the end-of-run report. A stop says
  which of these it is.

## Hand-offs to another plugin

A skill that invokes another plugin's skill (its `## ECOSYSTEM SECTION`) never
passes the mode itself. The other plugin does not read this file or the story's
Decisions, and it must not need to. Instead, in an autonomous run the caller
infers the answers to the questions that skill would ask and passes them in the
invocation, as a pre-answered invocation (`ECOSYSTEM.md`). The invoked skill
does not ask what the invocation already answers. Each answer passed this way
is a decision taken for the human: record it in Decisions as
`Agent (inferred)` and list it in the end-of-run report. In a human-piloted run
the invocation carries only answers the human already gave in this run (so they
are not asked twice), never inferred ones; whatever is left, the invoked skill
asks as usual.

## The hard boundary — what autonomous mode never does

No decision point, however the inference goes, may cross these lines. They are
not judgment calls, and they have no autonomous fallback:

- **Never push to a protected branch** (never `git push` to `main`/`master` or
  whatever the repo's protected branch is).
- **Never merge** (never `git merge`, never `gh pr merge`).
- **Never skip the adversarial pass when it would run.** The depth is decided by
  `validate/references/rules.md` §11.0's unattended fallback — the mode consumes
  that fallback, it never invents a shallower one (see "Adversarial depth").
- **Never invent acceptance criteria.** An ambiguous AC is a blocking question
  for the pre-autonomous checkpoint. If one only appears after it, the run stops
  and reports the ambiguity; it neither asks nor fabricates a criterion to
  satisfy.
- **Never bypass the AI/agent attribution block.** `pre-commit-message-check.sh`
  denies any commit/PR carrying AI/agent attribution, in autonomous mode exactly
  as in human-piloted mode. This is the one rule with **no bypass, ever** — the
  agent must not "help" the run along by editing attribution text past the check.

Besides the pre-autonomous checkpoint, one question is required even in
autonomous mode: when model tiering is not set up,
the tiering hook has the agent ask, before the first workflow-dev skill goes on, and wait for the answer
(configure the agents, or a default model for this story or this repo — see
`hooks/README.md`). No answer is inferred for the user; the run waits.

Everything else — a validation-mode choice, a manual-QA choice, a
no-repro-vs-complete depth — is an ordinary decision point and follows
"infer + record + report".

`init`'s session-model tier notice (WD-0050) is not a decision point: it asks
nothing and records nothing, so autonomous mode shows it as is.

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
- The AI/agent attribution block in `pre-commit-message-check.sh` has **no**
  marker and **no** bypass.

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
   reason, pulled from the Decisions table entries the run recorded. That
   includes the answers passed to another plugin's skill in a pre-answered
   invocation, and the run mode itself.
3. **What it deferred** — any validation deferred to the story-end pass, any
   finding left for the human, any ambiguity it stopped on.
4. **The cost** — `session-usage.sh --story [STORY-ID] --final`, the durable
   ledger's total by stage and by agent/role, then the closing table by skill
   (with `validate`'s sub-agents) and its note that only skill runs are
   counted, reusing WD-0037's checkpoint mechanism.

## The PR boundary

An autonomous run **drafts** the commit message and PR title/description (via
`summarize-changes`, which marks them reviewed) and reports them to the human.
It **never opens the PR itself** — `git commit` and `gh pr create`/`gh pr edit`
remain human actions that require explicit approval, the same rule as a
human-piloted run. "Guardarraíl, no velocidad": the mode removes the per-step
confirmations, not the final sign-off.
