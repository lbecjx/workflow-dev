<!--
workflow-dev — a persistent-context development workflow for Claude Code and OpenCode
Copyright (C) 2026  lbecjx

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version. See LICENSE for the full text.
-->

# hooks/

`hooks.json` is **Claude Code only**. It does not run under OpenCode.

- The matchers `"Bash"` and `"Skill"` are Claude Code *event* vocabulary — the
  names of events in that harness, not universal tool names. Reading them as
  tool names is how an agent under another harness ends up calling a tool that
  doesn't exist.
- JSON takes no comments, which is why this note sits beside the file rather
  than inside it.
- OpenCode's counterpart is the plugin `opencode/plugin.ts` (v2 API), which
  covers every reminder registered above by calling the **same** `scripts/*.sh`
  from its own hooks — the wording and the "is this warranted?" test stay in the
  script, so the two harnesses cannot come to different conclusions about either.
  The two commit reminders are real asks here too (WD-0022): a `shell` action's
  `allow` is escalated to `ask` through `ctx.permission.hook("evaluate", …)`,
  carrying the script's own wording. The plugin never denies; AI/agent
  attribution still blocks on both, and it still blocks in `execute.before`.
  Two limits are documented, not silent: an OpenCode **"always"** reply saves a
  durable project-scoped `allow` that the hook cannot distinguish from the
  default, so it does not suppress the reminder (it re-asks); and a configured
  **`deny`** never reaches the hook, so that is the one case the reminder does
  not run.
- The plugin also adds the session's live tool names to every model call in a
  workflow-dev project — OpenCode only, with no Claude Code counterpart — and
  records that it is running so `scripts/opencode-live-check.sh` can tell.
- Both commit/PR hooks ask `scripts/command-match.sh` whether a command is really
  a `git commit` / `gh pr create` / `gh pr edit`, so they act on the command
  itself and not on a command that only mentions one. It answers `real`, `maybe`
  (wrapped in `bash -c`, `eval` and similar) or `no`. `maybe` is treated as `real`
  by the reminders, which only ask; the attribution block never denies on it.
- After a real `gh pr create`/`gh pr edit` succeeds, `scripts/post-pr-url-check.sh`
  hands back the PR's full URL (WD-0024). On Claude Code it reads
  `tool_response.exit_code`/`stdout` from the `PostToolUse` payload and stays
  quiet on a non-zero exit. OpenCode's `execute.after` carries no exit code, so
  there a URL found in the output is the only signal of success — a documented
  gap, not a missed check. `gh pr edit` whose own stdout carries no URL falls
  back to a read-only `gh pr view --json url`, the one script in this plugin
  that calls out to `gh` itself.
- `scripts/plugin-update-check.sh` tells the developer, at most once per
  session per version, when a newer copy of this plugin exists (naming the
  update command) or is already on disk and only needs a session restart
  (WD-0029). It is **Claude-Code-only, by scope, not an oversight**:
  OpenCode's update path is a `git pull` in its clone, not
  `claude plugin update`, so there is nothing for an OpenCode counterpart to
  tell — this is the one reminder above with no OpenCode side at all, not a
  gap in the "same script, both harnesses" rule the rest of this file
  describes. It emits only `additionalContext`, never a permission decision,
  on both the events it fires on.
- The compaction-state save point (`scripts/save-read-unsaved.sh`,
  `scripts/save-mark-saved.sh`) keeps how far each story's last save read, per
  harness, in `.workflow-dev/context/.compaction-state/<STORY>.json` — Claude Code
  a transcript path + line count, OpenCode a session id + message `seq`. On
  OpenCode the current session is the one the harness sets on every command
  (`OPENCODE_SESSION_ID`), falling back to the newest session for the project; a
  session other than the one last saved is read from the start rather than reusing
  an old position (WD-0008).
- The one reminder with no verified OpenCode trigger is the compaction pair:
  `pre-compact-check.sh --arm` is wired to the subscribed compaction events, and
  those register but have never been observed firing on 2.0.19. Wired, not
  proven.
- Tool-name mapping across harnesses: `../references/harness-tools.md`.
