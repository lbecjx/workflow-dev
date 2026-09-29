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
// Claude Code can *ask* (a `permissionDecision`); OpenCode cannot — its
// `tool.execute.before` may only rewrite arguments or throw to block, and no
// permission-decision hook exists. So this shows a notice and lets the skill
// run, rather than breaking the repo's "never deny" rule to fake an ask. That
// difference is deliberate, and documented as a harness limit rather than
// presented as parity.
//
// Install by symlink. OpenCode auto-loads plugins from
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

import { join } from "node:path"

// `import.meta.dir` is Bun's (what OpenCode runs plugins on); `import.meta.dirname`
// is Node's, which is what can exercise this file's logic without Bun. Taking
// whichever exists keeps one implementation, not a test-only copy.
const HERE = import.meta.dir ?? import.meta.dirname ?? "."
const SCRIPT = join(HERE, "..", "scripts", "model-tiering-check.sh")

const NOT_SET_UP =
  "workflow-dev has no model tiering configured — run /workflow-dev:setup-models to bind each agent role to a model, or opt out in ~/.workflow-dev/tiering.json"
const STALE =
  "workflow-dev's agent roles are stale — re-run /workflow-dev:setup-models to refresh them (your chosen models are kept)"

export const WorkflowDevTiering = async ({ $, client }) => {
  const remind = async (payload: string) => {
    const status = (await $`bash ${SCRIPT} --status ${payload}`.text()).trim()
    if (status !== "unmapped" && status !== "stale" && status !== "incomplete") return
    await client.tui.showToast({
      body: {
        message: status === "stale" ? STALE : NOT_SET_UP,
        variant: "warning",
      },
    })
  }

  return {
    // The agent invoking a workflow-dev skill. `skill` is the tool name the
    // `skill` permission key gates; the script does the finer matching.
    "tool.execute.before": async (input, output) => {
      if (!/^skill$/i.test(input.tool ?? "")) return
      await remind(JSON.stringify({ tool_name: input.tool, tool_input: output.args }))
    },

    // The user typing `/workflow-dev:<skill>` directly, which never reaches a
    // tool call. The event's own field names aren't pinned down anywhere, so
    // this matches on the serialized event rather than guessing at a property
    // that may not exist.
    event: async ({ event }) => {
      if (event?.type !== "command.executed") return
      const serialized = JSON.stringify(event)
      if (!serialized.includes("workflow-dev")) return
      await remind(serialized)
    },
  }
}
