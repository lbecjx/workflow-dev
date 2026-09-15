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
