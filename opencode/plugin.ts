// workflow-dev — a persistent-context development workflow for Claude Code
// Copyright (C) 2026  lbecjx
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version. See LICENSE for the full text.
//
// OpenCode side of workflow-dev's reminders.
//
// Claude Code gets these from `hooks/hooks.json`; OpenCode has no such file, so
// the same `scripts/*.sh` are called from here instead. **Nothing is
// reimplemented**: each script owns both its wording and its "is this
// warranted?" test, and this file only decides *when* to ask it and *where* the
// answer goes. That is why the plugin carries no reminder text at all — a
// second copy here is free to drift from the one Claude Code asks with, which
// is the bug the `--message` mode exists to prevent.
//
// OpenCode 2's plugin API is deliberately not OpenCode 1's: a plugin is
// `export default { id, setup }`, tool hooks are registered imperatively with
// `ctx.tool.hook(...)` (there is no returned hooks object), and the context has
// no `$` shell — so the check scripts run through `node:child_process`. The
// published `/docs/plugins` page describes v1; the v2 reference is
// `/v2/docs/build/plugins`.
//
// Claude Code can *ask* (a `permissionDecision`); OpenCode's plugin API has no
// method to *raise* a question to the human, so these post notices and let the
// work continue rather than breaking the repo's "never deny" rule to fake an
// ask. OpenCode does expose `ctx.permission.hook`/`reply` (measured on 2.0.19) —
// a plugin can observe and answer permission requests, so it could deny; what it
// cannot do is originate the question. The difference is deliberate, and
// documented as a harness limit rather than as parity.
//
// Three things measured on 2.0.19 (2026-09-29) shape everything below; the full
// probe record is in `.workflow-dev/context/WD-0019.md`:
//
//   - `ctx.session.hook("context", …)` fires per model call and its event is
//     **mutable** — pushing a `{role, content:[{type:"text",…}]}` message into
//     `event.messages` reaches the model (verified with a canary absent from the
//     prompt). The part-array shape is mandatory: a plain string `content`
//     crashes the request.
//   - `ctx.session.synthetic` **throws** on this build, so the append-to-output
//     fallback is the primary path, not a safety net.
//   - `ctx.event.subscribe(name, …)` registers any name without validating it
//     and delivered **nothing** observed — `session.created` did not fire in a
//     run where the context hook fired twice. Registering is not evidence.
//
// Install by symlink. OpenCode loads direct `.ts`/`.js` files from
// `~/.config/opencode/plugins/`, but this plugin's own checkout sits one level
// below it (`~/.config/opencode/plugins/lbecjx/workflow-dev/`), so this file is
// not picked up on its own:
//
//   ln -s ~/.config/opencode/plugins/lbecjx/workflow-dev/opencode/plugin.ts \
//         ~/.config/opencode/plugins/workflow-dev.ts

import { execFileSync } from "node:child_process"
import { join } from "node:path"

// `import.meta.dir` is Bun's (which is what OpenCode runs plugins on);
// `import.meta.dirname` is Node's, which is what can exercise this file's logic
// without Bun. Taking whichever exists keeps one implementation.
const HERE = import.meta.dir ?? import.meta.dirname ?? "."
const SCRIPTS = join(HERE, "..", "scripts")

// The project the session belongs to. The scripts resolve `.workflow-dev/` —
// relative paths, by design, so they behave the same when a human runs them by
// hand — while this plugin process runs in the *service's* directory, which is
// not the session's. Without pinning the cwd every call would silently look in
// the wrong project and find nothing to say. `location` is what the plugin ctx
// exposes for it (measured 2.0.19).
function projectDir(ctx: any): string | undefined {
  const dir = ctx?.location?.directory ?? ctx?.location?.project?.directory
  return typeof dir === "string" && dir ? dir : undefined
}

// Ask one script for its reminder, in the `--message` mode every reminder
// script now speaks: plain text back when there is something to raise, and
// nothing (exit 0, empty stdout) when there is not. `undefined` here always
// means "say nothing" — a script that cannot run, a payload it does not
// recognize, or a genuine all-clear: this file has no way to tell them apart
// and no business guessing.
function reminder(script: string, payload: unknown, cwd: string): string | undefined {
  let out = ""
  try {
    out = execFileSync("bash", [join(SCRIPTS, script), "--message", JSON.stringify(payload)], {
      cwd,
      encoding: "utf8",
    })
  } catch {
    return undefined
  }
  return out.trim() || undefined
}

// Arm the compaction state — the half that has no delivery of its own. On
// Claude Code `PreCompact` does this; on OpenCode the events that would stand in
// for it register but have never been observed firing (see the header), so this
// is called from whatever does fire and the arming side effect is the whole job.
function armCompaction(cwd: string): void {
  try {
    execFileSync("bash", [join(SCRIPTS, "pre-compact-check.sh"), "--arm", '{"harness":"opencode"}'], {
      cwd,
      encoding: "utf8",
    })
  } catch {
    // Nothing to arm, or no project context — silence is the correct outcome.
  }
}

// --- the two delivery channels ---------------------------------------------
// Appending to the tool result the caller already holds. Works for any tool
// with a string output — measured on the shell tool as well as on skills, which
// is why it no longer only applies to skill invocations.
function intoToolResult(event: any, text: string): boolean {
  const output = event?.result?.output
  if (output && typeof output.output === "string") {
    output.output += `\n\n[workflow-dev] ${text}\n`
    return true
  }
  return false
}

// Injecting into the model's own context, for the moments that have no tool
// result to append to (a session starting; a compaction warning). This is the
// only channel measured to reach the model, and it is why the reminders that
// Claude Code *asks* about are not simply lost here.
function intoModelContext(event: any, text: string): boolean {
  if (!Array.isArray(event?.messages)) return false
  event.messages.push({ role: "user", content: [{ type: "text", text: `[workflow-dev] ${text}` }] })
  return true
}

export default {
  id: "workflow-dev",

  async setup(ctx: any) {
    // Session ids whose opening reminder has already been sent. The context hook
    // fires on every model call, and Claude Code's own gate for this reminder
    // (`source == "startup"`) is a field its event has and OpenCode's does not —
    // so the "only once per session" half is this plugin's job, and a Set is the
    // smallest thing that does it. Bounded by the sessions one server process
    // sees; a restart re-opens every session at most once.
    const opened = new Set<string>()

    await ctx.session.hook("context", async (event: any) => {
      const cwd = projectDir(ctx)
      if (!cwd) return

      const session = String(event?.sessionID ?? "")

      if (session && !opened.has(session)) {
        opened.add(session)
        const welcome = reminder("session-start-check.sh", { source: "startup" }, cwd)
        if (welcome) intoModelContext(event, welcome)
      }

      // Nothing is armed until a compaction event fires (or Claude Code's
      // PreCompact does), so this is usually silent — but once it has news, this
      // is where it can still be delivered.
      const pending = reminder(
        "post-compaction-save-check.sh",
        { hook_event_name: "PostToolUse" },
        cwd,
      )
      if (pending) intoModelContext(event, pending)
    })

    // The compaction events. Registered because the alternative — assuming they
    // are dead on the strength of one name (`session.created`) failing to
    // deliver — would be an assumption, not a measurement. If they never fire,
    // nothing here was ever reached, which is the honest outcome to record
    // rather than to paper over.
    for (const name of ["session.compaction.started", "session.compacted"]) {
      try {
        await ctx.event.subscribe(name, async () => {
          const cwd = projectDir(ctx)
          if (cwd) armCompaction(cwd)
        })
      } catch {
        // A build that doesn't take this subscription: the reminder degrades to
        // unavailable rather than taking the plugin down with it.
      }
    }

    // `execute.after` is the only tool hook that carries both what was invoked
    // (`input`) and a place to put the notice. `execute.before` can inspect the
    // call but cannot add anything to it.
    await ctx.tool.hook("execute.after", async (event: any) => {
      const cwd = projectDir(ctx)
      if (!cwd) return

      // The tiering reminder: only a completed skill call, and only this
      // plugin's skills — the script decides which those are.
      if (event?.tool === "skill" && event?.status === "completed") {
        const tiering = reminder(
          "model-tiering-check.sh",
          { tool_name: "skill", tool_input: event.input },
          cwd,
        )
        if (tiering) {
          // A synthetic message is what the user actually sees, so try that
          // first. If this OpenCode build won't take one — and on 2.0.19 it
          // won't, it throws — fall back to appending the notice to the call's
          // own output, which reaches the agent reading it.
          try {
            await ctx.session.synthetic({ sessionID: event.sessionID, text: tiering })
          } catch {
            intoToolResult(event, tiering)
          }
        }
        return
      }

      // The pre-commit reminders. Claude Code fires these *before* the command
      // and can ask; here the command has already run, so what arrives is a
      // notice that the moment has passed — a warning, not a gate. Saying so is
      // the honest shape (AC #2), and both scripts exit immediately for anything
      // that is not a commit or PR, so this costs nothing on ordinary calls.
      if (event?.tool === "shell" && event?.status === "completed") {
        const review = reminder(
          "pre-commit-message-check.sh",
          { tool_input: event.input },
          cwd,
        )
        if (review) intoToolResult(event, review)

        const validated = reminder(
          "pre-commit-validate-check.sh",
          { tool_input: event.input },
          cwd,
        )
        if (validated) intoToolResult(event, validated)
      }
    })
  },
}
