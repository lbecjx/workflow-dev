// workflow-dev — a persistent-context development workflow for Claude Code
// Copyright (C) 2026  lbecjx
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version. See LICENSE for the full text.
//
// OpenCode side of the model-tiering reminder.
//
// OpenCode 2's plugin API is deliberately not OpenCode 1's: a plugin is
// `export default { id, setup }`, tool hooks are registered imperatively with
// `ctx.tool.hook(...)` (there is no returned hooks object), and the context has
// no `$` shell — so the check script runs through `node:child_process`. The
// published `/docs/plugins` page describes v1; the v2 reference is
// `/v2/docs/build/plugins`.
//
// Claude Code can *ask* (a `permissionDecision`); OpenCode cannot — no
// permission-decision hook exists — so this posts a notice and lets the skill
// run, rather than breaking the repo's "never deny" rule to fake an ask. That
// difference is deliberate, and documented as a harness limit rather than
// presented as parity.
//
// Install by symlink. OpenCode loads direct `.ts`/`.js` files from
// `~/.config/opencode/plugins/`, but this plugin's own checkout sits one level
// below it (`~/.config/opencode/plugins/lbecjx/workflow-dev/`), so this file is
// not picked up on its own:
//
//   ln -s ~/.config/opencode/plugins/lbecjx/workflow-dev/opencode/plugin.ts \
//         ~/.config/opencode/plugins/workflow-dev.ts
//
// Which skills count, whether the roles are bound, and whether the user opted
// out are all decided by `scripts/model-tiering-check.sh --status` — the same
// script Claude Code's hooks call, so both harnesses share one definition of
// "set up" instead of two that can drift.

import { execFileSync } from "node:child_process"
import { join } from "node:path"

// `import.meta.dir` is Bun's (which is what OpenCode runs plugins on);
// `import.meta.dirname` is Node's, which is what can exercise this file's logic
// without Bun. Taking whichever exists keeps one implementation.
const HERE = import.meta.dir ?? import.meta.dirname ?? "."
const SCRIPT = join(HERE, "..", "scripts", "model-tiering-check.sh")

const NOT_SET_UP =
  "workflow-dev has no model tiering configured — run /workflow-dev:setup-models to bind each agent role to a model, or opt out in ~/.workflow-dev/tiering.json"
const STALE =
  "workflow-dev's agent roles are stale — re-run /workflow-dev:setup-models to refresh them (your chosen models are kept)"

// Ask the shared script; anything unexpected (no script, no harness) means say
// nothing rather than guess.
function noticeFor(payload: string): string | undefined {
  let status = ""
  try {
    status = execFileSync("bash", [SCRIPT, "--status", payload], { encoding: "utf8" }).trim()
  } catch {
    return undefined
  }
  if (status === "stale") return STALE
  if (status === "unmapped" || status === "incomplete") return NOT_SET_UP
  return undefined
}

export default {
  id: "workflow-dev",

  async setup(ctx: any) {
    // `execute.after` is the only hook that carries both what was invoked
    // (`input.id`) and a place to put the notice. `execute.before` can inspect
    // the call but cannot add anything to it.
    await ctx.tool.hook("execute.after", async (event: any) => {
      if (event?.tool !== "skill" || event?.status !== "completed") return
      const message = noticeFor(
        JSON.stringify({ tool_name: "skill", tool_input: event.input }),
      )
      if (!message) return

      // A synthetic message is what the user actually sees, so try that first.
      // If this OpenCode build won't take one, fall back to appending the
      // notice to the skill's own text — which at least reaches the agent
      // reading it, the same way Claude Code's context injection does.
      try {
        await ctx.session.synthetic({ sessionID: event.sessionID, text: message })
      } catch {
        const output = event.result?.output
        if (output && typeof output.output === "string") {
          output.output += `\n\n[workflow-dev] ${message}\n`
        }
      }
    })
  },
}
