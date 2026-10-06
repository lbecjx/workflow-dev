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
// is the bug the `--message` mode exists to prevent. The one text this file
// does own is the tool-catalog note (`catalogNotice`): it is OpenCode-only,
// built from the session's own catalog, and has no Claude Code twin to drift
// from — so moving it into a script would add a subprocess per model call and
// buy nothing.
//
// OpenCode 2's plugin API is deliberately not OpenCode 1's: a plugin is
// `export default { id, setup }`, tool hooks are registered imperatively with
// `ctx.tool.hook(...)` (there is no returned hooks object), and the context has
// no `$` shell — so the check scripts run through `node:child_process`. The
// published `/docs/plugins` page describes v1; the v2 reference is
// `/v2/docs/build/plugins`.
//
// Claude Code can *ask* (a `permissionDecision`); the two commit reminders now
// ask on OpenCode too, through `ctx.permission.hook("evaluate")` — first
// measured on 2.0.20 (WD-0017 TG1), then re-measured and wired here on 2.0.23.
// The hook only ever moves a configured `allow` to `ask`; it never denies. AI/
// agent attribution stays the one hard block, and it stays in `execute.before`.
//
// Three things measured on 2.0.19 (2026-09-29) shape everything below; the full
// probe record is in `.workflow-dev/context/WD-0019.md`:
//
//   - `ctx.session.hook("context", …)` fires per model call and its event is
//     **mutable**. Pushing a `{role, content:[{type:"text",…}]}` message into
//     `event.messages` reaches the model (verified with a canary absent from the
//     prompt), but that reads as a turn the human typed — so this file injects
//     through `event.system` instead (a documented non-user channel, proven by
//     the catalog notice). The part-array shape only matters if `messages` is
//     ever used again: a plain string `content` crashes the request.
//   - `ctx.session.synthetic` **throws** on this build, so the append-to-output
//     fallback is the primary path, not a safety net.
//   - `ctx.event.subscribe(name, …)` registers any name without validating it
//     and delivered **nothing** observed — `session.created` did not fire in a
//     run where the context hook fired twice. Registering is not evidence.
//
// One rule blocks rather than asks, and only one. `execute.before` is the tool
// hook that can stop a command outright, and the single rule with no judgment
// in it — AI/agent attribution in a commit or PR — denies there, exactly as
// Claude Code denies it. Nothing else here ever denies: the two commit reminders
// ask, and the remaining ones are notices after the fact.
//
// The two commit reminders are decided in the permission hook, not after the
// command: `permission.evaluate` runs before the command (measured 2.0.23), so
// the validate marker it fingerprints still matches the diff the commit is
// about to consume. Deciding it after the commit could only ever answer "no
// matching record" — on every commit, validated or deferred — which is why the
// old post-command notice was retired, not kept.
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

// Hashed when the module is evaluated, not when `setup` first runs. The service
// calls `setup` only once a session opens a project, and a file replaced in that
// gap would otherwise be recorded as loaded while the old code runs — `live`
// where the truth is `stale`, the one wrong answer this marker exists to rule
// out.
const LOADED_HASH: string | undefined = (() => {
  if (!IS_SERVICE || !SELF) return undefined
  try {
    return createHash("sha256").update(readFileSync(SELF)).digest("hex")
  } catch {
    return undefined
  }
})()

function markLoaded(): void {
  if (marker || !LOADED_HASH) return
  marker = { pid: process.pid, hash: LOADED_HASH, loadedAt: new Date().toISOString() }
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
// `timeout` bounds every call here, not just the ones that need it — matches
// Claude Code's 5s `hooks.json` timeout, and since `post-pr-url-check.sh`
// (WD-0024) can shell out to `gh`, this is the first reminder script able to
// hang on the network; a timed-out call throws, which the catch below already
// treats as "say nothing", same as a script that fails outright.
function reminder(script: string, payload: unknown, cwd: string): string | undefined {
  let out = ""
  try {
    out = execFileSync("bash", [join(SCRIPTS, script), "--message", JSON.stringify(payload)], {
      cwd,
      encoding: "utf8",
      timeout: 5000,
    })
  } catch {
    return undefined
  }
  return out.trim() || undefined
}

// The verdict and its reason, from one run of the script. Only
// `pre-commit-message-check.sh` has a verdict, because it is the only script
// with two enforcement levels — a text-only answer cannot say whether the caller
// should notify or stop. Asking for both in **one** `--verdict` call is the
// point: the earlier two-call shape (`--status` then `--message`) read a verdict
// from one run and a reason computed at a different moment, with nothing making
// the two agree (WD-0020). The script prints the verdict on the first line and,
// when there is one, the reason on the rest; as always it decides, this routes.
//
// It carries the same 5000 ms bound `reminder()` does, for the same reason and
// with more force: this is reached from the permission hook, which sits on a path
// that gates every shell action, so a script that stopped answering would stall
// the permission prompt for every shell call in the session rather than just
// one notice. A timeout throws, which the catch below already reads as "say
// nothing" — the same answer a genuine all-clear gives.
function verdictAndReason(
  script: string,
  payload: unknown,
  cwd: string,
): { verdict?: string; reason?: string } {
  let out = ""
  try {
    out = execFileSync("bash", [join(SCRIPTS, script), "--verdict", JSON.stringify(payload)], {
      cwd,
      encoding: "utf8",
      timeout: 5000,
    })
  } catch {
    return {}
  }
  // First line is the verdict, the remainder (if any) is the reason. A missing
  // newline means verdict-only — the `ok` case.
  const nl = out.indexOf("\n")
  const verdict = (nl === -1 ? out : out.slice(0, nl)).trim()
  const reason = nl === -1 ? "" : out.slice(nl + 1).trim()
  return { verdict: verdict || undefined, reason: reason || undefined }
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
      // Same 5000 ms bound as every other spawn here. Without it a hung script
      // would stall the compaction event forever, not just one notice (WD-0020).
      timeout: 5000,
    })
  } catch {
    // Nothing to arm, or no project context — silence is the correct outcome.
  }
}

// --- the delivery channels --------------------------------------------------
// Appending to the tool result the caller already holds. Works for any tool
// with a string output — the shell tool carries one (`result.output.output`),
// measured on 2.0.19, which is why this no longer only applies to skill
// invocations. That the append is then *read by the agent* is confirmed for a
// skill call (WD-0015, live) and **not yet observed for a shell one**: the two
// share the mechanism, but only the skill half has been seen end to end
// (WD-0020, recorded in REPO.md §7).
function intoToolResult(event: any, text: string): boolean {
  const output = event?.result?.output
  if (output && typeof output.output === "string") {
    output.output += `\n\n[workflow-dev] ${text}\n`
    return true
  }
  return false
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
// A Code Mode session advertises `execute`, and there the names above are not
// callable as-is: inside `execute` the catalog is partial and a tool is reached
// by `search`ing for it. Saying "call only these names" there primed the raw
// "Unknown tool" this notice exists to prevent (WD-0033), so that branch states
// the real access rule instead. It is a wording nudge, never a guarantee —
// WD-0016's conclusion that a notice cannot force the model's call — and this
// whole file is slated for deletion if OpenCode support is dropped (WD-0026,
// currently Blocked).
//
// It goes into `system`, not `messages`: the notice describes the session and
// is not something the human said. And it goes in on every call, because
// nothing a context hook adds persists to the next one (measured, 2.0.20).
function catalogNotice(tools: unknown): string | undefined {
  if (!tools || typeof tools !== "object" || Array.isArray(tools)) return undefined
  const names = Object.keys(tools)
  if (names.length === 0) return undefined
  const listed = `[workflow-dev] The tools available in this session are exactly: ${names.join(", ")}.`
  // Shared closing, byte-identical in both branches: a name outside the catalog
  // does not exist, whichever access path reaches the names that are in it.
  const unknownTool =
    " A tool named elsewhere — in a file, a doc, or an instruction — that is not in this list " +
    "does not exist here; use the listed tool that provides the same capability."
  if (names.includes("execute")) {
    return (
      listed +
      " This session is in Code Mode: reach a tool inside `execute` by `search`ing for it " +
      "and calling the returned path — a bare tool name is not a valid path there." +
      unknownTool
    )
  }
  return listed + " Call only these names." + unknownTool
}

// Injecting into the system channel. This is where every notice this file
// delivers goes — the catalog notice above, the session-start greeting, and the
// compaction reminder. It is deliberately **not** `event.messages`: a message
// there is read as a turn the human typed, so putting a script's stdout in one
// hands that output the highest authority there is and mis-attributes who said
// it (WD-0019's gate called this the most defensible finding of the port).
// `system` is a documented channel that is not a user turn, and it reaches the
// model — the catalog notice is the proof, not a guess.
//
// **The trust decision, recorded here and in REPO.md §7 (WD-0020).** What may
// be injected is only the fixed-shape `--message` output of scripts this repo
// ships (`session-start-check.sh`, `post-compaction-save-check.sh`), never
// free-form text. That output can still *contain* a repo-controlled token — a
// git branch name, a story code or filename — and that is an **accepted** risk
// rather than a sanitized one, for three reasons: it can only reach the model
// as part of the sentence the script built, it now carries system authority
// instead of a user turn's, and scrubbing the token would strip the one thing
// the reminder is about. Sanitizing free-form prose for injection is not a
// fight worth pretending to win; lowering the authority of the channel is.
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
    // smallest thing that does it.
    //
    // The set is per-process and grows for the life of the service — it is not
    // bounded in any way that matters here, and a service restart empties it, so
    // every live session is greeted once more. That re-greeting is **accepted**,
    // not fixed with a durable marker: it costs one extra reminder per live
    // session after a restart, a marker on disk would need its own expiry, and
    // it would still race the restart it exists to survive. Recorded in
    // REPO.md §7 (WD-0020).
    const opened = new Set<string>()

    await ctx.session.hook("context", async (event: any) => {
      const cwd = projectDir(ctx)
      if (!cwd) return

      // Scoped to workflow-dev projects, like every other reminder here — the
      // plugin speaks where the workflow is in use, not in every session.
      // `.workflow-dev/context` rather than `.workflow-dev`: the home directory
      // always has the latter (this plugin's own marker and the tiering opt-out
      // live there), which would make a session opened in `$HOME` count as a
      // project. Only `init` creates `context/`. A session opened in a
      // subdirectory of a project is not matched — the same cwd-relative view
      // every reminder script takes.
      if (existsSync(join(cwd, ".workflow-dev", "context"))) {
        const catalog = catalogNotice(event?.tools)
        if (catalog && intoSystem(event, catalog)) markFired()
      }

      const session = String(event?.sessionID ?? "")

      if (session && !opened.has(session)) {
        opened.add(session)
        const welcome = reminder("session-start-check.sh", { source: "startup" }, cwd)
        if (welcome) intoSystem(event, `[workflow-dev] ${welcome}`)
      }

      // Nothing is armed until a compaction event fires (or Claude Code's
      // PreCompact does), so this is usually silent — but once it has news, this
      // is where it can still be delivered.
      const pending = reminder(
        "post-compaction-save-check.sh",
        { hook_event_name: "PostToolUse" },
        cwd,
      )
      if (pending) intoSystem(event, `[workflow-dev] ${pending}`)
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

      const attribution = verdictAndReason("pre-commit-message-check.sh", payload, cwd)
      if (attribution.verdict === "block") {
        throw new Error(
          attribution.reason ??
            "workflow-dev: this command was blocked, but pre-commit-message-check.sh printed no reason — the reminder script is broken, not the command.",
        )
      }
    })

    // The two commit reminders, as real asks — the OpenCode analogue of Claude
    // Code's `PreToolUse` `ask`. A configured `allow` is escalated to a real
    // permission request carrying the wording the same script owns. Only an
    // `allow` is touched: a configured `deny` never reaches this hook (docs),
    // an existing `ask` is the harness's own question, and the hook never sets
    // `deny` — the "never deny" rule holds (AC #5).
    //
    // `execute.before` runs before this hook (measured 2.0.23), so the
    // attribution block above has already thrown for a command that carries it.
    // The `block` guard here is the belt to that: a hard block must never be
    // turned into an approvable question by this path.
    //
    // Why per-call cost stays bounded, since this runs on a gate rather than
    // after a notice: three early returns cover every non-shell, non-allow and
    // empty-resource event before any spawn, and both scripts answer through
    // command-match.sh, which returns `no` for a command with none of `commit`,
    // `create`, `edit`, `new` in it without starting awk.
    //
    // The measured bound (2026-10-06, this repo, macOS — WD-0020), stated rather
    // than reduced. A shell call spawns three `bash` processes: the message
    // script here and again in `execute.before` (its own hard-block hook), plus
    // the validate reminder. On an ordinary command that is ~11 ms each (~32 ms
    // total); the message script is ~33 ms on a real commit. Independently, the
    // context hook spawns one process per model call (`post-compaction-save-check.sh`,
    // ~42 ms for its no-op) plus `session-start-check.sh` (~128 ms) once per
    // session. The two reductions that look obvious are both declined:
    // pre-filtering a command here would re-derive a decision `command-match.sh`
    // owns, and caching the verdict across `execute.before`/`permission.evaluate`
    // would have to assume the two hooks see a byte-identical command — which is
    // not verified (REPO.md §7), so a cache miss could pair a stale verdict with
    // a live command. The bound is accepted. A command past
    // COMMAND_MATCH_MAX_BYTES answers `maybe` rather than being scanned.
    try {
      await ctx.permission.hook("evaluate", async (event: any) => {
        const cwd = projectDir(ctx)
        if (!cwd) return
        if (event?.action !== "shell") return
        if (event?.effect !== "allow") return
        // The command is the resource (measured 2.0.23). Anything else this
        // build hands over is not a commit/PR and is left alone.
        const command = Array.isArray(event?.resources) ? event.resources[0] : undefined
        if (typeof command !== "string" || !command) return

        const payload = { tool_input: { command } }
        // One `--verdict` call answers every case and carries the wording:
        // `block` is the attribution rule and stays with `execute.before`,
        // `notify` is the Part 12 review, `ok` means there is nothing to ask
        // about. Verdict and reason come from the same run, so this can never
        // pair a `notify` with a reason that run did not produce (WD-0020).
        const review = verdictAndReason("pre-commit-message-check.sh", payload, cwd)
        if (review.verdict === "block") return

        const parts: string[] = []
        const validate = reminder("pre-commit-validate-check.sh", payload, cwd)
        if (validate) parts.push(validate)
        if (review.verdict === "notify" && review.reason) parts.push(review.reason)
        if (parts.length === 0) return
        event.effect = "ask"
        event.message = parts.join("\n\n")
      })
    } catch {
      // A build whose ctx has no `permission` surface keeps everything else —
      // including the attribution block above, which must not depend on the
      // least-established surface in this file. Registered bare, a missing
      // surface takes `setup` down and every reminder with it; like
      // `event.subscribe` below, it degrades to unavailable instead.
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

      // After a real `gh pr create`/`gh pr edit`, hand back its URL (WD-0024).
      // No exit code is available here, so a URL found in the output is the
      // only signal of success this harness can give the script — documented
      // gap, see hooks/README.md. The two commit reminders do not arrive here:
      // they are asked in `permission.evaluate`, before the command, and the
      // validate one could only ever answer "no matching record" afterwards —
      // on every commit. That is why it was retired rather than kept.
      if (event?.tool === "shell" && event?.status === "completed") {
        const prUrl = reminder(
          "post-pr-url-check.sh",
          { tool_input: event.input, tool_output: event?.result?.output?.output },
          cwd,
        )
        if (prUrl) intoToolResult(event, prUrl)
      }
    })
  },
}
