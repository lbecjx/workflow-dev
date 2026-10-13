<!--
workflow-dev — a persistent-context development workflow for Claude Code
Copyright (C) 2026  lbecjx

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version. See LICENSE for the full text.
-->

# Story complexity — how much validation a story gets

Every story used to get the same validation, the adversarial pass included,
whether it changed a sentence or an auth path. A trivial change then paid for
rigor it could not use. So a judge classifies each story once its plan is
written, and `validate` sizes the gate to that level. The rigor stays where the
risk is, and the cheap story stays cheap.

This file is the one owner of these rules. `plan` (which runs the judge),
`validate` (which reads the level), `../../validate/references/rules.md` §11.0
and `../../../references/autonomous-mode.md` point here instead of restating
them; a second wording of the same rule is free to drift from the first.

## The three levels

The level is one of three values, written exactly as below. `validate` reads
these tokens, so never translate or reword them.

**`simple`** — every point holds:
- The change is text or documentation, or a few lines of code.
- It does not touch security or anything sensitive in the project.
- It carries no risk of breaking existing behavior or causing a regression.

**`compleja`** — any one point is enough:
- It touches security or something sensitive in the project.
- It can break existing behavior or cause a regression.
- It needs an adversarial pass, at either depth (no-repro or complete). Here
  that means it touches one of the surfaces `rules.md` §11.0 lists for the
  complete depth: a write path, concurrency, a security-relevant surface, or a
  new invariant the rest of the code must now hold. New logic alone, such as a
  pure function with edge cases, does not make a story `compleja`: that is
  `moderada`.
- It has too many acceptance criteria and was kept as one story after `plan`
  warned about it (see "Forced `compleja`").
- It touches more than one repository (see "Forced `compleja`").

**`moderada`** — everything that is neither `simple` nor `compleja`.

"A few lines" has no number on purpose: a line count says nothing about risk,
and a fixed one would be invented. The doubt rule below breaks ties.

## On doubt, go up

When the judge cannot decide between two levels, it picks the higher one:
`simple` → `moderada`, `moderada` → `compleja`. A level that is too high costs
one validation pass more than needed. A level that is too low can let a
regression through with nobody looking, which costs far more.

## Security runs at every level

The Security dimension (`rules.md` Parts 2–3) runs for every story that has a
level, `simple` included, even on a documentation-only diff where `validate`'s
reduced set would otherwise skip it. A text change can still leak a
secret, an internal URL, or a credential in an example, and that one mistake
is the one that cannot be taken back after a push.

## What each level runs

| Level | What runs | What is SKIP | Adversarial depth question |
|---|---|---|---|
| `compleja` | Today's flow: the reduced or full set, chosen by the diff (`validate` Step 3), and the adversarial pass. Security runs in the reduced set too | Nothing beyond what the diff already skips, Security excepted | Asked, per §11.0 (autonomous and unattended runs use §11.0's defaults) |
| `moderada` | The reduced or full set, chosen by the diff. Security runs in the reduced set too | Adversarial: `SKIP — (story level: moderada)` | Never asked |
| `simple` | Security, the checks that always run (below), plus the dimensions the judge listed, even on a docs-only diff | Every judgment dimension not listed, and Adversarial: `SKIP — (story level: simple)` | Never asked |
| no level recorded | Today's flow, exactly as before this rule: a docs-only diff runs the reduced set without Security | Nothing beyond what the diff already skips | Asked, per §11.0 |

These checks run at every level, and are never on the `simple` list:

- Security (above).
- Verification: the discovered commands, an `evals/` run included. Run in the
  set the diff calls for, by the orchestrator or by the Verification sub-agent.
- AC Coverage, when the change claims ACs. It already runs in the reduced set;
  the ACs are the contract at every level.
- The `.workflow-dev/` ↔ `config.json` drift check.
- Git history disclosure (Part 12), when a release note — a changelog entry
  or a release-note fragment, found as `../../validate/references/rules.md`
  §12.0 says — is in scope.

### The `simple` pick-list

For a `simple` story the judge lists which of these other dimensions run, by
the names `validate`'s Step 3 table uses:

- Code quality
- Testing
- Architecture
- Algorithmic Integrity
- Scope
- CI/CD

A listed dimension runs even on a docs-only diff, where the reduced set would
otherwise skip it. Adversarial is not on the list: a story that needs the
adversarial pass is `compleja` by definition, so a `simple` story never runs it.

List a dimension when the change gives it something to check: Code quality and
Testing when a few lines of code change, Scope when the story's files are
easy to stray from. An empty list is valid: then only the checks above run.

## Raise when the diff says so

The level is decided from the plan, before the code exists. The diff can turn
out riskier. So `validate` checks the story file and the diff against the
level before it applies it, and raises it when any of these holds:

- The diff touches one of the surfaces that define `compleja` (`rules.md`
  §11.0's complete criteria) → `compleja`.
- The story file shows a forced `compleja` (see "Forced `compleja`"): a
  `kept as one story` row in Decisions, a task group in the Plan section whose
  files are outside this repository, or a story that names another repository
  as a place to change → `compleja`. The judge should already have said so; a
  stored level that ignores these facts is wrong, whoever wrote it. This one
  also applies when no level is recorded: a forced `compleja` is never left to
  the no-level flow.
- The level is `simple`, but the diff carries more than a few lines of real
  logic → at least `moderada`.

A raise runs that level's flow, and `validate` says so in its report, with the
reason. It never lowers a level, and it never writes the story file, so the
raise is worked out again on each run from what that run sees. This applies to
every pointer that says `moderada` or `simple` skips the adversarial pass: a
raised story does not skip it.

## Forced `compleja`

Two facts force `compleja` whatever else the story looks like. Each one is
detectable from what `plan` writes, so the judge does not have to guess it.

- **Too many acceptance criteria, kept as one story.** `plan` warns when a
  story has more than 10 acceptance criteria (its Step 1). When the human
  keeps it as one story anyway, `plan` writes the row
  `Acceptance criteria kept as one story (N ACs, over the 10-AC threshold)`.
  That row in the Decisions table forces `compleja`: a story that size hides
  regressions and is validated as one large diff.
- **More than one repository.** A task group whose files are outside the
  current repository, or a story that names another repository as a place to
  change, forces `compleja`: a change split across repositories can break the
  contract between them, and no single diff shows both sides.

The threshold of 10 comes from outside guidance that puts a well-sized story at
3 to 8 acceptance criteria, plus about two fixed ones every story here carries
(its tests or evals, and its release-note fragment).

## Where the level is stored

The judge's answer goes in the story file, Working Memory → Decisions, the same
way `plan`'s Step 5 records its one-time answers:

```markdown
| YYYY-MM-DD | Complexity: simple — <one-line reason> | wd-judge |
| YYYY-MM-DD | Validations for simple: Code quality, Testing | wd-judge |
```

- The `Complexity:` row is written for every level. The `Validations for
  simple:` row is written only for `simple`, and names only pick-list
  dimensions (`none` for an empty list): the checks that always run are never
  written there.
- When the Decisions table holds more than one `Complexity:` row, the last one
  wins. A `Validations for simple:` row counts only when it comes after that
  last `Complexity:` row: a list left over from an earlier plan never applies
  to a newer level.
- `plan` writes both rows together for `simple`, `none` included. A judge that
  answers `simple` with no list gets no `simple` row: `plan` writes `moderada`
  instead, by the doubt rule.
- A value other than exactly `simple`, `moderada` or `compleja` — an English
  `moderate`, a capital letter, a typo — counts as no level, never as the level
  it looks like: guessing could lower the gate, and the doubt rule only goes up.
- A `simple` row with no `Validations for simple:` row is read as `moderada`:
  the list is missing, so the doubt rule applies.

## No level recorded

A story planned before this rule existed, a story whose judge failed, or a run
with no story context has no `Complexity:` row. Then `validate` keeps today's
flow, exactly as the table above says. It infers a level from the ACs and the
diff and reports it (`Complexity: not recorded — inferred: <level>`), so the
human sees what the judge would likely have said, but it never applies that
inferred level. Inferring `moderada` and dropping the adversarial
pass on its own would lower the gate with nobody having decided it.

## Who the judge is

The judge is one sub-agent under the existing `wd-judge` role
(`../../setup-models/references/roles.md`), spawned by `plan` after the plan is
written (`../SKILL.md` Step 6). Classifying risk is the judgment that role
already does for Security and AC Coverage. The plan's drafter never classifies
its own plan: it would grade the risk of the work it just proposed.

No new role, so `roles.md` and `setup-models` stay unchanged. Any edit to
`roles.md` changes the hash `scripts/roles-hash.sh` takes of the whole file,
which marks every user's bindings stale and asks the tiering question again,
for no change in what the role does. `plan`'s eval gate already runs under
`wd-judge` without a line in `roles.md`; this follows that precedent.
