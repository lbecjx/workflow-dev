---
name: validate
description: Runs a multi-dimensional quality gate on uncommitted changes before commit. Use when the user says "validate", "check quality", or before suggesting a commit.
---

<!--
workflow-dev — a persistent-context development workflow for Claude Code
Copyright (C) 2026  lbecjx

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version. See LICENSE for the full text.
-->

# Validate

Runs a structured quality gate over the current uncommitted changes, using parallel sub-agents to check independent dimensions, and reports pass/fail per dimension with actionable findings.

**Read `references/rules.md` for the full set of validation dimensions before executing.**

## When to use

- Before committing (the user says "validate," "are we ready?")
- After finishing a chunk of implementation work
- Whenever the human wants confidence the changes are solid

## What this does not do

- Doesn't commit or push
- Doesn't auto-fix issues — it reports them and leaves the call to the human
- Doesn't validate business logic **by default** — that's manual testing / AC
  verification. When the story's manual-QA decision is "Yes", Step 7 runs
  `../manual-qa/SKILL.md` against the running app; otherwise the gate stays
  static.
- Doesn't draft or review a commit message or PR title/description — that's
  `/workflow-dev:summarize-changes`. This skill's Git History Disclosure
  dimension (Part 12) only covers `CHANGELOG.md` entries that happen to be
  in the diff scope (see Step 3) — text that isn't part of this scope's
  diff at all doesn't belong to this skill.

## Execution

### Step 1: Discover project context

Determine the available verification commands. A fixed list of manifest files (`package.json` → npm scripts, `pyproject.toml` → pytest, and nothing else) misses any project that doesn't happen to match one of those exact shapes — a Python project using `pytest.ini`/`requirements-dev.txt` instead of `pyproject.toml`, a Ruby project, a monorepo with three stacks in different subfolders, a project whose test tool didn't exist when this list was last updated. This step is deliberately stack-agnostic instead: it reasons about what a project's own stack conventionally uses, rather than pattern-matching a short hardcoded list.

1. Check `.workflow-dev/context/REPO.md` for documented test/lint/typecheck/build commands. If found and still accurate (spot-check against what's actually in the repo), skip straight to Step 2.
2. Absent that, this is two sub-agents in sequence, not one — a survey and a confirmation search are different tasks (broad ecosystem knowledge vs. this specific repo's filesystem), and keeping them separate means the second agent's search list isn't limited to whatever the orchestrator happened to already know:
   - **Stack-survey sub-agent**: give it whatever manifest/config files actually exist at the repo root and in any obviously-separate sub-projects (a monorepo can have more than one stack) — `package.json`, `pyproject.toml`, `requirements*.txt`, `pytest.ini`, `setup.cfg`, `tox.ini`, `go.mod`, `Cargo.toml`, `Gemfile`, `composer.json`, `*.csproj`/`*.sln`, `build.gradle`/`pom.xml`, `mix.exs`, or whatever else is present — Python alone has enough legitimate config-file shapes (`pyproject.toml`, or a bare `requirements*.txt` with `pytest.ini`/`setup.cfg`/`tox.ini` and no `pyproject.toml` at all — both real, current setups) that no single one of them can be assumed to signal "this is/isn't a Python project" by itself. Ask it to identify every language/framework in use, then, for each one, list the realistic full set of conventional test, build, typecheck, lint, and format tools an experienced developer in that stack would recognize — not just the most common one (e.g. Python: pytest (+ pytest-cov, hypothesis), unittest, doctest, nose2, tox, nox, ruff, flake8, pylint, black, mypy, pyright; JS/TS: jest, vitest, mocha, ava, jasmine, playwright, cypress, eslint, prettier, tsc; Go: `go test`, `go vet`, golangci-lint, `gofmt`; Rust: `cargo test`/`clippy`/`fmt`; Ruby: rspec, minitest, rubocop; Java/Kotlin: Maven/Gradle `test`, checkstyle, spotbugs, ktlint; PHP: phpunit, pest, phpcs; .NET: `dotnet test`, StyleCop; Elixir: `mix test`, credo, dialyzer). **Its list is a union, not a replacement**: it must include at least the examples already named above for whatever stack it finds, plus anything else it knows about that ecosystem (including a stack not named here at all) — the examples in this file are a floor that doesn't depend on the agent's reasoning being complete that day, not a ceiling on what it's allowed to add. This agent doesn't need to find anything in the repo beyond the stack itself — its output is a candidate list, not a fixed list this file hardcodes standing alone (new tools appear faster than a skill doc gets updated, which is exactly why neither source should be trusted by itself).
   - **Confirmation sub-agent**: give it that candidate list and have it actually check the repo for each one — a config file (`pytest.ini`, `tox.ini`, `jest.config.js`, `.rspec`, `phpunit.xml`, …), a script entry (`package.json`'s `scripts`, a `Makefile` target, a CI workflow file), or a directory/naming convention (`tests/`, `test/`, `spec/`, `__tests__/`, `test_*.py`, `*_test.go`, `*.spec.ts`). Only a command actually found this way goes in the map — the survey names candidates, it doesn't assume any of them are present. **Independent of the candidate list, this same agent always also runs a generic catch-all**: search the repo for anything whose name contains "test" or "spec" that the stack-specific list might have missed — a custom `run-tests.sh`, an unconventionally-named `Makefile` target, a `tests/` folder with no config file the survey would recognize. If something like this turns up and it's not obviously one of the tools already found, report it and ask what it is rather than silently ignoring it — an unrecognized test setup is a gap in the survey's knowledge, not evidence the project has no tests.

Build a command map: `{ build: "...", typecheck: "...", lint: "...", format: "...", test: "..." }` — one entry per stack if more than one was found. Any command that can't be discovered is skipped, not failed — note it in the report, and say what was searched for so a human can tell "skipped, nothing found" apart from "skipped, didn't look."

For Part 11 (Adversarial Correctness), also read the Acceptance Criteria table from the active `.workflow-dev/context/[STORY-ID].md`, if one exists. If no active story context exists, proceed without ACs and note that in the report — don't block on it.

### Step 2: Determine scope

Two scopes, not one — which applies depends on why this is running:

- **Single-diff scope (default).** `git diff --name-only` (staged +
  unstaged) defines the validation scope. Only these files are judged —
  pre-existing issues elsewhere are out of scope, not failures. This is
  what a normal, one-off call uses — including a task group validated
  immediately under a story's "after every task group" mode, or an ad-hoc
  "validate this one now" override (see `implement/SKILL.md` Step 5).

- **Batched/story-end scope.** Triggered when `implement`'s Step 5 reaches
  the last task group of a story running in "once, at the end" mode, or
  when the human explicitly asks to validate/wrap up the whole story.
  Scope is `git diff --name-only <merge-base-with-the-story's-base-branch>...HEAD`
  **union** any currently staged/unstaged changes — the full accumulated
  diff since the story's branch forked off its base, not just the latest
  task group (use the branch's actual PR-target base — typically `main`;
  ask if genuinely ambiguous). Every dimension and rule below applies
  unchanged to this larger scope — §11.0's "judge by the highest-risk file
  touched" already handles a diff spanning many files, no new logic
  needed for that.

  **Known, accepted simplification:** this scope doesn't exclude a task
  group that was already individually validated via an ad-hoc override
  earlier in the story — it re-validates the whole branch diff regardless.
  Excluding it would need tracking validated-vs-deferred state at the
  per-commit or per-hunk level; not worth that complexity for marginal
  savings next to the actual win here (one pass instead of many).

### Step 3: Run validation dimensions

> **Gates for this step** — the moves that leave no artifact of their own, so
> a miss is easy to overlook. Do them, don't just read them:
> - **Gate depth:** decide the *set* first (below) and state it in the report —
>   a no-logic diff runs the reduced set, not the full one.
> - **Brief = content, not a command:** give each dimension the changed files'
>   contents and the diff **inline**; never a `git diff`/`read` for it to run —
>   a command is paid once per dimension (~10× the cache reads).
> - **Adversarial depth (Part 11):** real logic in the diff → suggest LITE or
>   FULL **with a one-line reason** and **ask the human to choose**; don't run
>   a depth silently. SKIP only when there's genuinely no logic. (Unattended →
>   §11.0's depth defaults, not a silent pick.) → `references/rules.md` §11.0

**Decide the gate's depth first — the set, not just the adversarial depth.**
This is §11.0's idea (spend where the risk is) applied to the whole dimension
list, and it is the **default**, not an opt-in:

- **Reduced set — no real logic in the diff** (docs/comments only, a pure
  rename, a config-value change, a version bump). Run only checks the
  orchestrator performs itself: the discovered commands, the `.workflow-dev/`
  ↔ `config.json` drift check, and a direct read of any in-scope `CHANGELOG.md`
  entry. The judgment dimensions (Code quality, Testing, Architecture) and
  Adversarial are **SKIP** — with nothing to judge or break, a fresh pair of
  eyes adds cost and no signal. State the set plainly in the report.
- **Full set — anything else.** The dimensions below, in parallel, plus the
  adversarial decision.

**Give each dimension the content, not the whole rulebook — and not a command.**
The brief carries, **inline**: the changed files' contents and the diff, the
relevant section(s) of `references/rules.md`, and the story's ACs. Paste the diff
in — never hand the sub-agent a `git diff …` (or a file path to `read`) and let
it fetch them: a command is paid **once per dimension**, which is exactly the
~10× cache-read amplification seen when four dimensions each re-fetched the same
diff. Never hand it "read `rules.md`" wholesale either — a dimension scoped to
its own rules section is also less likely to wander.

**Mechanical checks run inline, no sub-agent.** Anything that is a script or a
check rather than a judgment — running the discovered commands, the
`.workflow-dev/` ↔ `config.json` drift check — the orchestrator runs directly.
Don't spend a sub-agent on it.

**Model tiering, when the harness allows it.** The mechanical work — Verification,
Git history disclosure, the inline checks above, and `summarize-changes`' Part 12
review — is a checklist; run it on a **cheaper/faster model**. Adversarial
Correctness and Architecture are judgment; keep them on the strongest model on
hand. If the harness cannot select a model per sub-agent, run everything on the
default and say so — don't silently pretend the tiering happened.

Then, for a **full set**, spawn one independent sub-agent per dimension, each
with its scoped brief, reporting findings as a structured list (file, line,
issue, severity):

| Sub-agent | Dimensions (from rules.md) |
|-----------|-----------------------------|
| **Verification** | Run the discovered commands (build, typecheck, lint, **test**); report failures. The **project's own test suite is run whenever the diff touches it** (for a plugin repo that is its `evals/` suite) — a diff that changes tests is executed, not reasoned about. |
| **Security** | Parts 2–3. Read the changed files for vulnerabilities. |
| **Code quality** | Part 4. Smells, conventions, patterns. |
| **Testing** | Part 5. Coverage of changes, test quality. |
| **Architecture** | Parts 8–9. Separation of concerns, coupling, performance. |

**Git history disclosure** (Part 12) is conditional, not always-run: it fires
only when `CHANGELOG.md` (or equivalent) is in the Step 2 changed-file list,
and then reviews the new/edited entries — formality, length, security-incident
disclosure, personal/internal-behavior exposure. A changelog entry is ordinary
committed file content with no commit-time hook backstop the way a commit
message has, so this run is its enforcement. If `CHANGELOG.md` isn't in scope,
report `SKIP — (not touched)`.

**Context hygiene** (Part 10) is one of the inline checks above, not a
sub-agent. The commit message and PR title/description are a different
artifact, reviewed at a different moment — that's
`/workflow-dev:summarize-changes`, not this step.

**Adversarial correctness (Part 11) is the exception even within a full set:
it starts with a question, not a run.** For anything with real logic, suggest a
depth per §11.0 — with a one-line reason — and **ask the human to pick LITE or
FULL**:

- **Anything with real logic** → suggest **LITE** or **FULL** per §11.0's
  FULL criteria (writes, concurrency, security-relevant surface — including a
  pure-frontend auth component — or a new invariant → suggest **FULL**;
  otherwise → suggest **LITE**), state the one-line reason, and **ask which
  to run**. The choice is the human's, not a notification. Unattended/CI with
  no answer → **LITE**, except the batched/story-end pass, which uses §11.0's
  recommended depth; never silently escalate to FULL on your own.
- **Genuinely zero logic** → **SKIP** (already handled by the reduced set).

Both depths are the same two sub-agents (hunt, §11.1, then verify, §11.2) —
what differs is whether those agents may actually execute anything (FULL) or
must stay on the page (LITE, §11.1/§11.2's depth rules). Neither agent ever
gets the design discussion, only the changed files and the ACs — inheriting
that narrative means inheriting its blind spots, at either depth.

Report only what verify marks CONFIRMED or NEEDS TESTING upward — a REJECTED
claim never reaches the results table. Report this dimension as SKIP — not
FAIL — if it ran (LITE or FULL) and there turned out to be no logic to break
once looked at closely (`— (nothing to test)`).

**Re-checking after a fix — scope it.** When a confirmed finding is fixed, do
**not** re-run the whole set, and never a fresh `hunt` + `verify` over the whole
diff. Re-check the **specific dimension(s) the fix touches, against the changed
files**, plus the Verification commands — a `verify`-only pass over the claimed
fix is enough. This is the difference between paying once and paying for the
whole gate twice; the reflexive second full pass is exactly where a "small fix"
turns into a second validation run.

### Step 4: Collect and present results

Once every sub-agent returns, present a unified report:

```
Validation Results (set: full — the diff carries logic):

| Dimension        | Result | Findings |
|-------------------|--------|----------|
| Verification      | PASS   | 0        |
| Security          | PASS   | 0        |
| Code Quality       | WARN   | 2        |
| Testing           | PASS   | 0        |
| Architecture      | PASS   | 0        |
| Context Hygiene    | PASS   | 0        |
| Git History Disclosure | SKIP | — (CHANGELOG.md not touched) |
| Adversarial Correctness | PASS | 0 — ran at LITE (recommended LITE: real logic, no write/concurrency/security surface; choice surfaced) |

Overall: PASS (2 warnings)

Warnings:
1. src/foo.ts:45 — function exceeds 50 lines (62 lines)
2. src/foo.ts:12 — magic number 1000 could be a named constant
```

**State the set.** The header names whether this ran the **reduced** or **full**
set (Step 3). A reduced run lists only the checks it actually ran — it does not
print the skipped judgment/adversarial dimensions as if they had passed.

The report ends at the warnings — don't print a "ready to commit" verdict here
for a run that still has Step 7 (manual QA + the next-step offer) ahead of it.

When Adversarial Correctness isn't SKIP, its row also states the depth it ran at
and the one-line reason, and reflects that the LITE/FULL choice was surfaced —
the same decision Step 3's gate required, not a silent pick.

**Record the run's cost.** After the report, run
`"${CLAUDE_PLUGIN_ROOT}"/scripts/session-usage.sh` and state its totals
(main thread + per sub-agent tokens and wall-time) alongside the results. This
is what ties a validation run to what it actually cost, and what makes the
savings from a reduced run measurable rather than estimated (WD-0007). The
script is best-effort: when the harness's side-chain files have been purged it
reports `unavailable`, never a misleading zero.

**Attribute it to the story.** A session can mix several stories (and a story
can span sessions and harnesses), so a bare per-session number isn't the
story's cost. When the harness hands you an id for each sub-agent you spawned
(OpenCode's `subagent sessionID`; Claude Code's transcript path), record it in
the story's context — then the run can be totalled **per story** with
`session-usage.sh --sessions <ids>` (OpenCode) or `--transcripts <paths>`
(Claude Code).

### Step 5: Verdict

| Overall | Meaning |
|---------|---------|
| **PASS** | Every dimension passes. Safe to commit. |
| **PASS (N warnings)** | Non-blocking issues found. The human decides whether to fix them first. |
| **FAIL** | Blocking issues found — security, a broken build/tests, type errors, `.workflow-dev/` drift, or a CONFIRMED adversarial-correctness finding (either depth). Must be fixed before committing. |

Blocking: security vulnerabilities, build failures, type errors, test failures, `.workflow-dev/` git-tracking drift (Part 10), a security-incident disclosure or a personal/internal-behavior exposure in the commit message/PR description/CHANGELOG entry (Part 12.2 or 12.3 — both blocking, neither is a lesser variant of the other), or a **CONFIRMED** adversarial-correctness finding (Part 11) — at either depth; CONFIRMED means the same thing whether it was traced statically (LITE) or reproduced live (FULL).
Non-blocking: code smells, missing edge-case tests, style issues, and any adversarial-correctness finding that only reached **NEEDS TESTING** — verify couldn't fully settle it at the depth it ran, so it's a judgment call for the human, same tier as a code smell.

### Step 6: Record the validated diff (only on PASS)

On PASS (with or without warnings), write a marker so a later commit attempt can tell these exact changes were already validated, without asking again:

```bash
REPO_HASH=$(git rev-parse --show-toplevel | tr -d '\n' | shasum | cut -c1-12)
MARKER_DIR="${TMPDIR:-/tmp}/workflow-dev-validate"
mkdir -p "$MARKER_DIR"
DIFF_HASH=$(
  { git diff --name-only HEAD -- . ':!.workflow-dev';
    git ls-files --others --exclude-standard -- . ':!.workflow-dev';
  } | sort -u | while IFS= read -r f; do
    [[ -n "$f" ]] && printf '%s\n' "$f" && cat "$f" 2>/dev/null
  done | shasum | cut -d' ' -f1
)
printf '{"diffHash":"%s","status":"validated","validatedAt":"%s"}' "$DIFF_HASH" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$MARKER_DIR/$REPO_HASH.json"
```

`.workflow-dev/` is excluded from the hash on purpose — a later `/workflow-dev:save` writing to the story file must never invalidate a validation that already passed on the actual code changes. Only `diffHash` matters for comparison; `validatedAt` is display-only metadata, never part of what gets hashed. This file is pure ephemeral machine state — it lives outside the repo, is never committed, and is safe to lose (worst case, the next commit attempt just doesn't find a match and asks the human to confirm validation happened).

`status` is written explicitly as `"validated"` here rather than left implicit — `pre-commit-validate-check.sh` also accepts a marker with no `status` field at all as `"validated"` (backward compatible with markers written before this field existed), but a marker this skill writes fresh always states it plainly. The only other value the hook recognizes is `"deferred"`, written by
`"${CLAUDE_PLUGIN_ROOT}"/scripts/validate-mark-deferred.sh` when `/workflow-dev:implement` defers a task group's validation instead of running it — see that script and `implement/SKILL.md` Step 5 for when that path is taken instead of this one.

**Why content, not `git diff`'s text:** the obvious formula — `git diff` plus
`git status --porcelain` — looked right and even matched between this file
and the hook byte-for-byte, but broke on the single most common sequence
there is: validate while everything is still unstaged, then `git add`
before committing. Staging alone changes a file's porcelain status line
(`?? f` → `A  f`, ` M f` → `M  f`) and makes `git diff` (no `--cached`) go
silent for anything fully staged — so the hash changed on every commit
that staged anything, unconditionally, even with zero actual content
change. Hashing each touched path's on-disk content directly — file list
from `git diff --name-only HEAD` (stable across staged/unstaged for
tracked files) plus `git ls-files --others` (untracked files) — is immune
to this, because `git add` never touches what's actually on disk.

### Step 7: Manual QA (PASS only) and the next-step offer

Runs only on PASS (with or without warnings), and after Step 6 — the marker is
written first, so a manual-QA finding never voids it (the static gate did pass;
a QA finding is a new, separate signal for the human).

1. Read the story's Working Memory → Decisions for the **"Manual QA for this
   story"** row (written once by `/workflow-dev:plan`'s Step 5). **Never ask it
   here.**
   - **"yes"** → run `../manual-qa/SKILL.md` now, against the running app, and
     report its per-AC verdicts. Its timing follows the story's validation
     mode: under "once, at the end" this is the single end-of-story pass; under
     "after every task group" it runs on each PASS. Do not re-ask whether to
     run — that was decided at plan time.
   - **"no", or no row (older story)** → skip manual QA; no notice needed.
   - **Unattended/non-interactive** → same as "no": skip silently (the plan
     default for manual QA is "skip").

2. Then offer the next step via the ask-question tool (OpenCode `question` /
   Claude Code `AskUserQuestion`):

   ```
   AskUserQuestion:
     question: "Validation passed. Draft the commit message / PR now?"
     header: "Next step"
     options:
       - label: "Yes — summarize changes"
         description: "Run /workflow-dev:summarize-changes for the commit/PR text."
       - label: "Not yet"
         description: "Stop here; I'll ask when I'm ready."
   ```
   On "Yes" → run `/workflow-dev:summarize-changes`. On "Not yet" → stop.

   **Skip this offer when `validate` was invoked by `/workflow-dev:implement`** —
   implement's own Step 5 already runs `summarize-changes` right after it, so
   offering again would double it. The offer exists so a **standalone**
   `/workflow-dev:validate` still hands the human the next step instead of
   dead-ending.

3. **Unattended:** skip the question and do not run `summarize-changes` on your
   own — leave the summary for a human-triggered step.

## Principles

- **Stack-agnostic rules** — the dimensions are universal, and so is how verification commands get found: a two-agent survey-then-confirm process reasons from the project's actual stack (§Step 1) instead of pattern-matching a fixed list of manifest files, so a language or tool this file doesn't name by name still gets discovered correctly.
- **Scope-limited** — judge changed files only; don't surface pre-existing issues.
- **The gate scales with the diff (default)** — a diff with no real logic runs the **reduced set** (mechanical checks inline: commands, `.workflow-dev/` drift, a direct read of any changelog entry), a logic-bearing diff runs the **full set**, and the report states which ran. This is §11.0's "spend where the risk is" applied to the whole dimension list, not just adversarial.
- **Scoped, not repeated** — each dimension gets only the rules it needs (not all 554 lines), and a fix triggers a **scoped re-check** of the touched dimension(s) + Verification, never a second full run or a fresh `hunt`+`verify` over the whole diff.
- **Parallel** — sub-agents run independently for speed, except adversarial correctness's hunt→verify pair, which is deliberately sequential (the verify agent's whole point is checking the hunt agent's claims, not racing them). Context hygiene and command-running are inline checks, not sub-agents.
- **Adversarial correctness has a depth decided per diff, not a fixed shape** — SKIP is decided directly (zero logic, nothing to test either way); for anything else, the depth is a recommendation (LITE or FULL, whichever §11.0's criteria call for) presented with a reason, and the human picks (§11.0).
- **Actionable** — every finding names a file, a line, and states the problem plainly.
- **Non-blocking by default** — only security, broken builds/tests, context-hygiene drift, and a CONFIRMED adversarial-correctness finding block (at either depth). A NEEDS TESTING finding — verify couldn't fully settle it without something that depth doesn't do — is advisory, same as everything else.
- **Discoverable** — a command that can't be found is skipped gracefully, not treated as a failure, and a generic "test"/"spec" catch-all runs regardless of stack so an unconventional setup still surfaces instead of silently reading as "no tests exist."
- **Git history disclosure is enforced, not just suggested** — this skill's slice of it (CHANGELOG.md entries in scope) runs as part of the normal dimension pass; the commit message/PR text slice lives in `summarize-changes`, which is required to run Part 12 on its own output and mark it reviewed. Either way, the `pre-commit-message-check.sh` hook is the actual guarantee: it fires on every `git commit`/`gh pr create`/`gh pr edit`, independent of which skill (or none) produced the text, and asks for confirmation — or denies outright for AI/agent attribution — unless the exact text was already marked reviewed. Skipping the review step doesn't make the check disappear; it just means the hook is the one that catches it, at commit time, instead of earlier.
- **Manual QA is opt-in and decided elsewhere** — this skill *runs* manual QA (Step 7) only when `plan` recorded "yes"; it never decides that for itself, and never on a non-PASS.
