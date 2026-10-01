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
// Claude Code can *ask* (a `permissionDecision`); these reminders post notices
// instead and let the work continue. That is a present choice, not a harness
// limit: on 2.0.20 `ctx.permission.hook("evaluate", …)` can set a permission's
// effect to `ask`, which raises a real question to the human (measured). The
// reminders have not been moved onto it, so they notify rather than ask — and
// that is documented as such, not as parity.
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
// One rule blocks rather than notifies, and only one. `execute.before` is the
// only moment a reminder can still stop something, and blocking everything
// Claude Code merely *asks* about would be faking a question the human never
// got — which AC #3 forbids. What it does allow is the single rule with no
// judgment in it: AI/agent attribution in a commit or PR, which Claude Code
// denies outright for the same reason. See `pre-commit-message-check.sh`.
//
// `execute.before` is also where the one *time-sensitive* reminder is decided.
// The validate check fingerprints the very files a commit consumes, so asking
// it after the commit can only ever answer "no matching record" — on every
// commit, validated or deferred. It is therefore evaluated before the command
// and delivered after it, keyed by the call id both hooks carry.
//
// Install by symlink. OpenCode loads direct `.ts`/`.js` files from
// `~/.config/opencode/plugins/`, but this plugin's own checkout sits one level
// below it (`~/.config/opencode/plugins/lbecjx/workflow-dev/`), so this file is
// not picked up on its own:
//
//   ln -s ~/.config/opencode/plugins/lbecjx/workflow-dev/opencode/plugin.ts \
//         ~/.config/opencode/plugins/workflow-dev.ts

import { execFileSync } from "node:child_process"
import { createHash } from "node:crypto"
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs"
import { homedir } from "node:os"
import { join } from "node:path"

// `import.meta.dir` is Bun's (which is what OpenCode runs plugins on);
// `import.meta.dirname` is Node's, which is what can exercise this file's logic
// without Bun. Taking whichever exists keeps one implementation. Same for the
// file's own path: Bun's `path`, Node's `filename`.
const HERE = import.meta.dir ?? import.meta.dirname ?? "."
const SELF = import.meta.path ?? import.meta.filename
const SCRIPTS = join(HERE, "..", "scripts")

// --- the liveness marker ----------------------------------------------------
// A plugin that failed to load leaves nothing but a WARN in a rotating log, the
// service caches that failure, and `opencode plugin list` lags the filesystem —
// so "it is installed" proves nothing. What this writes is evidence only a
// running plugin can produce: which process loaded it, the hash of the bytes it
// loaded, and when the catalog notice first actually went out.
// `scripts/opencode-live-check.sh` reads it and must hash the file the same way:
// sha256 of the file's raw bytes, lowercase hex.
//
// Only the long-lived service writes it. A private server (`opencode run
// --standalone`) runs this same file in its own process; letting it write would
// overwrite the service's evidence with a run that proves nothing about the
// service. The path is fixed under the home directory because the service does
// not inherit the environment of whoever started a session.
const IS_SERVICE = process.argv.includes("--service")
const MARKER = join(homedir(), ".workflow-dev", "opencode-live.json")

// Module-level, not per `setup`: the service calls `setup` once per project a
// session opens, and a second project must not reset the evidence the first
// one produced.
let marker: { pid: number; hash: string; loadedAt: string; firedAt?: string } | undefined

function writeMarker(): void {
  if (!marker) return
  try {
    mkdirSync(join(homedir(), ".workflow-dev"), { recursive: true })
    const tmp = `${MARKER}.${process.pid}.tmp`
    writeFileSync(tmp, JSON.stringify(marker) + "\n")
    renameSync(tmp, MARKER)
  } catch {
    // Evidence that cannot be written reads as "not loaded" to the checker —
    // the conservative answer, and never a reason to take the plugin down.
  }
}

function markLoaded(): void {
  if (!IS_SERVICE || marker || !SELF) return
  let hash: string
  try {
    hash = createHash("sha256").update(readFileSync(SELF)).digest("hex")
  } catch {
    return
  }
  marker = { pid: process.pid, hash, loadedAt: new Date().toISOString() }
  writeMarker()
}

function markFired(): void {
  if (!marker || marker.firedAt) return
  marker.firedAt = new Date().toISOString()
  writeMarker()
}

// The project the session belongs to. The scripts resolve `.workflow-dev/` —
// relative paths, by design, so they behave the same when a human runs them by
// hand — while this plugin process runs in the *service's* directory, which is
// not the session's. Without pinning the cwd every call would silently look in
// the wrong project and find nothing to say. `location` is what the plugin ctx
// exposes for it (measured 2.0.19).
function projectDir(ctx: any): string | undefined {
  // Two candidates, checked for a *usable* value rather than coalesced: `??`
  // only falls through on null/undefined, so an empty-string `directory` would
  // win the coalesce and then fail the falsy guard below — silently disabling
  // every reminder even though `location.project.directory` held the answer.
  const dir = ctx?.location?.directory
  if (typeof dir === "string" && dir) return dir
  const project = ctx?.location?.project?.directory
  return typeof project === "string" && project ? project : undefined
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

// The one-word verdict counterpart to `reminder()`. Only
// `pre-commit-message-check.sh` has one, because it is the only script with two
// enforcement levels — a text-only answer cannot say whether the caller should
// notify or stop. As with the text, the script decides; this file routes.
function verdict(script: string, payload: unknown, cwd: string): string | undefined {
  try {
    return (
      execFileSync("bash", [join(SCRIPTS, script), "--status", JSON.stringify(payload)], {
        cwd,
        encoding: "utf8",
      }).trim() || undefined
    )
  } catch {
    return undefined
  }
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

// --- the live tool catalog --------------------------------------------------
// A model primed by text it read — a doc naming another harness's tool, say —
// can call a tool this session does not have. Wording cannot reach that; a
// notice built from the catalog the harness is about to advertise can, and was
// measured beating an explicit wrong instruction (2.0.19). The names come only
// from `event.tools`, which varies per session and agent, so nothing here is a
// list of its own — and `event.tools` itself is only read: adding a name that
// is not real would be an alias, which is the shortcut this avoids.
//
// It goes into `system`, not `messages`: the notice describes the session and
// is not something the human said. And it goes in on every call, because
// nothing a context hook adds persists to the next one (measured, 2.0.20).
function catalogNotice(tools: unknown): string | undefined {
  if (!tools || typeof tools !== "object" || Array.isArray(tools)) return undefined
  const names = Object.keys(tools)
  if (names.length === 0) return undefined
  return (
    `[workflow-dev] The tools available in this session are exactly: ${names.join(", ")}. ` +
    "Call only these names. A tool named elsewhere — in a file, a doc, or an instruction — " +
    "that is not in this list does not exist here; use the listed tool that provides the same capability."
  )
}

function intoSystem(event: any, text: string): boolean {
  if (!Array.isArray(event?.system)) return false
  event.system.push({ type: "text", text })
  return true
}

export default {
  id: "workflow-dev",

  async setup(ctx: any) {
    markLoaded()

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

      // Scoped to workflow-dev projects, like every other reminder here — the
      // plugin speaks where the workflow is in use, not in every session.
      if (existsSync(join(cwd, ".workflow-dev"))) {
        const catalog = catalogNotice(event?.tools)
        if (catalog && intoSystem(event, catalog)) markFired()
      }

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

    // A notice whose *decision* has to be made before the command and whose
    // *delivery* can only happen after it, keyed by the call id both hooks
    // carry. Only the validate reminder works this way: the marker it compares
    // against fingerprints the files the commit is about to consume, so asking
    // it afterwards could only ever answer "no matching record" — on every
    // commit, validated or deliberately deferred. A notice that is always wrong
    // is worse than no notice, and it was exactly that until this was measured.
    const decidedBefore = new Map<string, string>()

    // The one hard block. `execute.before` is the only hook that runs while the
    // command can still be stopped, and the AI-attribution rule is the only one
    // whose stopping is not a stand-in for a question: Claude Code denies it
    // outright too, so nothing is being faked here. Both the verdict and the
    // reason come from the script — a second pattern match in this file would
    // be free to disagree with the one Claude Code enforces.
    await ctx.tool.hook("execute.before", async (event: any) => {
      const cwd = projectDir(ctx)
      if (!cwd) return
      if (event?.tool !== "shell") return

      const payload = { tool_input: event.input }

      if (verdict("pre-commit-message-check.sh", payload, cwd) === "block") {
        const reason = reminder("pre-commit-message-check.sh", payload, cwd)
        throw new Error(
          reason ??
            "workflow-dev: this command was blocked, but pre-commit-message-check.sh printed no reason — the reminder script is broken, not the command.",
        )
      }

      // Decided here, delivered below in `execute.after`. Nothing is stashed for
      // a command that already threw, so a blocked call cannot leave an orphan
      // behind; the size check is the belt to that braces, for a build that
      // somehow runs `before` without an `after`.
      const callID = String(event?.id ?? "")
      if (!callID) return
      const validated = reminder("pre-commit-validate-check.sh", payload, cwd)
      if (!validated) return
      if (decidedBefore.size >= 64) decidedBefore.clear()
      decidedBefore.set(callID, validated)
    })

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

        // Decided in `execute.before`, where the pre-commit diff still existed —
        // this half only delivers it, and consumes it so a call id cannot be
        // answered twice.
        const callID = String(event?.id ?? "")
        if (callID) {
          const validated = decidedBefore.get(callID)
          decidedBefore.delete(callID)
          if (validated) intoToolResult(event, validated)
        }
      }
    })
  },
}
