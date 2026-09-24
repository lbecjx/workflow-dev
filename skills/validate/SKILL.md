---
name: validate
description: Runs a multi-dimensional quality gate on uncommitted changes before commit. Use when the user says "validate", "check quality", before suggesting a commit, or any time a PR is about to be created or edited — the user says "create the PR", confirms "yes" to an offer to open one, or asks to fill in a PR template/description.
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
- **Any time a PR is about to be created or edited** — see "PR mode" below.
  This is not limited to an explicit "run validate" request: it fires on
  "create the PR", on a plain "yes"/"sí" confirming an offer to open one,
  on "fill in the PR template" or "write the PR description," and on
  `gh pr create`/`gh pr edit` being about to run for any other reason.
  None of that requires the human to have said the word "validate."

## What this does not do

- Doesn't commit or push
- Doesn't auto-fix issues — it reports them and leaves the call to the human
- Doesn't validate business logic — that's manual testing / AC verification

## PR mode

Triggered by anything in the last bullet above — a PR request, a
confirming "yes," a template-filling request, or `gh pr create`/`gh pr
edit` about to run for any reason. This is a narrow entry point into this
skill: it runs **only** Part 12 (Git History Disclosure & Tone) against
the PR title/description, not the other six dimensions — those judge code
changes, and a PR-creation moment doesn't imply new uncommitted changes to
judge (the code was very likely already validated when it was committed).

1. Draft (or take the already-drafted) title and description — including
   one being typed directly into a template the human asked to fill in.
2. Run it through Part 12 (`references/rules.md`) as an independent
   sub-agent — not a self-review by whoever just drafted it, same
   reasoning as everywhere else this dimension runs.
3. If it doesn't pass, rewrite per §12.5 and re-check.
4. Once it passes, mark the exact final text reviewed:
   `printf '%s' "<final PR body text>" | scripts/git-message-mark-reviewed.sh`.
5. Only then run `gh pr create`/`gh pr edit`.

This isn't optional because a human said "yes" instead of "validate" — the
`pre-commit-message-check.sh` hook fires on the actual `gh pr create`/
`gh pr edit` command regardless, and will ask for confirmation if this
step got skipped. Running PR mode here just means that confirmation is a
formality instead of the first time anyone actually looked at the text.

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

`git diff --name-only` (staged + unstaged) defines the validation scope. Only these files are judged — pre-existing issues elsewhere are out of scope, not failures.

### Step 3: Run validation dimensions in parallel

Spawn one independent sub-agent per dimension. Each receives the changed-file list and the relevant section of `references/rules.md`, and reports findings as a structured list (file, line, issue, severity).

| Sub-agent | Dimensions (from rules.md) |
|-----------|-----------------------------|
| **Verification** | Run the discovered commands (build, typecheck, lint, test); report failures. |
| **Security** | Parts 2–3. Read the changed files for vulnerabilities. |
| **Code quality** | Part 4. Smells, conventions, patterns. |
| **Testing** | Part 5. Coverage of changes, test quality. |
| **Architecture** | Parts 8–9. Separation of concerns, coupling, performance. |
| **Context hygiene** | Part 10. `.workflow-dev/` state matches `.workflow-dev/config.json`. |
| **Git history disclosure** | Part 12. Reviews the drafted commit message and/or PR title/description, plus any new/edited `CHANGELOG.md` entries in scope — not the rest of the diff — for formality, length, security-incident disclosure, and personal/internal-behavior exposure. |

Git history disclosure has two independent triggers, not one fixed
condition:

- **A drafted commit message or PR title/description exists.** If neither
  exists yet at the point `/workflow-dev:validate` runs, this half of the
  dimension has nothing to check yet — don't block waiting for a draft
  that doesn't exist. It re-runs, independently of a full
  `/workflow-dev:validate` pass, at the actual moment a message/
  description gets drafted (see `implement/SKILL.md` Step 5, and the same
  applies to any PR title/description drafted from this repo) — that
  agent must be a fresh sub-agent, not the same context that just wrote
  the draft, for the same reason Part 11 keeps hunt and verify from
  sharing context: whoever wrote the text tends to re-confirm it reads
  fine. On PASS, mark the exact reviewed text via
  `scripts/git-message-mark-reviewed.sh` (see Part 12.5) — this is what
  lets `pre-commit-message-check.sh` recognize at actual `git commit`/
  `gh pr create` time that this specific text already cleared the check,
  instead of asking every time regardless.
- **`CHANGELOG.md` (or equivalent) is in the Step 2 changed-file list.**
  Whenever it's touched, this sub-agent reads the new/edited entries and
  runs the same 12.1–12.4 checks against them — a changelog entry is
  ordinary committed file content, so there's no commit-time hook backstop
  for it the way there is for the commit message itself; this run, inside
  `/workflow-dev:validate`, is the enforcement for changelog text.

If neither trigger applies — no drafted message/description and
`CHANGELOG.md` isn't in scope — report `SKIP — (nothing drafted yet)` in
the results table.

These six always run together, in parallel — they're cheap. **Adversarial
correctness (Part 11) has a depth, decided per diff, not a fixed shape.**
Apply §11.0's criteria to the scope from Step 2:

- **No real logic in the diff** (docs, a pure rename, a config-value change)
  → **SKIP**. Decide this directly, don't ask — state it plainly in the
  results (`SKIP — (skipped, low risk)`), not silently omitted. This is the
  only depth that never asks.
- **Anything else** → pick a suggested depth per §11.0's FULL criteria
  (writes, concurrency, security-relevant surface — including a pure-frontend
  auth component, or a new invariant → suggest **FULL**; otherwise → suggest
  **LITE**), state the one-line reason, and ask the human to pick LITE or
  FULL. Don't decide this one yourself and move on — the choice is the
  human's, not just a notification. Default to **LITE** if unattended/CI and
  no answer is possible — never silently run FULL just because that's what
  was suggested.

Both depths are the same two sub-agents (hunt, §11.1, then verify, §11.2) —
what differs is whether those agents may actually execute anything (FULL) or
must stay on the page (LITE, §11.1/§11.2's depth rules). Neither agent ever
gets the design discussion, only the changed files and the ACs — inheriting
that narrative means inheriting its blind spots, at either depth.

Report only what verify marks CONFIRMED or NEEDS TESTING upward — a REJECTED
claim never reaches the results table. Report this dimension as SKIP — not
FAIL — if it ran (LITE or FULL) and there turned out to be no logic to break
once looked at closely (`— (nothing to test)`).

### Step 4: Collect and present results

Once every sub-agent returns, present a unified report:

```
Validation Results:

| Dimension        | Result | Findings |
|-------------------|--------|----------|
| Verification      | PASS   | 0        |
| Security          | PASS   | 0        |
| Code Quality       | WARN   | 2        |
| Testing           | PASS   | 0        |
| Architecture      | PASS   | 0        |
| Context Hygiene    | PASS   | 0        |
| Git History Disclosure | SKIP | — (nothing drafted yet) |
| Adversarial Correctness | PASS | 0    |

Overall: PASS (2 warnings)

Warnings:
1. src/foo.ts:45 — function exceeds 50 lines (62 lines)
2. src/foo.ts:12 — magic number 1000 could be a named constant

Ready to commit.
```

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
  { git diff -- . ':!.workflow-dev'; git status --porcelain -- . ':!.workflow-dev'; } | shasum | cut -d' ' -f1
)
printf '{"diffHash":"%s","validatedAt":"%s"}' "$DIFF_HASH" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$MARKER_DIR/$REPO_HASH.json"
```

`.workflow-dev/` is excluded from the hash on purpose — a later `/workflow-dev:save` writing to the story file must never invalidate a validation that already passed on the actual code changes. Only `diffHash` matters for comparison; `validatedAt` is display-only metadata, never part of what gets hashed. This file is pure ephemeral machine state — it lives outside the repo, is never committed, and is safe to lose (worst case, the next commit attempt just doesn't find a match and asks the human to confirm validation happened).

## Principles

- **Stack-agnostic rules** — the dimensions are universal, and so is how verification commands get found: a two-agent survey-then-confirm process reasons from the project's actual stack (§Step 1) instead of pattern-matching a fixed list of manifest files, so a language or tool this file doesn't name by name still gets discovered correctly.
- **Scope-limited** — judge changed files only; don't surface pre-existing issues.
- **Parallel** — sub-agents run independently for speed, except adversarial correctness's hunt→verify pair, which is deliberately sequential (the verify agent's whole point is checking the hunt agent's claims, not racing them).
- **Adversarial correctness has a depth decided per diff, not a fixed shape** — SKIP is decided directly (zero logic, nothing to test either way); for anything else, the depth is a recommendation (LITE or FULL, whichever §11.0's criteria call for) presented with a reason, and the human picks (§11.0).
- **Actionable** — every finding names a file, a line, and states the problem plainly.
- **Non-blocking by default** — only security, broken builds/tests, context-hygiene drift, and a CONFIRMED adversarial-correctness finding block (at either depth). A NEEDS TESTING finding — verify couldn't fully settle it without something that depth doesn't do — is advisory, same as everything else.
- **Discoverable** — a command that can't be found is skipped gracefully, not treated as a failure, and a generic "test"/"spec" catch-all runs regardless of stack so an unconventional setup still surfaces instead of silently reading as "no tests exist."
- **Git history disclosure is enforced, not just suggested** — a skill that drafts a commit message or PR description is required to run Part 12 on its own output and mark it reviewed (§Step 3), but the `pre-commit-message-check.sh` hook is the actual guarantee: it fires on every `git commit`/`gh pr create`/`gh pr edit`, independent of which skill (or none) produced the text, and asks for confirmation unless the exact text was already marked reviewed. A skill skipping its own review doesn't make the check disappear — it just means the hook is the one that catches it, at commit time, instead of earlier.
