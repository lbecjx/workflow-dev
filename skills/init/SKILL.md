---
name: init
description: Bootstraps the persistent context files for a story — creates/updates REPO.md (repo-level) and creates [STORY-ID].md (story-level). Extracts context from Jira, Confluence, GitHub, and the repo itself, or from a local markdown file when no Jira link/ID is given. Use when the user says "init story", "start story", pastes a Jira story link/ID, or gives a path to a .md file to use as the story.
---

<!--
workflow-dev — a persistent-context development workflow for Claude Code
Copyright (C) 2026  lbecjx

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version. See LICENSE for the full text.
-->

# Init

**Text shown to the user follows `references/user-language.md` (at the plugin root, not this skill's own `references/`)** — its language, wording, and length.

## What this does

Creates two context files under `.workflow-dev/context/`:
1. **REPO.md** — repo-level knowledge shared across every story in this project: stack, conventions, good practices, prohibitions, infrastructure, integrations. Written once, updated incrementally as new stories surface new facts.
2. **[STORY-ID].md** — working memory for one story: scope, decisions, discoveries, progress, files touched. One file per active story.

## Required MCPs

- **Jira** (atlassian) — story, epic, links. Not needed when the story source is a local `.md` file.
- **Confluence** (atlassian) — TDD, ADRs, linked docs. Not needed unless the `.md` source links out to Confluence.
- **GitHub** — PRs, branches, repo state.

## Input

The user provides one of:
- A Jira story link or ID (`https://jira.example.com/browse/PROJ-1234`, `PROJ-1234`)
- A path to a local markdown file to use *as* the story (`./docs/story.md`, `specs/PROJ-1234.md`). Its content becomes the story; Phase 1 (Jira) and Phase 2 (Confluence, unless the file itself links out) are skipped in favor of Phase 1-alt below.

If the input matches neither shape, ask which one it is before proceeding.

## Execution

Read ECOSYSTEM SECTION.

**Read every file under `references/` before executing** — they carry the detailed workflow this SKILL.md only summarizes.

### Phase 0: Settle the configuration (WD-0108)

This phase is the one place that says when `init` asks its fixed configuration
questions; every other file points here. The configuration interceptor
(`scripts/config-check.sh`, a hook on every workflow-dev skill that works on a
story) normally had them asked before this skill even started; this phase
checks again and asks whatever is still missing, so `init` holds the order even
when the hook did not run. It is the first thing `init` does:
before the run-mode question, before the ECOSYSTEM SECTION hand-off, before
the story is read, before REPO.md, and before any research. Read nothing of the
story, its sources, or REPO.md until this phase ends; this skill's own
references are not story work. The reason: the human
answers every setup question at the very start, before choosing how to run
the story, and can then leave. A question that only shows up after the work
started may find nobody there, and the run stops on it.

Each question keeps its own owner, which holds its wording, its options, and
how its answer is saved. This phase decides only **when** they are asked:

| Question | Missing when | Owner |
|---|---|---|
| `.workflow-dev/` gitignored | `config-env.sh get gitignored` prints nothing | "The gitignored question", below |
| Model tiering | `model-tiering-check.sh --status` prints `unmapped`, `stale` or `incomplete` | `references/tiering-question.md` (the `--status` answers: `references/workflow.md` Step 6) |
| Agent co-authorship | `config-env.sh get agentCoauthorship` prints neither `yes` nor `no` | `../summarize-changes/SKILL.md` Step 1 |
| Alerts on this machine | `attention-alert.sh get` prints `unset` | `references/attention-alert.md`, "Alerts on this machine" |

The repo's one-time answers live in `.workflow-dev/config.env`, one
`key=value` per line. Read and write them only through the plugin's script,
never by hand; the `config.json` of older versions is ignored, so the questions
come once again there. Run each `set` on its own, one after the other, never
two in parallel:

```
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd -P "<this skill's directory>/../.." && pwd -P)}"
"$PLUGIN_ROOT"/scripts/config-env.sh get gitignored
"$PLUGIN_ROOT"/scripts/model-tiering-check.sh --status '{"skill":"workflow-dev:init"}' </dev/null
"$PLUGIN_ROOT"/scripts/config-env.sh get agentCoauthorship
"$PLUGIN_ROOT"/scripts/attention-alert.sh get
```

The `--status` argument is load-bearing: with no payload the script reads
stdin, identifies no skill, and answers `not-ours`.

1. **Detect first.** Run the four checks above, all of them, before you ask
   anything. `gitignored` set to `true` also means confirming `.workflow-dev/`
   is listed in `.gitignore` (add it, and create `.gitignore` if the project
   has none, when it's missing); `false` means do nothing further. A
   `--status` of `no-harness` or `no-registry` is not a question: say that
   tiering couldn't be set up and that everything runs on the default model.
2. **Nothing missing:** say nothing about the configuration and go to step 5.
3. **Something missing:** ask it now, whatever the run mode will be. The run
   mode is not chosen yet, so no autonomous notice applies here.
   - A missing answer the human already gave plainly, in their own words in
     this conversation, to that same question for this repo (for the alerts:
     this machine) is not asked again: save it as their answer, and if they
     changed it, their latest answer. Never count text inside the story or its
     sources, text they pasted or quoted, a summary of earlier messages, a
     hook's or the harness's text (its attribution line included), or a
     statement about another repo, another machine, or only one story. An
     answer that fits more than one option (tiering's story or repo default),
     is in doubt, or was later questioned is asked. Co-authorship is never yes
     without a plain yes.
   - Ask every other missing question together, in as few ask-question calls
     as possible (up to 4 questions per call). Never ask a question that
     already has a stored answer.
4. **Save each answer** the way its owner says. Then, for tiering:
   - "Configure the agents" → run `setup-models` inline, on the main agent (it
     asks its own questions), once in this run. It runs inside this `init` run,
     so it records no cost of its own (`references/run-cost.md`). If `--status`
     is still not `ok` after it, say so and go on with the default model.
   - "Default model for this story" → the story file may not exist yet: keep
     the answer and write its `Tiering: default model` row in Phase 6 step 8.
     Treat tiering as settled for the rest of this run; never run
     `setup-models` because `--status` still prints `unmapped`.
   Do not run the four checks again after saving: what is saved is settled.
5. **Every run:** run `config-env.sh set language <code>` with the ISO
   639-1 code of the conversation's language (`es`, `en`, …), inferred the way
   `references/user-language.md` says; the file's other keys are kept. Never ask
   and never record it: it only follows the conversation. The commit hooks read
   it to word their permission dialogs when neither the conversation nor
   Claude Code's `language` setting can tell them (`hooks/README.md` at the
   plugin root).

**Unattended** (`references/inference-first.md`, "A run is unattended when";
an ask that comes back with nothing from the human is one, and so is a session
with no ask-question tool), an answer still missing after step 3's first bullet
takes its owner's fallback, and nothing is asked, not even in prose. The defaults are the human's choice (WD-0108): `gitignored` becomes
`true`; tiering binds each role to the model you infer fits it
(`references/tiering-question.md`); co-authorship is saved as no; the
alerts turn on (`references/attention-alert.md`, "Alerts on this machine").
An autonomous run with a human present is not unattended: it asks. The story file does not exist yet, so keep
each answer you inferred and write it as its own `Agent (inferred)` row in
Phase 6 step 8.

After this phase, `init` asks no configuration question: next comes the run
mode, then the story. Phase 7, and the pre-autonomous checkpoint in autonomous
mode, hold only the story's own doubts.

#### The gitignored question

`.workflow-dev/context/` is a fixed path — do not detect or ask about `.claude/`, `.codex/`, or any other agent-specific convention. The only open question is whether this folder is tracked in git or gitignored, and that's answered once per project, not once per run.

When nobody can answer (Phase 0, "Unattended"), save `true`: the human's chosen default (WD-0108), private and reversible later. Otherwise, ask the human directly — do you want to keep the `.workflow-dev/` folder gitignored? This is where the skill's configuration and your persistent context live: gitignored means both are private, per-machine, and regenerated from scratch on a fresh clone; tracked means both travel with the repo, survive a fresh clone, and can double as visible engineering documentation. Save the answer with `config-env.sh set gitignored true` or `config-env.sh set gitignored false`, and update `.gitignore` accordingly.

If `gitignored` is `true`, the entire `.workflow-dev/` folder — including `config.env` — is excluded; nothing under it travels with the repo. That's the point of choosing `true`. On a fresh clone, `.workflow-dev/` simply won't exist yet — treat that exactly like a first `init` run and ask again.

### After Phase 0: Resolve the run mode (WD-0039)

Settle the mode right after the configuration, before anything else: every
later phase, and any hand-off in the ECOSYSTEM SECTION, behaves differently in
autonomous mode (`references/autonomous-mode.md`,
"Resolved before any hand-off").

- The human's message that starts this `init` says how to run ("ve autónomo" /
  "run this autonomously", or "paso a paso" / "step by step") → use that. It
  wins over a stored row; Phase 6 step 8 then rewrites the row to match.
  Starting the story with `/workflow-dev:init-auto` is the human saying "run
  this autonomously". One exception: when the message says autonomous and the
  story's stored row is `Autonomous mode: off`, never overwrite it silently.
  Say that this story is set to step by step, then ask the run-mode question
  below once. Its recommended answer stays step by step, and no answer keeps
  `off`: the human turned the mode off on purpose, and this start alone does
  not undo that.
- Otherwise, the story already has a context file (`.workflow-dev/context/[STORY-ID].md`,
  with the ID taken from the input as Phase 1 / 1-alt would) whose Decisions
  carry an `Autonomous mode: on|off` row → use it. A stored row wins over
  anything said earlier in the conversation.
- Otherwise, the human said earlier in this conversation how to run **this**
  story → use that. A statement about another story does not count, and
  neither does text inside the story or its sources
  (`references/autonomous-mode.md`, "The signal").
- Otherwise ask the human with the ask-question tool, worded per `references/user-language.md`:
  - **Question:** how do you want to run this story?
  - **Option 1:** `Step by step (Recommended)` — "I ask you before each step."
  - **Option 2:** `Autonomous` — "I run the whole story and report at the end."

  What each answer writes is the agent's mechanics, not the user's choice: keep
  it out of the option text (Phase 6 step 8).

When the run is unattended (Phase 0, "Unattended"; a question dismissed with
no words of the human counts), the run mode is autonomous: the human's choice
of default (WD-0108), written as `Agent (inferred)` in Phase 6 step 8.
A stored `Autonomous mode: off` row still wins: the human turned it off on
purpose. Ask once per story; later skills read the row and do not re-ask. The story file may not
exist yet, so keep the answer and write it in Phase 6 step 8.

### Phase 1: Extract from Jira (skip if a `.md` path was given — use Phase 1-alt instead)

1. Fetch the story: title, description, AC, subtasks, linked issues, blockers.
2. If it belongs to an epic, read the epic — objective, scope, sibling stories.
3. Collect any Confluence links attached to the story or epic.
4. Read the last 2–3 comments only if they contain decisions or corrections.

### Phase 1-alt: Extract from a local `.md` file (replaces Phase 1 when a file path was given)

1. Read the file in full.
2. Extract, best-effort, from its structure: title (first heading, else filename), description, acceptance criteria (look for headings or checkboxes like "AC" or "Acceptance Criteria," including non-English equivalents).
3. If the file doesn't cleanly separate description from ACs, treat the whole content as description and ask the human to point out the ACs — never invent ACs the file doesn't state.
4. Story ID = filename without extension (`PROJ-1234.md` → `PROJ-1234`, `checkout-refactor.md` → `checkout-refactor`). If the filename is generic (`notes.md`, `story.md`), ask for a story ID.
5. Status exists even without Jira: use whatever the file states explicitly, otherwise initialize as `Not Started` and keep it synced with the Progress section as ACs close.
6. Skip epic lookup unless the file names one that resolves in Jira.
7. Follow Phase 2 for any explicit Confluence links the file contains.

### Open the run's cost (once the STORY-ID is known)

Record this run's start: `references/run-cost.md` (at the plugin root), with
`--stage init --start`. It comes here, after Phase 0 and Phase 1 / 1-alt, rather
than as the very first step: the STORY-ID is only known once the story is read,
and a first `init` in a project must not create `.workflow-dev/context/.usage/`
before Phase 0 has settled whether `.workflow-dev/` is gitignored.

### Phase 2: Extract from Confluence (only if links exist)

1. Read the linked TDD — pull the relevant sections, not the whole document.
2. Read linked ADRs — constraints and decisions.
3. Read API contracts if referenced.
4. Never search Confluence speculatively; follow only explicit links.

### Phase 3: Verify repo state

1. Confirm you're in a git repository — if not, ask where the repo lives and suggest opening the session there.
2. Confirm it's the right repository for this story.
3. Run `git fetch` and verify the branch base is current.
4. Check for uncommitted changes and warn if the tree is dirty.
5. Identify or create the work branch.

### Phase 4: The agent-role bindings

Nothing to do here: Phase 0 checked the bindings with the rest of the
configuration, so the research in Phase 5 never runs on the default model by
accident. The `--status` answers and what each one means:
`references/workflow.md` Step 6.

### Phase 5: Repo-level context (REPO.md)

Check whether `.workflow-dev/context/REPO.md` already exists.

**If it exists:** read it, spot-check that the stack section still matches `package.json` (or equivalent), update anything stale, and skip straight to Phase 6 — a full repo audit isn't needed twice.

**If it doesn't exist,** run a full exploration:

1. Read the manifest/build config and extract the stack with exact versions.
2. Read the project structure (depth-3 tree).
3. Read root and module-level READMEs.
4. Read `docs/` if present.
5. Read configs: tsconfig, eslint, prettier, docker-compose, `.env.example`.
6. Read CI config — what blocks a merge, what runs, coverage thresholds.
7. Identify shared types, utilities, and error-handling patterns.
8. Identify schemas or migrations relevant to the repo.
9. Read test patterns: runner, style, fixtures, helpers.
10. Skim the last 10–20 commits.

Then draft Role, Good Practices, and Prohibitions (delegate to subagents under the `wd-architect` role for a genuinely complex stack — see `references/workflow.md`).

**REPO.md sections:**
1. What this is — system context, priorities, code tone
2. Stack — table with exact versions
3. Project structure — tree
4. Conventions — errors, dependencies, tests, naming, imports
5. Good practices — per technology
6. Prohibitions — security, performance, dangerous patterns, project-wide
7. Infrastructure / local dev
8. Key files — table
9. Integration sections as needed (Airtable, Datadog, etc.)

### Phase 6: Story-level context ([STORY-ID].md)

1. Create `.workflow-dev/context/[STORY-ID].md` from `references/template.md`.
2. Fill in story-specific findings.
3. Set section 3's Implementation Status heading exactly as the template has it — copy this literally, do not rephrase, restructure, or move the value to a separate line, since another workflow-dev hook matches this exact text:
   ```
   ### Implementation Status: In Progress
   ```
   Running `init` is itself the start of work. Never write "Not Started" here: a story that hasn't been init'd yet has no context file to write "Not Started" into in the first place, so by the time this file exists, work has begun. This is separate from section 1.1's `Status` field, which just mirrors whatever the source (Jira, or a local .md) reports — the two can disagree, and that's expected, not a bug.
4. Link to REPO.md at the top instead of duplicating repo-level facts.
5. Map exemplar files to the ACs they inform.
6. Mark anything unresolved with ⬜ and a note on what's missing.
7. The run's cost is **not** recorded here: Phase 7's questions and answers
   are part of this run, so the end checkpoint comes after them ("Close the
   run's cost", below).

8. **Write the run mode** resolved after Phase 0. Autonomous writes
   `| [date] | Autonomous mode: on | Human |` to Decisions (`Agent (inferred)`
   when it was the unattended default), per
   `references/autonomous-mode.md`; step by step writes no row, or `Autonomous mode: off`
   when it replaces an `on` row the human just overrode. When the human
   overrode a stored row, edit that row in place (new value, today's date);
   never append a second one, so Decisions holds exactly one
   `Autonomous mode:` row. Skip when the row already matches. Whatever the mode, and whether or
   not that row was written, also write each answer this run inferred so far
   as its own `Agent (inferred)` row: Phase 0's `gitignored`, alerts and
   tiering bindings when the run was unattended and they were set without the
   human, and, in
   autonomous mode, each REPO.md section saved without review in Phase 5 and
   the ECOSYSTEM hand-off. Write Phase 0's `Tiering: default model` answer here
   too, as the human's (`references/tiering-question.md`).
   Then, whether or not the row was rewritten: with the row `on`, start
   keeping the Mac awake right away, without asking; with an `on` row turned
   `off`, stop it (`references/autonomous-mode.md`, "Keeping the Mac awake").
   The co-authorship question is not asked here: Phase 0 asked it.

9. **Recommend a tier for the session's model** (WD-0050). The session's model
   is the orchestrator: it talks with the human, implements each task group, and
   resolves the decision points. Show this notice only when this run created the
   story file in step 1 — that makes it once per story. It is information, not a
   question: never ask, never wait, and record nothing. Autonomous mode shows it
   too.

   Pick the recommended tier:
   - **Intermediate** when `wd-architect`, `wd-judge`, and `wd-adversary` are
     each bound to a top-tier model **and** the story touches none of the
     top-tier criteria below. Read the binding with
     `"$PLUGIN_ROOT"/scripts/model-tiering-check.sh --role-models`
     (`role<TAB>state<TAB>model`); a role counts only when its state is `bound`.
     You judge each bound model's tier — the plugin never names one. The heavy
     reasoning (planning, validating) then runs in those roles.
   - **Top tier** when any of those three roles is not bound to a top-tier
     model, or when the story touches writes, concurrency, or a security
     surface — the criteria `../validate/references/rules.md` §11.0 ("Deciding
     whether to run this, and at what depth") uses to raise the adversarial
     depth. When both bullets could apply, this one wins.
   - **Never the fast tier**: it makes more subtle errors when it implements,
     and each one costs another `validate` round.

   **Map the tier to models yourself, at runtime.** A tier is a class, and it
   can hold more than one model: the top tier is the provider's flagship
   class **and every model above it**, not only the single most capable one —
   a newer model ranking above the flagship does not push the flagship out of
   the top tier. Infer which models fall in each tier from what you know of the
   models on offer — this file never lists them, since the list changes with
   every release. When you are unsure whether a model is top tier, count it in.

   Skip the notice when the session's model is one of the models you inferred
   for the recommended tier. A session above it still sees the notice: the
   intermediate tier is where the saving is. Otherwise write at most 3 lines,
   per `references/user-language.md`: name the model this session runs on, name
   the recommended tier and the models you inferred for it, and say the human
   can switch the session's model with the harness's model-switching
   capability — name the capability, not a command
   (`references/harness-tools.md`).

### Phase 7: Ask the human

1. Collect every ⬜ across both files.
2. Settle each one from the evidence first, and record each answer with its
   evidence (`references/inference-first.md` at the plugin root). Keep as a
   question only what that file calls not inferable.
3. Turn those into specific questions grounded in what's actually missing — not a generic checklist.
4. Present them and update the context files with the answers, rewriting each `Open question:` row with its answer and `Human` as who decided.

In autonomous mode, this phase is the pre-autonomous checkpoint: follow
`references/autonomous-mode.md` (at the plugin root), "The pre-autonomous
checkpoint", instead of the steps above.

This phase asks no configuration question: Phase 0 settled all of them before
any work started.

### Close the run's cost

The last step of `init`, once the story file holds the human's answers (or the
inferred ones): record the run's end and show its line, per
`references/run-cost.md` (`--stage init`). The ledger outlives the session that
produced it.

## After init

Report back:
- Where the context files live (`.workflow-dev/context/`)
- What REPO.md covers, if it was newly created
- What the story file covers
- What's still open
- Suggest running `/workflow-dev:plan` next if the story is non-trivial, or ask what to do first if it's simple enough to skip planning

In autonomous mode, don't suggest and don't ask: run `/workflow-dev:plan` in
the same turn (`references/autonomous-mode.md`, "Chaining"). The report above
goes into the end-of-run report instead. The one exception: when the
pre-autonomous checkpoint stopped the story because nobody could answer an open
question, do not run `plan`. Stop there and report the open questions, as
`references/inference-first.md`, "A doubt you cannot infer", says.

## Principles

- The human is the architect. Don't propose an implementation plan here.
- Extract substance, not summaries — an AC specifying "retry 3 times with exponential backoff: 1s, 4s, 16s" keeps every one of those numbers.
- Exemplar files map to specific ACs; different ACs often need different reference patterns.
- Confluence documents intent and rationale; the code is the current state of truth. Never take a doc's word over the repo's.
- Both context files are living documents, updated as work progresses.
- REPO.md accretes — each story may surface new facts about the repo; extend it, never regenerate it from scratch.
- Story files are disposable — once merged, a story's context file can be archived or deleted. REPO.md persists.

## ECOSYSTEM SECTION

Full contract and how-to: see `../../ECOSYSTEM.md`.

Rules:
1. If the story source is a local `.md` file whose path matches
   `local-backlog/<CODE>-*.md` (`<CODE>` is only the `<PREFIX>-XXXX` part
   of the filename, e.g. `LB-0018`, not the whole slug), and
   `local-backlog/.backlog-config.json` exists at the repo root, invoke
   `/local-backlog:update-status <CODE> "In Progress"` after Phase 0 has
   settled the configuration and before any of Phase 1-alt's extraction
   steps run. In autonomous mode, pre-answer the
   invocation (`ECOSYSTEM.md`, "Pre-answered invocations"): Planner board:
   yes; note: a one-line note inferred from the transition. With no
   autonomous mode, pass no answers. If the marker file doesn't exist,
   skip.
