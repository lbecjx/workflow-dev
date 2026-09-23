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
