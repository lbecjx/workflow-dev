<!--
workflow-dev — a persistent-context development workflow for Claude Code
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
- OpenCode's counterpart is the plugin `opencode/plugin.ts` (v2 API). A plugin
  can inspect a call, block it, or post a notice, and it can even answer a
  permission request (`ctx.permission.hook`/`reply` — measured on 2.0.19) — but
  it has no way to *raise* one, so the reminder there is a notice, not a question.
- Tool-name mapping across harnesses: `../references/harness-tools.md`.
