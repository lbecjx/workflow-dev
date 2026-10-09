---
name: manual-qa
description: Verifies a story's Acceptance Criteria by exercising the running app through whatever browser/device tooling the agent has (web via Playwright MCP/CLI or Claude-in-Chrome; iOS/Android via Maestro/Appium/adb). Runs on validate's PASS path when the story's manual-QA decision is "Yes". Use when the human says "manual QA", "verify in the browser/device", or wants the UI actually checked — not just read.
---

<!--
workflow-dev — a persistent-context development workflow for Claude Code
Copyright (C) 2026  lbecjx

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version. See LICENSE for the full text.
-->

# Manual QA

Exercises a story's **Acceptance Criteria in a real running app** — a browser
for web, a simulator/emulator/device for native iOS/Android — the way a human
QA would, and reports a per-AC verdict with evidence.

`/workflow-dev:validate` runs this on its PASS path when the story's one-time
manual-QA decision is "Yes" (that decision is made once, in
`../plan/SKILL.md` Step 5, and never re-asked here). The human can also invoke
it directly.

**Read `references/tool-mapping.md` and `references/platform-detection.md`
before executing** — together they define how a detected platform maps to the
tools actually available.

**Text shown to the user follows `references/user-language.md` (at the plugin root, not this skill's own `references/`)** — its language, wording, and length.

## When to use

- On `/workflow-dev:validate`'s PASS path, when the story's stored manual-QA
  decision is "Yes"
- Any time the human says "manual QA", "verify in the browser/device", or asks
  whether the UI actually works

## What this does

- Drives the app through whichever browser/device tooling the agent has
  configured (capability-based — see `references/tool-mapping.md`).
- Checks each Acceptance Criterion against the **running** app, not the diff.
- Collects evidence per AC: accessibility snapshot / view hierarchy, console
  or device logs, network (web), and/or screenshot.
- Returns a verdict per AC so the caller can proceed.

## What this does not do

- **Doesn't write, save, or keep E2E tests/Flows.** This is in-session
  verification; turning a working pass into a durable test is a separate,
  possible-future concern, not this skill's job.
- Doesn't fix code. It reports; the human decides.
- Doesn't decide *whether* to run — that was decided once, at plan time, and
  must not be re-asked here.
- **Never assumes a check passed.** No capable tool for a platform means
  `NOT VERIFIED`, never a soft pass (see Step 3).

## Execution

### Step 1: Gather the targets

When `validate` invoked this skill (its PASS path), this run is part of the
`validate` run and records no cost. Run on its own, record this run's start
once the story is known (`references/run-cost.md` at the plugin root,
`--stage manual-qa --start`) and its end at Step 6.

1. Read the active story's Acceptance Criteria from
   `.workflow-dev/context/[STORY-ID].md` (the caller may name the story;
   otherwise use the active one). If there is no story context, ask which ACs
   to verify — **never invent checks** the story doesn't state.
2. Get the changed files (`git diff --name-only`) to know which ACs the change
   plausibly touches.

### Step 2: Detect platform(s)

Apply `references/platform-detection.md` to the repo to determine which
platform(s) apply — web, iOS, Android, or several at once (Flutter/React
Native/KMP). The changed files narrow which platform(s) this run should cover.

### Step 3: Detect capability — and the NOT VERIFIED gate

For each detected platform, find which of the agent's tools can drive it
(`references/tool-mapping.md`). Then:

- **No capable tool for a detected platform → report `NOT VERIFIED` for that
  platform and stop on it.** State exactly what was looked for and what is
  missing (a configured MCP server, a CLI on `PATH`, a built app, …). Do not
  substitute a by-hand screenshot, do not infer, and do not report success.
- Capability present → continue.

### Step 4: Make the app reachable

- **Web:** identify or start the dev server; establish the base URL (usually
  `localhost`). If it can't be determined, ask via the ask-question tool.
- **iOS/Android:** build, install, and launch the app (bundle/app id). Ask if
  unknown.
- Ask (ask-question tool) before any login, credential entry, paid, or
  destructive action.

### Step 5: Verify the ACs — one at a time, with evidence

For each AC:

1. Perform the interaction (navigate/launch, tap, type, …).
2. Assert the expected outcome.
3. Capture evidence: accessibility snapshot / view hierarchy, console or
   device logs, network (web), and/or a screenshot.
4. Record the verdict.

### Step 6: Report — then hand control back

Present a table:

```
Manual QA — [STORY-ID]

| AC # | What was done            | Evidence                | Verdict |
|------|--------------------------|-------------------------|---------|
| 1    | launched app, tapped X   | snapshot + screenshot   | PASS    |
| 2    | ...                      | ...                     | FAIL    |
```

Verdicts: `PASS` / `FAIL` / `BLOCKED` / `NOT VERIFIED`. Every verdict names its
evidence — evidence or it didn't happen.

Then **return control to the caller's next step** (on validate's PASS path,
that is validate's closing — the offer to draft the commit message/PR). Do not
commit, and do not offer the commit yourself; `validate` owns that. Run on its
own, record this run's end and show its line as the last step
(`references/run-cost.md`, `--stage manual-qa`).

## Principles

- **Human-in-the-loop.** Stop and ask (ask-question tool) at any decision
  point: unknown URL/bundle id, ambiguous platform or scope, login, anything
  destructive. Never infer — read the code or ask.
- **Verify only what's stated.** The story's ACs (plus obvious regressions of
  the changed surface) — no invented checks.
- **Agent-agnostic, by capability.** Never hardcode a single tool name; map the
  capability to whatever the agent has (`references/harness-tools.md` at the
  plugin root).
- **Cheap by default is validate's job, not this skill's.** This pass is the
  expensive one on purpose; that's why it is opt-in and decided once, up front.
