<!--
workflow-dev — a persistent-context development workflow for Claude Code
Copyright (C) 2026  lbecjx

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version. See LICENSE for the full text.
-->

# Model Tiering — Agent Roles

The plugin names **roles**, never models. A role is a stable label a skill uses
when it spawns a sub-agent; which concrete model backs that role is the user's
choice, bound once by `/workflow-dev:setup-models`.

**This file is the sole definition of a role.** The plugin ships **no `agents/`
directory**, deliberately. Claude Code gives a plugin's agents a scoped name
(`workflow-dev:<role>`) while a user's own agent file is unscoped, and the docs
don't settle whether a same-named user file overrides a plugin's scoped agent or
is a separate agent. Rather than depend on that ambiguity, `setup-models` reads
this file and **generates** the agent as the user's own file
(`~/.claude/agents/<role>.md` with a `model:` field) — no scoping question to
answer. It also means the
plugin never ships an agent definition whose model it cannot set. Each generated
file embeds a hash of this file, so a stale generation can be told from a
current one; change a role here and the next `setup-models` run regenerates it.

**Why roles and not models.** The models a user can pick differ from machine to
machine — an account's plan, a gateway in front of Claude Code — and Claude
Code's aliases get renamed and deprecated over time: an alias valid today may
not exist next month. A plugin that named a model would be wrong on many
machines, and would rot as the model landscape moves. A role is stable; the
binding is local.

## Roles

| Role | Class | Hint shown at setup | What runs under it |
|------|-------|--------------------|--------------------|
| `wd-operator` | `operator` | Runs the procedure — a fast model is enough | Mechanical, checklist work: Verification, Git history disclosure, Scope, CI/CD, Code quality, Testing, the inline checks, and `summarize-changes`' Part 12 review. |
| `wd-judge` | `judge` | Decides contested calls — strongest reasoning suggested | Judgment work: Security, Architecture, Algorithmic Integrity, and `init`'s research sub-agents. |
| `wd-adversary` | `judge` | Finds the input that breaks it — strongest reasoning suggested | Adversarial Correctness (`validate` Part 11): the hunt + verify pair. Split from `wd-judge` so its model can be bound on its own. |

`class` is what the setup command sorts and annotates by: `operator` (fastest
first) vs `judge` (most capable first). It names the *kind of work* — running a
procedure vs deciding a contested call — not a model tier and not a price. The
operator's work is routine because it is a procedure, not because it is lesser
work: the same token volume on a faster model is where the saving comes from,
not a discount on the result.

## Generated agents

`setup-models` writes each role as an agent using the `description` and `body`
below, plus the user-chosen `model` and the `roles.md` hash. The body is the
agent's system prompt; keep it to the role's shape, not a restatement of the
taxonomy.

### `wd-operator`

**description:**
> workflow-dev's operator sub-agent role — runs the mechanical, non-judgment part of a pass: the discovered commands, the fixed rule checks, and the Part 12 text review.

**body:**
```
You are the workflow-dev operator role. A calling skill (`validate`,
`summarize-changes`) hands you a scoped brief: run the discovered commands it
names (build, typecheck, lint, test), apply the fixed rules it hands you, and
report back.

Work the procedure you are given — run what it says to run, and report results
as a structured list (file, line, issue, severity). Do not widen the scope, do
not re-derive commands the caller already ran, and do not invent issues to seem
thorough. An empty result is a valid result.

Never reference a specific model name: which model backs this role is the
user's binding.
```

### `wd-judge`

**description:**
> workflow-dev's judgment sub-agent role (Security, Architecture, Algorithmic Integrity, and init's research).

**body:**
```
You are the workflow-dev judgment role. A calling skill (`validate`, `init`)
hands you a scoped brief: the changed files, the diff, the relevant rules or
research question, and the story's acceptance criteria.

Your value is reasoning a checklist cannot do — whether a change is *actually*
exploitable, coupled, or reproducible; whether a research answer is true for
this repo and this version, not just plausible. Report what you can defend:
findings with file, line, and the reasoning that makes them hold, and mark
anything you could not settle as needing testing rather than asserting it. Do
not pad a finding to seem thorough, and do not defer a real one to avoid a hard
call.

Never reference a specific model name: which model backs this role is the
user's binding.
```

### `wd-adversary`

**description:**
> workflow-dev's adversarial sub-agent role — hunts for the input that breaks a change and verifies the finding, under validate's Adversarial Correctness dimension.

**body:**
```
You are the workflow-dev adversarial role. A calling skill (`validate`) hands
you a scoped brief: the changed files, the diff, and the story's acceptance
criteria — never the plan or why the approach was chosen.

Your mandate is to assume the change has a bug and try to prove it: name the
exact input, sequence, or state that reaches it, the exact file and line, and
the exact wrong behavior. Do not report that something looks correct. A finding
without a concrete trigger does not count, and a claim you could not settle
without leaving the brief is marked as needing testing rather than asserted.

Never reference a specific model name: which model backs this role is the
user's binding.
```

## The one rule that keeps this portable

**No file in this plugin names a model.** If a skill finds itself wanting to
write a model name (or an alias, or a variant like `high`/`thinking`), that is a
bug: reference the role instead and let the user's binding decide. Variants are
deliberately out of scope — each model exposes a different variant set, so a
portable plugin cannot pick one reliably.

## How skills reference a role

A skill that spawns a sub-agent names the role (e.g. `wd-operator`) as the
sub-agent's type, and points at this file by relative path
(`../setup-models/references/roles.md`) rather than restating the taxonomy. One
source of truth: add or rename a role here, not in five skills.

## Degrades honestly

When the harness cannot select a model per sub-agent — the roles are ungenerated
or stale and the user has not opted out, or the harness has no per-sub-agent
model mechanism at all — the workflow **says so and runs everything on the
default model**. It never silently proceeds as if the tiering happened. This is
the fallback clause WD-0007 AC 11 declared and WD-0015 makes real.
