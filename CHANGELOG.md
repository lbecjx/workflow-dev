<!--
workflow-dev — a persistent-context development workflow for Claude Code
Copyright (C) 2026  lbecjx

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version. See LICENSE for the full text.
-->

# Changelog

All notable changes to this plugin are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/), versioning follows
[Semantic Versioning](https://semver.org/).

## 1.36.0

- A story's cost is now only the spend of its workflow-dev skill runs. Every
  story skill records a start and an end checkpoint, and a run costs end minus
  start, so chat between skills and other stories in the same session are no
  longer counted, and a run of one story inside another's is counted once. A
  run is exact when both ends are Claude Code's exact figure, otherwise priced
  from the table. `session-usage.sh --snapshot … --start` records a start.
- A start that never gets its end is an open run: the total is marked `≥` and
  the index reports `open_runs`. Ledgers written before keep their old deltas.
- `summarize-changes` ends with a closing cost report
  (`session-usage.sh --story <ID> --final`): one row per skill, rows with
  sub-agent spend split by sub-agent, and a note on what is not measured.
- **Breaking for dashboards:** `.usage/.index.json` is now
  `workflow-dev.usage/2`. `verified` and `verified_reason` are removed (and the
  `spend verified ✓` notice with them); `open_runs` is added.
- The rule every skill follows is in `references/run-cost.md`.
- `session-usage.sh` exits with an error on a missing flag value instead of
  waiting forever.

## 1.35.0

- New agent role **`wd-architect`** (class `judge`): `init`'s research
  sub-agents and the drafting of `plan`'s task groups run under it, so its model
  can be bound on its own. `wd-judge` keeps `validate`'s judgment dimensions.
- `plan` hands the drafting to a `wd-architect` sub-agent, with `implement`'s
  coding standards, decision points and stack rules in its brief; you still see,
  approve and answer the plan's questions in the main conversation. If the
  sub-agent can't produce a plan, the main agent drafts it and says so.
- Every task group in a plan carries an execution class, `mechanical` or
  `judgment`.
- `init` recommends a tier for the session's model once per story, without
  asking.
- Re-run `/workflow-dev:setup-models` once: the role registry changed, so the
  roles read as incomplete until the new one is generated (your models are
  kept).

## 1.34.0

- OpenCode is no longer supported; workflow-dev is a Claude Code plugin only.
- Re-run `/workflow-dev:setup-models` once: the role registry changed, so the
  agent roles read as stale until they are regenerated (your models are kept).

## 1.33.0

- Story cost checkpoints are recorded reliably, per session, from any
  subdirectory; a checkpoint that cannot be recorded says so.
- A checkpoint no longer freezes at an old total: newer spend is priced from
  `scripts/model-prices.json` and marked `(estimated)`, about 3% low.
- An exact figure that lands later is added as a `reconcile` entry; a story
  holding only exact figures is marked verified.
- `.workflow-dev/context/.usage/.index.json` serves each story's cost to
  dashboards (`references/usage-api.md`).
- `session-usage.sh --transcript <path>` names the transcript explicitly.

## 1.32.4

- Questions and messages follow the language of the conversation, with short
  option descriptions that say what each choice means to the user. One shared
  rule, `references/user-language.md`, covers every skill. The run-mode question
  in `init` now offers "Step by step" or "Autonomous" without internal details.

## 1.32.3

- The model-tiering question no longer shows as an error. Claude Code prints any
  hook deny behind "Error:"; the hook now allows the skill and tells the agent to
  ask first, so nothing is blocked and nothing is shown in red.

## 1.32.2

- The model-tiering reminder no longer opens a dialog. Its "Yes, and don't ask
  again" silenced the reminder without configuring anything; the hook now blocks
  the skill until the user answers one question: configure the agents, or keep the
  default model for this story or this repo. `setup-models` lets any role keep the
  default.
- The machine-wide opt-out is removed: `~/.workflow-dev/tiering.json` is ignored.
  Keep the default per repo (`"tiering": "default"` in `.workflow-dev/config.json`)
  or per story instead.

## 1.32.1

- `resume` shows a Mode line, so a story left in autonomous mode is not resumed
  unannounced; the README notes that `init` asks for the mode.
- In autonomous mode, `implement` runs `save` after every task group instead of
  suggesting it, so progress and decisions reach the story file mid-run.

## 1.32.0

- Add an opt-in autonomous mode for running one story end-to-end without
  per-step approval: decisions are inferred, recorded, and reported, and the run
  ends with a report of what it did and what it cost. The hard boundary still
  holds.
- The commit/PR hooks are unchanged for the mode: the validate and
  reviewed-message markers keep them quiet, and the AI/agent attribution block
  still blocks on both harnesses.

## 1.31.3

- The README points to `local-backlog` for anyone working locally without a
  cloud ticket service: plain-Markdown stories, on Claude Code and OpenCode.

## 1.31.2

- The README states that the plugin supports OpenCode and that the support is
  tested against **OpenCode 2.0.24**, in a new top-level "Harnesses" section;
  its first sentence now names both harnesses.
- The GPL header tagline in every shipped file (README, skills, scripts, hooks,
  the OpenCode plugin) now names both harnesses instead of Claude Code alone.
- The reminder table no longer reads 2.0.19 as the current OpenCode version, and
  1.31.1 sits above 1.31.0 as newest-first order requires.

## 1.31.1

- `model-tiering-check.sh --role-models` reads a role's model only from a real
  `model:` key in the agent file's closed YAML front matter — never a body line,
  an unterminated block, or a `model:` with no separating space — skips a leading
  UTF-8 BOM the way a YAML parser does, and reads a hash-matching file with no
  such key as `default`, not `bound` with an empty model, since an absent model
  is the harness default on both harnesses.
- The reader's role list accepts only a ``### `role` `` registry heading, so a
  prose `###` heading no longer surfaces as a phantom role; an unreadable
  registry yields no rows, and its comment now says so.
- The usage report's `default` line now reads "ungenerated, stale, or with no
  model", matching the reader's broadened `default`.

## 1.31.0

- `session-usage.sh` gains `--snapshot <story> --stage <stage>` and
  `--story <story>`. `--snapshot` normalizes the current run from either harness
  to one object (dollars and tokens) and records a checkpoint in a durable
  per-story ledger under `.workflow-dev/context/.usage/`; `--story` totals the
  story from that ledger — across sessions and harnesses, by stage, session and
  agent/role — so the number survives deletion of the session or transcript that
  produced it.
- The OpenCode snapshot sums the whole recursive sub-agent tree (grandchildren
  included); the Claude snapshot reads the last `cost-state` `totalCostUSD`
  (sub-agents already included). The dollar figure is real on both harnesses,
  not "tokens only".
- `model-tiering-check.sh --role-models` exposes the runtime role→model binding
  with honest fallbacks (ungenerated/stale → default, opt-out, no-harness →
  unreadable, an alias shown as written). `validate` renders it beside the
  observed spend and flags config-vs-observed discrepancies.
- Checkpoints are written at the workflow boundaries (`init`, `plan`, each
  `implement` task group, `validate`, `save`, `summarize-changes`), and a new
  `/workflow-dev:usage` skill shows the active story's running total.

## 1.30.0

- The validate and message markers are trusted only when their directory — and
  every directory above it within the marker store — is a real directory, owned
  by the current user, and not group- or world-writable. Anything else makes the
  pre-commit gate ask, with the reason in one line.
- `scripts/marker-dir.sh` is the one owner of the marker path, its permissions
  (mode 700) and its safe writes (`mktemp` in place plus `mv`, mode 600),
  shared by the two hooks, the two marker writers and validate's Step 6.

## 1.29.3

- The OpenCode plugin delivers its session-start greeting and compaction save
  reminder through the model's `system` channel, as the catalog notice already
  does.
- `scripts/pre-commit-message-check.sh` gains a `--verdict` mode that returns the
  verdict and its reason in a single run, so the OpenCode plugin never pairs a
  verdict from one invocation with a reason from another.
- The OpenCode plugin states its per-call subprocess cost and its restart
  re-greeting behaviour, and gives the compaction-arming spawn the same timeout
  as the other scripts.

## 1.29.2

- `scripts/session-usage.sh`'s default report no longer presents a finished run
  as the current one: it uses this project's newest transcript while that is
  still being written, and only then a story-tracked path, so a stale or
  just-finished path is not reported as the run in progress.
- The Claude auto-resolution reads the current state shape (`claudePath`) as
  well as the older `transcriptPath`.
- The OpenCode default resolves the run from `OPENCODE_SESSION_ID` when that is
  a top-level session of this directory, rather than always the newest one.

## 1.29.1

- Correct `wd-judge`'s description, in the role registry and the README: it no
  longer lists Adversarial Correctness, which moved to `wd-adversary` in 1.29.0.

## 1.29.0

- Model tiering gains a third role, **`wd-adversary`**, and `validate`'s
  **Adversarial Correctness** pass (the hunt + verify pair) now runs under it
  instead of `wd-judge`. The two are bound separately, so the adversarial pair
  can use a stronger model without putting Security/Architecture/Algorithmic
  Integrity on the same one.

## 1.28.0

- `scripts/command-match.sh` closes three forms it used to get wrong:
  `vagrant ssh -c <cmd>` is looked through like the other runners and a
  `git filter-branch --*-filter <cmd>` like `git rebase -x` (both `maybe`),
  while `vagrant ssh` / `vagrant up` and a bare `filter-branch` stay `no`; a
  multi-line `name=(` array literal is opaque across lines instead of read as a
  command — a later real commit is still `real`, a substitution inside it stays
  visible, and an unterminated array no longer swallows the lines after it.
- `scripts/session-usage.sh` gives an explicit `--transcripts` / `--sessions` /
  `--session` precedence over its implicit source. They sat after the implicit
  Claude resolution and were silently ignored when a transcript was resolvable,
  which is why `session-usage.test.sh` failed two assertions from a project root.
- `scripts/pre-commit-message-check.sh` reads a message body behind combined
  short flags (`-qm`, `-am`), `--message` and a single-quoted body, and resolves
  a `$TMPDIR` path even when the hook's own environment has no `TMPDIR`.

## 1.27.0

- OpenCode's two commit reminders are now **real asks**, not post-command notices:
  the plugin escalates a configured `allow` to a permission request through
  `ctx.permission.hook("evaluate")`, carrying the wording the same `scripts/*.sh`
  already own, so the guardrail arrives before the commit on both harnesses.
  AI/agent attribution remains the one rule that blocks, and it still blocks first.
- An OpenCode "always" reply does not suppress them: the durable project-scoped
  `allow` it saves is indistinguishable from the default, so the reminder re-asks
  rather than let one keystroke retire the guardrail.

## 1.26.0

- `validate` gains an **Algorithmic Integrity** dimension (`rules.md` Part 13,
  run under `wd-judge`): it judges whether an algorithm terminates and makes
  progress, whether its complexity fits the input it actually sees, and whether
  an algorithm reachable from untrusted input has a bounded worst case
  (CWE-407 / CWE-1333 / CWE-400). A confirmed non-termination or an
  attacker-triggerable blow-up blocks; bounded inefficiency is advisory. It is
  skipped on a diff with no logic.
- The `wd-judge` role now also covers Algorithmic Integrity, so the roles
  registry changed — existing role bindings refresh on the next `setup-models`
  run.

## 1.25.3

- The save point tracks the **current** OpenCode session instead of the one a
  story last saved in. OpenCode sets `OPENCODE_SESSION_ID` on every command, and
  a session change now reads from the start rather than reusing the old session's
  position — so a story continued in a fresh session is no longer skipped.
- A save point that can't be read (no `sqlite3`, no OpenCode store, no session)
  says so, instead of reading as "nothing unsaved".

## 1.25.2

- The OpenCode live-catalog notice states how a tool is reached inside Code
  Mode — `search` for it, then call the returned path — instead of telling the
  model to call a bare name that cannot resolve there.

## 1.25.1

- The session-start greeting reads a story's `Implementation Status` value
  instead of scanning the section body for "In Progress", so a `Done` story is
  no longer listed or offered as active.

## 1.25.0

- The session-start greeting no longer picks a story by filename order. It
  names the story the git branch points at (a branch carrying the story's code,
  or one whose words clearly match a single story's title). With several
  `init`'d stories and no way to tell, it lists them in a table instead of
  guessing; with exactly one, it behaves as before.

## 1.24.0

- `/workflow-dev:init` moves a `local-backlog` story to `In Progress` when
  starting it, and `/workflow-dev:save` closes it when it records `Done` or
  `Won't Do`. When it asks which resolution applies, the one inferred from
  what the story shows happened is listed first as the recommended option.
- `ECOSYSTEM.md` documents how `lbecjx` plugins detect and call each other.

## 1.23.0

- A skill-time reminder tells you, at most once per session per version, when
  a newer copy of this plugin is available or already on disk and only needs
  a session restart. Informational only; it never asks, blocks, or denies.

## 1.22.0

- After a real `gh pr create` or `gh pr edit` succeeds, a reminder hands back
  the PR's full URL, so it gets relayed as plain text instead of staying
  buried in a Markdown link label. `gh pr edit` whose own output carries no
  URL falls back to a read-only `gh pr view --json url`.

## 1.21.0

- The commit and PR message review is asked only in a workflow-dev project; the
  attribution block still applies everywhere.
- Commit and PR text kept in a file (`--body "$(cat file)"`, `-F`) is read and
  checked against the reviewed marker.

## 1.20.0

- The commit and PR reminders act on the command itself: an `echo`, a `grep` or
  a heredoc that writes about `git commit`, `gh pr create` or `gh pr edit` no
  longer triggers them.
- The AI/agent attribution block denies only a real commit or PR. A command it
  cannot read (`bash -c`, `eval`) asks instead.
- Both reminders recognize `git -C <dir> commit`, `git -c k=v commit`, extra
  spaces, and a commit after an escaped quote.
- Both reminders look through wrappers and their options, such as `time -p`,
  `sudo -u`, `timeout` and `xargs`.
- A heredoc glued to a redirect, or arithmetic like `$((1<<2))`, no longer hides
  the commands after it.
- A command handed to something else to run (a script fed to `bash`,
  `git submodule foreach`) asks rather than going unnoticed.
- Both hooks read the command with one shared function, so the attribution block
  also works without `jq`.
- `scripts/command-match.sh` is the one place that decides whether a command is
  a real commit or PR.

## 1.19.0

- In a workflow-dev project, the OpenCode plugin adds the session's live tool
  names to every model call, steering the agent away from tools it does not have.
- `scripts/opencode-live-check.sh` reports whether the plugin is running in the
  OpenCode service: `live`, `stale`, `not-loaded` or `not-firing`.
- `resume` and `help` run that check on OpenCode and report a plugin that is not
  live.
- The docs no longer say an OpenCode plugin cannot ask: it can, through the
  permission hook; the reminders still notify.

## 1.18.0

- Every reminder Claude Code gets from `hooks/hooks.json` now reaches OpenCode
  too, by `opencode/plugin.ts` calling the same `scripts/*.sh`.
- The reminder scripts take `--message` for plain text, and the two-level one
  takes `--status` for its `ok`/`notify`/`block` verdict.
- OpenCode cannot raise a question, so where Claude Code asks it notifies — a
  pre-commit reminder arrives after the command, not before it.
- AI/agent attribution blocks on both harnesses.
- `pre-compact-check.sh --arm` arms the compaction state where no `PreCompact`
  event exists.
- `README.md` and `hooks/README.md` state per reminder what each harness gets.

## 1.17.0

- `init` checks the agent-role bindings before spawning its research
  sub-agents, and runs `setup-models` inline in the same session when they are
  missing or stale.
- The check is `model-tiering-check.sh --status`'s verdict — one owner for the
  answer: `ok` and `opted-out` stay silent, and a missing or unreadable harness
  says so and runs on the default model.
- `init`'s steps are renumbered (repo-level is now Step 7, research Step 8);
  `README.md` documents the self-heal, and `references/harness-tools.md` the
  per-harness id a skill uses when it invokes another.
- `model-tiering-check.test.sh` pins init's call shape — the payload as an
  argument, and the no-payload case that reports `not-ours` — and a new eval
  guards that `init` runs the check and reaches its story-context step without
  prompting.

## 1.16.0

- Tool names are written as **capabilities**, each harness's name an example —
  the mapping lives once in `references/harness-tools.md`.
- `harness-vocab.test.sh` fails when shipped text names a Claude-Code-only tool
  without naming its environment.
- `hooks/hooks.json` is documented as **Claude Code only**, matchers included.
- `evals/*/prompt.md` note that `allowed_tools` are Claude Code names, with the
  OpenCode equivalents alongside; the values are unchanged.
- README documents the **OpenCode install** and the per-harness naming.
- The gate states that a runtime-behaviour claim can't be CONFIRMED by reading
  alone, and that a changelog entry follows the length rule of a commit message.
- CI runs the test scripts on every push and pull request.

## 1.15.0

- Model tiering is real: the plugin names **roles** — `wd-operator` for the
  mechanical checklist, `wd-judge` for judgment calls — and a new
  `/workflow-dev:setup-models` command discovers the models your harness offers
  and binds each role to one, written into your own agent config. No model name
  ships in the plugin.
- A reminder hook asks you to bind the roles (or opt out via
  `~/.workflow-dev/tiering.json`) until they're mapped: an explicit ask on
  Claude Code, a notice on OpenCode 2.
- Skills resolve the plugin root portably, so script-driven steps now work under
  OpenCode (which doesn't set `CLAUDE_PLUGIN_ROOT`), not just Claude Code.
- Part 12.3 blocks AI *attribution*, not naming the platform a change is about —
  a commit saying "Claude Code" or "OpenCode" no longer trips the review.

## 1.14.0

- Renamed the Adversarial Correctness depths to what they actually are — **Skip**,
  **`no-repro`** (without reproduction), **`complete`** — so they no longer read as
  a cost choice; the depth is about **confidence** (can a claim be reproduced), not
  time, and the docs say so.
- Bounded both active levels: a **scope ceiling** (work only from the brief, no
  executing/cloning/exploring outside) and a **stop rule** (return NEEDS TESTING
  rather than iterate open-endedly). `verify` still runs at both and is never dropped.

## 1.13.0

- Clarified three decision points: `plan` asks for approval on its own before the
  two one-time questions (not bundled); the validation-mode `(recommended)` is
  labelled as the plugin's suggestion, not the recorded answer; and `save`'s
  auto-vs-manual split is documented — mechanical state is kept current
  automatically, decisions/discoveries are saved on request with review.

## 1.12.0

- `save-read-unsaved.sh --digest` prints a readable line per message (channel +
  text, tool-call payloads and reasoning stripped) instead of raw JSON, so a save
  no longer pulls a transcript dump into context.
- `validate` owns **every** rulebook part — Part 1 (Scope Compliance) and Part 7
  (CI/CD Anticipation) now have a home in Step 3's table.
- A validation run ends with a **disposition per WARN** (fixed / new story /
  accepted), and guidance records that an adversarial cost cut goes to LITE,
  never dropping verify.

## 1.11.0

- Recording a run's cost is now a **gate** in `validate`, not just prose: no run
  (full or reduced) closes without stating what it cost, measured **per run**
  rather than as a session total. `implement` records each sub-agent's id, so
  cost is attributable **per story**.

## 1.10.0

- `validate`'s per-dimension brief must carry the changed files' contents and the
  diff **inline**, never a command for the sub-agent to fetch them — so the same
  diff isn't re-read once per dimension (a command is paid once per dimension,
  ~10× the cache reads).

## 1.9.1

- Fixed the save point's `.gitignore` helper: it no longer appends its state
  directory when an ancestor pattern (e.g. `.workflow-dev/`) already ignores it,
  so a save no longer dirties a tracked `.gitignore`.

## 1.9.0

- Validation now scales to the diff: a change with no logic runs inline checks
  only, a logic-bearing change the full set, and each dimension gets a scoped
  brief instead of the whole rulebook; a fix is re-checked without re-running
  the whole gate. `summarize-changes` reviews a change-set once, on a cheaper
  model.
- `session-usage.sh` reports token usage and wall-time per main thread and per
  sub-agent, from a Claude Code transcript or OpenCode's store, and totals cost
  per story (`--sessions` / `--transcripts`).
- The save point works on OpenCode too and is source-aware, so a story can move
  between Claude Code and OpenCode without re-reading or skipping content.
- `implement` requires edge-case tests for every new input boundary, and skills
  reference their scripts via `${CLAUDE_PLUGIN_ROOT}`.

## 1.8.0

- Surfaced the workflow's procedural gates as short, prominent checklists in the
  skills that act on them — `validate` (the Adversarial Correctness LITE/FULL
  ask), `implement` (read the stored validation mode; summarize before commit;
  one commit per task group; repo-first, post-merge plugin updates), and `plan`
  (the two one-time questions). A new eval guards the adversarial-depth ask.

## 1.7.1

- `/workflow-dev:help` and the README now describe the manual-QA step added in
  1.7.0: `manual-qa` is listed, the workflow diagram shows the optional
  PASS-path QA branch, and the end-of-story next step points at `validate`
  instead of "ready to commit". Both surfaces also now list every skill
  (`summarize-changes`, `refresh` included), and the README's Hooks section
  matches the shipped hooks.

## 1.7.0

- `/workflow-dev:validate` can now run a **manual QA** pass — exercising the
  app in a real browser or device — when the story chose it. `/workflow-dev:plan`
  asks once, up front; a new `manual-qa` skill does the work on validate's PASS
  path, then hands back to the normal commit/PR step.

## 1.6.0

- Validation can now be deferred to story end instead of running after
  every task group — `/workflow-dev:plan` asks once, up front, and
  `/workflow-dev:implement` follows that choice silently for the rest of
  the story. Commit-time enforcement stays intact either way (a new
  marker state distinguishes "deferred" from "unvalidated").

## 1.5.1

- Fixed the `/workflow-dev:validate` marker (used to skip re-asking at
  commit time): it hashed `git diff` + `git status --porcelain`, which
  changes format across a plain `git add` with zero content change — so
  validating before staging, then staging before commit (the normal
  order), invalidated the marker on every single commit. Now hashes each
  touched file's on-disk content directly, which staging never alters.

## 1.5.0

- Added `/workflow-dev:summarize-changes` to draft and review the commit
  message, PR title, and PR description — split out of `implement` and
  `validate`, which now only handles `CHANGELOG.md` entries.
- Part 12.3 now hard-blocks any AI/agent/LLM attribution or co-authorship
  in a commit or PR — enforced by both scripts, not just reviewed.
- Fixed: a 12.3 (personal/internal exposure) violation now blocks on its
  own, same tier as 12.2, instead of only when a secret was also named.

## 1.4.0

- Added Part 12 (Git History Disclosure & Tone) to `/workflow-dev:validate`:
  reviews the drafted commit message/PR description and any `CHANGELOG.md`
  entries for formality, length, security-incident disclosure, and
  personal/internal-behavior exposure.

  Enforced two ways so it can't be skipped: `implement/SKILL.md` runs it
  as an independent sub-agent before suggesting a commit message, and a
  new `pre-commit-message-check.sh` hook asks for confirmation on every
  `git commit`/`gh pr create`/`gh pr edit` unless the exact text was
  already marked reviewed.

## 1.3.2

- `/workflow-dev:validate`'s Step 1 (discovering build/test/lint commands)
  used a fixed, short list of manifest files (`package.json` → npm scripts,
  `pyproject.toml` → pytest, and nothing else) — a project shaped any other
  way was invisible to it. Confirmed against a real project using
  `pytest.ini`/`requirements-dev.txt` with no `pyproject.toml`: Verification
  would have reported the test suite as "not discovered" and skipped it
  entirely, never actually running it.

  Replaced with two sub-agents in sequence: a stack-survey agent identifies
  every language/framework in the repo and lists the realistic full set of
  conventional test/build/typecheck/lint/format tools for each — its own
  ecosystem knowledge merged with the examples already named in this file,
  neither one trusted alone — then a confirmation agent checks the repo for
  each candidate and, independently, always also runs a generic "test"/
  "spec" name search as a catch-all for anything neither source named. A
  command still not found is skipped, not failed, but the report now says
  what was actually searched for, distinguishing "looked and found nothing"
  from "never looked."

## 1.3.1

- The `PreToolUse` hook that warns before a `git commit` with no matching
  `/workflow-dev:validate` marker used `permissionDecision: "allow"` — it
  injected an advisory string but let the commit through regardless,
  leaving the gate entirely dependent on an agent reading that text and
  acting on it. Changed to `"ask"`: the commit now requires an explicit
  human decision instead of passing through silently. Still not a hard
  deny — the human can approve committing unvalidated changes — but the
  decision now actually reaches them instead of being an easy-to-miss
  string in tool output.

## 1.3.0

- The Adversarial Correctness dimension (Part 11) no longer always runs at
  full depth — its full hunt→verify pair, both agents doing live empirical
  testing, is by a wide margin the most expensive part of
  `/workflow-dev:validate` (routinely longer, and more tokens, than the
  other six dimensions combined). A new §11.0 now picks one of three
  depths per diff:
  - **SKIP** — nothing spawned; decided directly, no need to ask, for diffs
    with no real logic (docs, a pure rename, a config-value change) — the
    only depth with nothing to actually choose between.
  - **LITE** — two independent agents (hunt then verify), both held to
    static-analysis depth: read the code and trace it by hand, never
    actually run anything.
  - **FULL** — hunt and verify both run empirically (spin up a server, fire
    real requests, corrupt a file and re-run the script against it).

  For anything other than SKIP, the dimension suggests LITE or FULL (LITE
  by default; FULL when the diff touches writes, concurrency,
  security-relevant surface — including a pure-frontend auth component, not
  just backend endpoints — or a new invariant), states the reason in one
  line, and the human picks which one actually runs. Depth is never decided
  for the human past SKIP; unattended runs (CI, batch mode, no reply
  possible) fall back to LITE regardless of which depth was suggested.

  Verify's outcomes are now CONFIRMED, NEEDS TESTING, or REJECTED — NEEDS TESTING is
  new, for a claim that traces correctly but needs live execution to settle
  for certain (most common at LITE depth, where that execution never
  happens). CONFIRMED still blocks the commit at either depth; NEEDS TESTING is
  a WARN-level judgment call for the human, same tier as a code smell. The
  other six dimensions are unaffected and still always run.

## 1.2.0

- Added an "Adversarial Correctness Review" dimension to `/workflow-dev:validate`
  (`references/rules.md` Part 11). Every other dimension checks compliance
  against a checklist; this one has an explicit mandate to find a concrete
  input or sequence that breaks the change, run as two independent sub-agents
  in sequence — a "hunt" agent given only the changed files and ACs (not the
  design reasoning that produced them, so it doesn't inherit the same blind
  spots), then a separate "verify" agent that independently re-derives each
  claimed finding from the actual code before it's allowed to reach the
  report. Only a CONFIRMED finding is reported, and a CONFIRMED finding now
  blocks the commit, same tier as a security or build failure.

## 1.1.10

- 1.1.8's fix addressed the wrong layer: it assumed the wrong time was
  Claude paraphrasing instead of relaying `save-mark-saved.sh`'s output —
  but a real recurrence, confirmed against the actual local clock, showed
  the script's own output was wrong. BSD `date`'s `-u` flag, combined with
  `-f` to parse an ISO 8601 string, also forces the *output* to UTC, not
  just the input parsing — a single-step `date -j -u -f ... +format` call
  silently prints the value back out in UTC, never actually converting.
  Fixed with the standard two-step form: parse to an epoch integer (where
  `-u` is legitimately needed), then format that epoch without `-u`,
  which renders in local time. Verified directly against the real system
  clock, not just visual plausibility.

## 1.1.9

- Reworded the Step 6 example to use fully generic placeholder values.

## 1.1.8

- `save`'s Step 6 confirmation showed a wrong "local" save time — visibly
  off from the real local time (a screenshot in a real session showed
  "3:02 AM" as the reported save point next to Claude Code's own footer
  timestamp reading "10:02 PM" for the same moment). Instead of relaying
  `save-mark-saved.sh`'s own already-converted output, Claude paraphrased
  a shorter summary line, sourcing the raw `dateTime` field from
  `.compaction-state/[STORY-ID].json` directly — which is stored in UTC
  specifically for the script to convert, not for display. Step 6 now
  explicitly warns against re-deriving this value for a reformatted
  summary line.

## 1.1.7

- Confirmed in a real session that delivery works (Claude quoted the
  reminder verbatim), but it still answered the human's actual question
  first and only ran `/workflow-dev:save` after being called out —
  competing with a real, in-the-same-turn question is exactly where an
  injected reminder is easiest to deprioritize. The same loss to
  competing priority also happens on the `PostToolUse` path, mid an
  autonomous run (e.g. `/workflow-dev:implement` chaining tool calls) —
  the current task/next tool call wins out and save never gets
  inserted. The reminder now claims priority explicitly, worded per the
  event that actually fired: "before answering the question below" for
  `UserPromptSubmit`, "before running the next tool call or continuing
  whatever task is in progress" for `PostToolUse` — naming the specific
  thing it needs to outrank, instead of one generic phrasing for both.
- `save/SKILL.md` still said "watermark" in every user-facing spot
  (Steps 3 and 6), a name 1.1.6 dropped for the underlying file/directory
  but never updated in this prose — confirmed in the same real session,
  where Claude's own save summary literally read "no prior watermark,"
  parroting the stale term straight back to the human. Replaced with
  "save point" throughout.

## 1.1.6

- `PreCompact` copied the *entire* transcript into a fresh backup file on
  every compaction, forever. A real session left uninterrupted across 6
  compactions produced a single 17MB, 4300+ line backup — the same
  already-saved history recopied every single time, handed to `save`'s
  Step 3 as if it were all new. Claude Code's session `.jsonl` files are
  both append-only within a session (verified empirically — line and
  byte content stay identical while a live transcript grows) and never
  deleted (they persist under `~/.claude/projects/...` indefinitely), so
  there is no need to copy anything at all: the original is always there
  to read later. Compaction backups are gone entirely, replaced by one
  small per-story JSON state file (`.workflow-dev/context/.compaction-state/[STORY-ID].json`
  — `transcriptPath`, `length`, `dateTime`, `pendingSave`) recording how
  far a prior successful save got into a given transcript file, and
  whether a reminder is currently owed. Two new scripts do the mechanical
  work: at Step 3, `save-read-unsaved.sh` reads straight from the live
  `transcriptPath` and prints only what's past `length` (small in the
  normal case of saving promptly, only large if several compactions were
  skipped in a row); at Step 6, `save-mark-saved.sh` — only after Step 5
  actually writes the story file — advances `length` to precisely where
  that read stopped and clears `pendingSave`, converting its UTC
  timestamp to a readable local date/time along the way. Neither
  calculation is left to the model: get either wrong and a future read
  could silently skip content nobody actually saved.
  `post-compaction-save-check.sh` now scans this same state for a
  `pendingSave: true` story instead of reading a separate marker file —
  one piece of state per story instead of two. `save-cleanup.sh` is
  removed; there's no backup file left to clean up. `transcriptPath` is
  a local absolute filesystem path (it encodes the OS username) that has
  to be stored somewhere — a plain Bash tool call has no way to learn a
  session's transcript path on its own, only hooks receive it — so
  `.compaction-state/` is force-added to `.gitignore`, same as
  `.compaction-backups/` was, regardless of whether the project tracks
  `.workflow-dev/` itself.

## 1.1.5

- 1.1.4's fix worked (confirmed in a real session — Claude invoked save
  directly, no longer asking permission first), but the same run dropped
  the "declining loses this" warning it was also asked to add — two
  instructions folded into one paragraph, and only one got followed.
  Split into two explicit, numbered, mandatory actions, with the warning
  given as an exact, verbatim line to append rather than a paraphrased
  idea to work in.
- Bigger gap found in the same session: `save` never actually read the
  compaction backup it kept telling the human it would protect. Asked
  directly, Claude confirmed it was working entirely from Claude Code's
  own compaction summary — the exact thing that might have dropped
  detail — and had never opened the `.jsonl` backup. `save/SKILL.md` now
  explicitly requires reading a story's compaction backup, when one
  exists, before relying on the in-context summary, and reporting which
  backup was used.
- Step 6's cleanup deleted every backup for a story (`[STORY-ID]-*.jsonl`)
  on any completed save, including ones this particular save never
  opened — a backup the human hadn't gotten to yet, or one a second
  compaction created after this save's review already started, would be
  destroyed with its content never actually persisted. Now deletes only
  the specific file(s) Step 3 actually read, one at a time, tied to
  confirmed capture rather than "a save happened." Also corrected the
  reminder's warning text, which implied declining causes immediate
  deletion — it doesn't: nothing is deleted on decline, the backup just
  stays unintegrated until a future save reads it.

## 1.1.4

- Confirmed working end-to-end in a real session, with one gap: the
  reminder asked Claude to run `/workflow-dev:save` "on your own
  initiative," but Claude read that loosely and asked the human whether
  it should run it or wait, instead of just invoking it — an extra layer
  of asking on top of the confirmation `save` already shows in its own
  Step 4. The instruction is now explicit: invoke it now, don't ask
  whether to, the skill's own summary-and-confirm is the only
  confirmation this needs.

## 1.1.3

- Both `SessionStart` and `PreCompact` matched the Implementation Status
  line with an exact-text grep — a real `/workflow-dev:init` run
  paraphrased the template's heading into a different, still-valid
  wording, and the exact match silently never fired for that story. Now
  scans the whole section for "In Progress" instead of one exact line.
  `init/SKILL.md` also now quotes the literal heading to copy instead of
  restating it in prose, which is the likely reason the wording drifted.

## 1.1.2

- The post-compaction save reminder only fired on `UserPromptSubmit` — the
  human's next typed message. During a long autonomous run (e.g.
  `/workflow-dev:implement` chaining tool calls with no human input in
  between), that assumption doesn't hold: the reminder could sit unseen
  through many tool calls. The same check now also runs on `PostToolUse`
  (any tool), so whichever fires first after a compaction — a human prompt
  or the next tool call — surfaces the reminder. Renamed
  `user-prompt-compaction-check.sh` to `post-compaction-save-check.sh`
  since it now serves both events; `hookEventName` in its output is read
  from the firing event instead of hardcoded.

## 1.1.1

- The `SessionStart` hook checked a field, `session_start_reason`, that
  never existed in Claude Code's real input — the actual field is `source`.
  This silently no-op'd the hook on every real session since it was
  written; every manual test of the script had "passed" only because each
  one fed it the same wrong field name the script itself expected.

## 1.1.0

- `PreCompact` cannot hand any text to Claude or the human — per Claude
  Code's own docs it discards `systemMessage` and `additionalContext`
  entirely on this event, so the 1.0.2 bell was the ceiling of what it could
  do alone. It now also backs up the raw pre-compaction transcript to
  `.workflow-dev/context/.compaction-backups/` whenever an in-progress story
  exists — an automatic action that needs nobody to notice anything — and
  leaves a marker for a new `UserPromptSubmit` hook, which reliably does
  reach Claude's context, to run `/workflow-dev:save` on its own initiative
  on the very next prompt (save still shows its usual summary and asks for
  confirmation — only the waiting-to-be-asked part is skipped), explicitly
  warning the human that declining leaves whatever the compaction summary
  dropped unrecovered. The backups directory is force-added to `.gitignore`
  since a raw transcript can contain anything pasted into the conversation,
  credentials included; `save` now deletes a story's backups once its own
  save completes, since they've served their purpose by then.

## 1.0.2

- Fixed the `PreCompact` hook to actually reach the human: `systemMessage`
  and `additionalContext` are only honored on `UserPromptSubmit`,
  `UserPromptExpansion`, `SessionStart`, and `PostModelSwitch` — on every
  other event, including `PreCompact`, they go to the debug log only and
  were never seen. The hook now rings the terminal bell via
  `terminalSequence`, the one field documented as supported on all events.

## 1.0.1

- Corrected the React + TypeScript stack standard: plain typed function
  components are the recommended pattern, not `React.FC<Props>` — updated
  the rule, both code examples, and the anti-patterns table to match.
- Fixed the `PreCompact` hook to check every story file under
  `.workflow-dev/context/`, not just the first one found — with multiple
  story files present, an arbitrary pick could lack the Implementation
  Status line entirely, silently skipping the actual in-progress story.
- Fixed the same first-file issue in the `SessionStart` hook, and made its
  Plan-section check match any section number instead of assuming Plan is
  always section 5 — a story with an extra section before it shifts the
  number.

## 1.0.0

- Initial release.
