<!--
workflow-dev — a persistent-context development workflow for Claude Code
Copyright (C) 2026  lbecjx

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version. See LICENSE for the full text.
-->

# Validation Rules — Universal Dimensions

These rules are language- and stack-agnostic; they apply to any codebase. Each dimension is checked independently by a sub-agent that receives the list of changed files and reads them directly.

---

## Part 1: Scope Compliance

- [ ] Only files relevant to the current task were modified
- [ ] No unrelated changes mixed in (refactors, style fixes, unrelated features)
- [ ] If a story/task context exists (.workflow-dev/context/*.md), changes align with stated scope

**Verdict:** WARN if unrelated files touched. Never blocks.

---

## Part 2: Security

### 2.1 Injection & Input Handling

- [ ] No string concatenation/interpolation for queries (SQL, NoSQL, GraphQL, shell commands)
- [ ] No unsanitized user input in URLs, paths, headers, or templates
- [ ] No eval(), Function(), or dynamic code execution with external input
- [ ] No deserialization of untrusted data without validation

### 2.2 Secrets & Credentials

- [ ] No API keys, tokens, passwords, or connection strings in code
- [ ] No hardcoded credentials (even "temporary" or "test" ones in non-test files)
- [ ] No internal URLs, IPs, or infrastructure details exposed in client-facing code
- [ ] Environment variables or secret managers used for all sensitive values

### 2.3 Data Exposure

- [ ] No raw upstream error bodies returned to clients (wrap in structured errors)
- [ ] No PII logged or exposed in error messages
- [ ] No overly permissive CORS, auth bypass, or disabled security checks
- [ ] Response bodies don't leak internal structure (field names, stack traces, IDs)

**Verdict:** FAIL if any 2.x check fails. Security is always blocking.

---

## Part 3: Data Shape Integrity

- [ ] New types/enums/variants handled exhaustively in all switch/case/match statements
- [ ] Cache keys, dedup keys, unique identifiers remain unique with new data shapes
- [ ] No silent type coercion that could produce incorrect comparisons
- [ ] Default/fallback values are distinguishable from valid data (not empty string for "missing")

**Verdict:** FAIL if exhaustiveness broken (will crash at runtime). WARN otherwise.

---

## Part 4: Code Quality

### 4.1 Smells

- [ ] No duplicated logic (same block in 3+ places without extraction)
- [ ] Functions focused and reasonably sized (guideline: <50 lines)
- [ ] No excessive nesting (guideline: max 4 levels)
- [ ] No magic numbers/strings without context (named constants preferred)
- [ ] No dead code (commented-out blocks, unreachable branches, unused imports)
- [ ] No overly complex functions (too many responsibilities, too many params)

### 4.2 Conventions

- [ ] Follows existing project naming conventions (file names, variables, types)
- [ ] Follows existing project patterns (error handling, logging, dependency injection)
- [ ] Imports follow project style (relative vs absolute, ordering)
- [ ] Error handling appropriate — not excessive (defensive against impossible cases) and not missing (ignoring failures)

### 4.3 Type Safety (typed languages)

- [ ] No type escape hatches (any, as, !, unsafe) without clear justification
- [ ] Null/nil/undefined handled explicitly at boundaries
- [ ] Generic types used correctly (not over-abstracted, not under-constrained)

**Verdict:** WARN for smells and conventions. Never blocks alone.

---

## Part 5: Testing

### 5.1 Coverage of Changes

- [ ] New functions/methods have at least one test exercising the happy path
- [ ] New error paths have at least one test proving the error is handled
- [ ] Behavioral changes to existing code have tests updated or added
- [ ] Edge cases considered: null/empty input, boundary values, concurrent access

### 5.2 Test Quality

- [ ] Each test has at least one meaningful assertion (not just "doesn't throw")
- [ ] Tests verify outcomes, not implementation details (not just "mock was called")
- [ ] Tests are isolated — no dependency on execution order or shared mutable state
- [ ] Test names describe the scenario being verified
- [ ] No copy-paste from production logic into expected values (independently computed)

### 5.3 What NOT to require

- Do NOT require tests for trivial getters/setters, type definitions, or pure config
- Do NOT require 100% coverage — focus on behavior that matters
- Do NOT flag missing tests for code that's already tested at a higher level (integration)

**Verdict:** WARN if new behavior lacks tests. FAIL only if existing tests now fail.

---

## Part 6: Verification Commands

Run whatever the project provides — discovered per SKILL.md's Step 1 (a stack-survey sub-agent enumerates conventional tools for whatever language/framework the repo actually uses, a confirmation sub-agent checks which of those exist here plus a generic "test"/"spec" catch-all), not a fixed list of manifest files. Map to these categories:

| Category | What it proves | Blocking? |
|----------|---------------|-----------|
| Build | Code compiles/bundles without errors | FAIL |
| Type check | Static types are consistent | FAIL |
| Lint | Style and lint rules pass | WARN |
| Format | Code is formatted per project standard | WARN |
| Tests | All tests pass, no regressions | FAIL |

**If a command is not available** (can't be discovered), note it as "skipped" — don't fail.

**Pre-existing failures:** If a command fails on code NOT in the changed files, note it but don't block. Only NEW failures in changed code block.

---

## Part 7: CI/CD Anticipation

Think about what CI will check after push:

- [ ] No new lint warnings that CI treats as errors
- [ ] No decrease in coverage on changed files (if CI enforces)
- [ ] Commit message follows project convention (if enforced)
- [ ] No files that should be gitignored (build artifacts, .env, node_modules, etc.)

**Verdict:** WARN. Anticipation is advisory — CI is the source of truth.

---

## Part 8: Architecture

- [ ] Changes respect existing layer boundaries (don't mix concerns)
- [ ] Dependencies flow in the correct direction (no circular, no reaching up layers)
- [ ] New abstractions are justified (not premature, not over-engineered)
- [ ] No tight coupling introduced (changes in file A shouldn't force changes in file B without reason)

**Verdict:** WARN. Architecture is judgment, not binary.

---

## Part 9: Performance

- [ ] No queries/API calls inside loops without batching consideration
- [ ] No unbounded growth patterns (arrays/maps that grow without limits)
- [ ] No blocking operations in hot paths (sync I/O, heavy computation in request handlers)
- [ ] Resource cleanup in place (connections closed, listeners removed, timers cleared)

**Verdict:** WARN unless it's clearly a production incident waiting to happen (e.g., N+1 in a loop processing thousands of items) → FAIL.

---

## Part 10: Context Hygiene

Applies only when `.workflow-dev/config.json` exists in the project.

- [ ] Read `gitignored` from `.workflow-dev/config.json`.
- [ ] If `true`: `.workflow-dev/` must actually be excluded via `.gitignore`, and `git status` must show nothing under it as staged or tracked.
- [ ] If `false`: `.workflow-dev/` must actually be tracked — not silently excluded by an unrelated `.gitignore` pattern (e.g. a broad `*.local` or `context/` rule shadowing it).

**Verdict:** FAIL if the declared preference and the actual git state disagree — this is silent, easy-to-miss drift (someone hand-edits `.gitignore`, or a broad ignore rule shadows the folder) that a human won't notice until content quietly stops syncing.

---

## Part 11: Adversarial Correctness Review

Every other dimension checks compliance against a checklist. This one has a
different mandate: assume the change has a bug, and try to prove it — rather
than confirm it looks fine. A single pass done by whoever wrote (or reasoned
through) the change tends to re-confirm the same assumptions that produced it;
this dimension exists specifically to not share that context.

**This is also, by a wide margin, the most expensive dimension** — the other
six each run one bounded check (a command, a diff read, a config check) in
under two minutes combined; the hunt→verify pair below routinely takes longer
than that on its own, because both agents do open-ended exploration and often
empirical testing (spinning up a server, firing real concurrent requests,
corrupting a file on purpose), not a fixed scan. Never spend that cost
reflexively — see §11.0 before spawning anything.

### 11.0 Deciding whether to run this, and at what depth

The other six dimensions always run — they're cheap enough that skipping them
saves nothing worth the risk. This one is different: it's expensive enough
that running the full version by default, on every change regardless of what
the change actually is, wastes real time and tokens for no real return on a
change with nothing much to break. There are three levels, not two:

- **SKIP** — nothing spawned. For diffs with nothing worth adversarially
  testing: docs/comments only, a pure rename or config-value change with no
  new logic, styling/presentation-only code, or anything else where a wrong
  result would be immediately obvious on the next normal use.
- **LITE** — both hunt (§11.1) and verify (§11.2) run, both held to
  *static-analysis depth*: read the code, trace it by hand — this is what
  actually saves the time and tokens, not skipping verify. Neither agent runs
  anything (no server spun up, no real requests fired, no script executed
  against a scratch file); a hunt-alone cut would still leave the truly
  expensive part (live, empirical testing) in place, so LITE restricts depth
  on *both* agents instead. A finding that both agents can trace all the way
  through on paper still reaches CONFIRMED and still blocks (see Verdict);
  only a claim that genuinely needs live execution to settle — real
  concurrency timing, mostly — comes back NEEDS TESTING instead, a WARN. Right
  for a diff with real new logic worth a fresh pair of eyes, but not touching
  the highest-risk categories below — a new pure function with some edge
  cases, a UI component with real conditional logic *that isn't auth-related*
  (a date picker, a filter panel, a form for non-sensitive data), a data
  transform.
- **FULL** — hunt and verify both at full depth (empirical testing expected
  wherever a claim can be checked that way, per §11.1/§11.2), as originally
  designed. Right for a diff that touches: a write path (anything that
  persists, deletes, or mutates state — a database, a file, `localStorage`/
  `sessionStorage`/a cookie, an in-memory store), concurrency (anything that
  can run more than once at the same time — request handlers, background
  jobs, shared files, or a UI component that can be triggered twice before
  its first call resolves), security-relevant surface (auth in any form —
  a login/signup/password-reset component is security-relevant even if the
  diff is pure frontend calling an already-existing endpoint; also token/
  session storage or transmission, input trusted from outside the process,
  anything newly network- or filesystem-reachable), or a genuinely new
  invariant the rest of the codebase now has to hold (a new closed set, a
  new "exactly one of" guarantee, a new atomicity claim). These are exactly
  the cases where a claim needing live execution to be fully sure —
  something LITE can only mark NEEDS TESTING — would actually matter enough
  to pay for resolving it outright, so the extra depth earns its cost.
  **None of this is backend-specific** — "write path," "concurrency," and
  "security-relevant surface" apply the same way to frontend code (state
  writes, double-submit races, auth UI) as to a server.

**SKIP is the only depth decided directly, without asking** — it's for a
narrow case: genuinely zero logic (docs, a pure rename, a config-value
change), where there's nothing to adversarially test either way, so asking
would just be friction with no real choice behind it. For anything else,
picking a depth is a real judgment call — LITE and FULL trade off cost
against how settled a finding can get — and that call belongs to the human,
not the model. LITE is the default *suggestion* whenever there's real logic
but nothing hits the FULL criteria above; FULL is the default suggestion once
it does. Either way, present the suggestion with a one-line reason and ask
which depth to actually run.

**Mixed diff:** judge by the highest-risk file touched, not the average — one
write-path file in an otherwise-docs change still calls for suggesting FULL.

Before spawning anything, look at the scope from Step 2 and decide SKIP
directly — the one case that never asks, since there's nothing to test
either way. For anything else, present the suggested depth with its reason
and ask the human to pick LITE or FULL:

```
Adversarial correctness (Part 11): SKIP
This diff is a folder rename across skill docs plus one path change in a
shell script; no new logic to break.
```

```
Adversarial correctness (Part 11) — recommend: LITE
This diff adds a pure formatting function with several edge cases; no
write/concurrency/security surface. Run at LITE, or escalate to FULL?
```

```
Adversarial correctness (Part 11) — recommend: FULL
This diff adds a write endpoint with concurrent access and a rollback path —
exactly the shape this dimension exists for. Downgrade to LITE instead?
```

```
Adversarial correctness (Part 11) — recommend: FULL
This diff is a pure-frontend login form — auth is security-relevant surface
regardless of layer, even calling an endpoint that already exists.
Downgrade to LITE instead?
```

If the human doesn't answer (asynchronous review, CI, batch mode): default
to LITE regardless of which depth was suggested — never silently escalate to
FULL just because that's what was recommended and nobody was there to
confirm it. A human choosing a different depth than what was suggested or
decided — up, down, or to skip — is always honored; SKIP is a stated
decision, not a gate the human can't override, and LITE/FULL are
recommendations, not requirements.

Both depths run two independent sub-agents (hunt then verify), never with any
memory of each other or of how the change was designed — LITE and FULL differ
in what those two agents are allowed to do (§11.1, §11.2), not in how many of
them run:

### 11.1 Hunt

Given only: the list of changed files, their current full contents, and the
acceptance criteria being validated against — nothing about the plan, the
design discussion, or why the approach was chosen. Inheriting that narrative
means inheriting its blind spots.

Instructions to give this agent, close to verbatim:
- Do not report "this looks correct." Your only job is to find the specific
  input, sequence of calls, or state that breaks this.
- Prioritize, in this order: concurrent/racing writes to shared state,
  boundary values (empty, null, zero, negative, max-length, unicode,
  duplicate), an error path that's assumed handled but never actually
  exercised, a caller passing data the callee doesn't expect, and any spot
  where two pieces of code each assume the other one validates something.
- A finding without a concrete trigger doesn't count. For each one, state:
  the exact file and line, the exact input/sequence that reaches it, and the
  exact wrong behavior that results.
- Ignore: pre-existing issues outside the changed lines, anything a linter or
  type checker would already catch, and pedantic style points — this
  dimension hunts for behavior that's actually wrong, not taste.

**Depth is set here, not just by whether verify runs afterward** — running
real code (spinning up a server, firing actual concurrent requests,
corrupting a file on disk and re-running the script against it) is what makes
a FULL-depth hunt take minutes and burn six figures of tokens; a LITE-depth
hunt skips all of that and stays on the page:

- **LITE:** static analysis only — read the code and trace it by hand. Cite
  the exact line and reason through what the input/sequence you're describing
  would do, but never actually run anything: no starting a server, no real
  HTTP/socket calls, no executing the script against a scratch file, no
  process spawned to "just check." A claim traced correctly on paper still
  counts as a finding here — it just isn't empirically confirmed, which is
  exactly what makes LITE cheap. §11.2's verify pass still runs at LITE — at
  the same static depth — so a LITE finding isn't unverified in the sense of
  "nobody checked it twice," only in the sense of "nobody actually ran it."
- **FULL:** the same mandate, but empirical testing is not just allowed, it's
  expected wherever a claim can be checked that way — a hunt agent that could
  have spun up the actual server and fired the actual request, but instead
  only reasoned about what "should" happen, is doing LITE-depth work under a
  FULL label. Reserve this depth for exactly the diffs that earn it (§11.0).

Tell the agent explicitly which depth it's running at — this isn't something
it infers from context.

### 11.2 Verify

Runs at both depths — LITE gets a real verify pass too, not none; it's just
verify held to the same no-execution rule as a LITE hunt (see below). A
second, independent agent — given the hunt's raw findings, the same changed
files, and the same acceptance criteria hunt received, but nothing about how
the hunt agent reasoned its way there.

For each claimed finding, re-derive it from the actual code without trusting
the hunt agent's framing: does the claimed trigger really reach the claimed
line, with the claimed effect — and is that effect actually inconsistent with
the ACs, not just surprising? A hunt agent can misread what the spec actually
requires; tracing the trigger correctly doesn't make the "bug" real if the
behavior it found is what the ACs call for.

Same depth rule as hunt (§11.1), told explicitly, not inferred:
- **LITE:** static only — re-derive by reading, never by running. Most false
  positives (the trigger doesn't actually reach that line, the case is
  already handled elsewhere, the behavior matches what the ACs actually
  require) are just as catchable by careful reading as by execution — that's
  what still makes a LITE verify pass worth running instead of skipping it.
  What static reading *can't* fully settle — genuine timing/concurrency
  behavior, anything whose outcome depends on real execution order — gets the
  **NEEDS TESTING** outcome below instead of CONFIRMED.
- **FULL:** empirical — actually reproduce the claim (run the server, fire the
  request, corrupt the file, whatever the claim calls for) rather than only
  reasoning about it.

Three outcomes per finding:
- **CONFIRMED** — independently traced (LITE) or reproduced (FULL) the exact
  failure, with enough certainty at the depth actually run that this isn't a
  judgment call, and confirmed the resulting behavior actually violates a
  requirement (an AC, or an unambiguous correctness expectation if no AC
  covers it); it's real.
- **NEEDS TESTING** — the trigger and reasoning check out on inspection, but
  settling it for certain would need something this depth doesn't do (typically:
  live execution, at LITE depth, for a genuinely timing/order-dependent claim
  that reading alone can't fully resolve — rare at FULL depth, where
  execution is already on the table, but not impossible for something that's
  hard to reproduce reliably even running it, like a narrow race window).
- **REJECTED** — couldn't reproduce, the trigger doesn't actually reach the
  code, the case is already handled elsewhere, or the behavior matches what
  the ACs actually require.

Only CONFIRMED and NEEDS TESTING findings are reported upward. A finding that
stays REJECTED never reaches the human — this is what keeps the dimension
high-signal instead of a pile of speculative maybes.

**Verdict:**
- **SKIP** — decided directly per §11.0 for a diff with no real logic
  (Findings column reads `— (skipped, low risk)`), or it ran anyway (LITE or
  FULL) and there was nothing to adversarially test (`— (nothing to test)`).
- **CONFIRMED → FAIL**, at either depth. A verify pass that reached CONFIRMED
  — whether by careful static tracing (LITE) or live reproduction (FULL) — is
  reporting a real bug, not a matter of judgment. Depth changes how much a
  finding *can* reach CONFIRMED (some claims are only fully settleable by
  running them), not what CONFIRMED itself means once reached.
- **NEEDS TESTING → WARN**, at either depth. Verify traced the reasoning and it
  holds up, but couldn't rule out every alternative without doing something
  this depth doesn't do — most often live execution at LITE depth, for a
  timing/order-dependent claim reading alone can't fully settle. A judgment
  call for the human, not a verified bug — the human reads it and decides.

---

## Part 12: Git History Disclosure & Tone

Every other dimension judges code. This one judges the *record* — the
commit message and, when one exists, the PR title/description — because
that text outlives the diff it describes. Once committed (and especially
once a PR is opened) it's effectively permanent and effectively public,
even in a private repo: every future contributor, every `git log`, every
notification and search index sees it as-is. Nothing here is about the
code being wrong; it's about the *story told around the code* being one
that shouldn't be told in public, in this tone, at all.

**Scope:** the drafted commit message and/or PR title/description, **and**
any new or edited entries in `CHANGELOG.md` (or equivalent) that appear in
the changed-file list from Step 2 — not the diff of the actual code. A
changelog entry is exactly as permanent and public as a commit message
(often more visible — it's the one artifact meant to be read end-to-end by
someone who wasn't there), so 12.1–12.4 apply to it the same way; it isn't
a lower-scrutiny cousin of the commit message just because it's committed
as a regular file edit instead of passed via `-m`.

If none of these exist yet — no drafted message and `CHANGELOG.md` isn't
in the changed-file list — report `SKIP — (nothing drafted yet)`; it
re-runs once a draft exists or `CHANGELOG.md` is touched (see
validate/SKILL.md and implement/SKILL.md for exactly when that is).

### 12.1 Formality

- [ ] Reads like professional technical writing: what changed and why, in
      neutral third-person or imperative mood — not a chat message, not a
      diary entry
- [ ] No first-person narration of the *process* of writing the code
      ("I noticed", "I realized", "oops", "mi bad")
- [ ] No casual filler, apologies, or hedging ("sorry about this", "not
      sure if this is right but")

### 12.2 No Security Disclosure

A commit/PR that narrates a security incident turns the git history
itself into a timestamped, attributed index of what to attack and when it
was fixed — worse than saying nothing.

- [ ] Does not describe a leaked secret, credential, or sensitive file as
      having been leaked/exposed — states the resulting change only
      ("Add `.env` to `.gitignore`", never "Remove the API key that leaked
      in commit abc123")
- [ ] Does not narrate a history rewrite as cleanup of a mistake — e.g.
      "este commit limpia del historial algunos documentos que no
      debieron subirse al repo, por lo que se corrió un force push" is
      exactly what this blocks. If history had to be rewritten, the
      message describes the current state, not the incident behind it
- [ ] Does not name a vulnerability class, exploit, or attack vector that
      was present in a previous version, even to say it's now fixed — a
      fix commit states what the code now does, not what it used to be
      vulnerable to
- [ ] Does not reference internal security tooling, scan results,
      incident IDs, or timelines

### 12.3 No Personal/Internal-Behavior Exposure

- [ ] Does not explain a change via the developer's or team's private
      reasoning, preferences, or internal discussion — e.g. "metiendo
      .workflow-dev al gitignore porque no queremos que la información
      del plugin de workflow dev se suba al repo" exposes internal intent
      that doesn't belong in the public record. The *what* belongs in the
      message; the internal *why* usually doesn't
- [ ] Does not reveal internal tooling, workflows, or plugins not meant
      for an external audience, framed as a reason for the change — if
      something needs to be gitignored, state that fact plainly
      ("Add `.workflow-dev/` to `.gitignore`") instead of narrating the
      motive behind it
- [ ] Does not mention specific people, blame, or internal disagreement

### 12.4 Length & Conciseness

A long commit message or PR description is usually long because it's
narrating the process (what was tried, what went wrong, why a decision was
made) instead of stating the outcome — and process narration is exactly
what 12.1–12.3 already flag for other reasons. Length is a useful signal
on its own even when nothing else trips: it means the draft needs
summarizing, not just softening in tone.

- [ ] Commit message: a one-line summary, optionally followed by **at most
      two short paragraphs** of body — not a changelog, not a step-by-step
      of the implementation
- [ ] PR description: **at most a couple of short paragraphs** (a brief
      summary plus, if genuinely useful, a short bulleted list) — not a
      full narrative of the work session, not one bullet per commit
- [ ] If the underlying change needs more explanation than that to be
      understood, that explanation belongs in code comments, the PR's
      inline diff comments, or linked documentation — not in the message
      itself
- [ ] Summarize, don't transcribe: state the net effect of the change, not
      a chronological account of how it was reached

**Verdict:** WARN — rewrite to fit before marking reviewed (§12.5); length
alone is never FAIL the way 12.2/12.3 always are, but a message failing
length nearly always also carries some of what 12.1–12.3 flag, so check
those again after trimming it.

### 12.5 Rewriting when this fails

Don't just reject and stop — rewrite toward the plain, factual version and
re-check: state what changed, present/imperative tense, with no narrative
about *why* it had to change if that narrative is the sensitive part. If
the underlying technical reason isn't itself sensitive, keep it; only the
disclosure and the tone are being flagged, not documentation in general.

Once a rewritten message/description passes, mark it reviewed so the
commit-time hook recognizes it and doesn't ask again:

```bash
printf '%s' "<final message text>" | "$CLAUDE_PLUGIN_ROOT"/scripts/git-message-mark-reviewed.sh
```

The marker is keyed by exact content hash — editing the text by even one
character after marking it invalidates the marker, same as the diff-hash
marker in `pre-commit-validate-check.sh` (Part 10's mechanism, reused
here for the same reason: no marker match means "not confirmed as
reviewed," not "assume it's fine").

**Verdict:** FAIL if any 12.2 (security disclosure) **or** 12.3
(personal/internal-behavior exposure) check fails — the two are equally
blocking, same tier as Part 2, and neither needs the other to also trip
for it to matter: a 12.3 violation with no security content in it still
FAILs on its own, exactly like a 12.2 violation with no personal reasoning
in it does. WARN for 12.1 (formality) and 12.4 (length) alone — these are
quality-of-writing issues, not disclosure.

---

## Severity Guide

| Severity | Meaning | Blocks commit? |
|----------|---------|----------------|
| FAIL | Will break production, expose vulnerabilities, or crash at runtime | Yes |
| WARN | Degrades quality, maintainability, or performance. Might bite later. | No (human decides) |
| SKIP | Dimension couldn't be checked (missing command, no test runner found) | No |

**Overall verdict:**
- Any FAIL → Overall FAIL
- Only WARN/PASS/SKIP → Overall PASS (with warnings listed)
