#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Tests for opencode/plugin.ts. OpenCode loads that file on Bun; its logic is
# plain JS, so it runs here under node against the real check scripts, with a
# stub plugin context that records what the plugin would have delivered.
#
# The stub mimics the three surfaces measured on OpenCode 2.0.19 (see
# `.workflow-dev/context/WD-0019.md`): `tool.hook("execute.after")`,
# `session.hook("context")` with a **mutable** `messages` array, and
# `event.subscribe`. Real OpenCode is still the only thing that can load the
# plugin, fire a real session and render a notice — this covers everything after
# a hook fires, including which of the shared scripts the plugin asks and where
# the answer goes.
#
#   bash scripts/opencode-plugin.test.sh
#
# Skips (exit 0) when node isn't available, since the plugin's own runtime is
# OpenCode's Bun and a missing node shouldn't read as a failure.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN="$HERE/../opencode/plugin.ts"

if ! command -v node >/dev/null 2>&1; then
  echo "  skip  node isn't installed — plugin.ts logic not exercised"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
HOME_DIR="$TMP/home"
PROJECT="$TMP/project"
mkdir -p "$HOME_DIR" "$PROJECT/.workflow-dev/context" "$PROJECT/.workflow-dev/context/.compaction-state"

# A real git repo with a workflow-dev project in it: the pre-commit scripts key
# off both, and a project that had neither would make every case pass for the
# wrong reason.
( cd "$PROJECT" \
  && git init -q . \
  && git config user.email t@example.com \
  && git config user.name t \
  && printf 'one\n' > tracked.txt \
  && git add tracked.txt \
  && git commit -qm "chore: seed" \
  && printf 'one\ntwo\n' > tracked.txt ) >/dev/null 2>&1

printf '# WD-0001\n\n### Implementation Status: In Progress\n' > "$PROJECT/.workflow-dev/context/WD-0001.md"

cat > "$TMP/harness.ts" <<'HARNESS'
import { execFileSync } from "node:child_process"
import { createHash } from "node:crypto"
import { existsSync, mkdirSync, writeFileSync, rmSync, readFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { pathToFileURL } from "node:url"

const PLUGIN = process.env.PLUGIN_PATH!
const HOME_DIR = process.env.HOME_DIR!
const PROJECT = process.env.PROJECT!

// This harness runs under node, but the script the plugin calls detects the
// harness from the environment — pin it to Claude Code's signals so the check
// script looks at the agents dir this test controls.
delete process.env.OPENCODE
delete process.env.OPENCODE_TERMINAL
process.env.CLAUDECODE = "1"
process.env.HOME = HOME_DIR

let pass = 0
let fail = 0
const check = (label: string, condition: boolean) => {
  if (condition) { console.log("  ok   " + label); pass++ }
  else { console.log("  FAIL " + label); fail++ }
}

// --- a stub OpenCode plugin context ----------------------------------------
const toolHooks: Record<string, (event: any) => Promise<void>> = {}
const subscribed: Record<string, (() => Promise<void>) | undefined> = {}
const posted: string[] = []
let contextHook: ((event: any) => Promise<void>) | undefined
let syntheticThrows = false

const ctx = {
  // The project the session belongs to — the scripts resolve `.workflow-dev/`
  // relative to this, and the plugin must pass it as the child process's cwd.
  location: { directory: PROJECT },
  tool: {
    hook: async (name: string, callback: (event: any) => Promise<void>) => {
      toolHooks[name] = callback
      return { dispose: async () => {} }
    },
  },
  session: {
    hook: async (name: string, callback: (event: any) => Promise<void>) => {
      if (name === "context") contextHook = callback
      return { dispose: async () => {} }
    },
    synthetic: async ({ text }: { text: string }) => {
      if (syntheticThrows) throw new Error("no synthetic messages here")
      posted.push(text)
    },
  },
  event: {
    // The callback is kept, not just the name: asserting that two subscriptions
    // were *registered* says nothing about whether the arming path they exist
    // for is reachable. Nothing else in this harness triggers it.
    subscribe: async (name: string, callback: () => Promise<void>) => {
      subscribed[name] = callback
      return { dispose: async () => {} }
    },
  },
}

const plugin = (await import(PLUGIN)).default
await plugin.setup(ctx)

// --- 1: setup registers everything the reminders need -----------------------
check("setup registers execute.after", typeof toolHooks["execute.after"] === "function")
check("setup registers execute.before", typeof toolHooks["execute.before"] === "function")
check("setup registers session.hook('context')", typeof contextHook === "function")
check("setup subscribes the compaction events", Object.keys(subscribed).length === 2)

// --- helpers ---------------------------------------------------------------
const newContextEvent = (sessionID: string) => ({
  sessionID,
  model: "stub",
  system: [],
  messages: [] as any[],
  options: {},
  agent: "build",
  tools: [],
})
const runContext = async (event: any) => { await contextHook!(event); return event }
const injected = (event: any): string =>
  (event.messages ?? []).map((m: any) => m.content?.[0]?.text ?? "").join("\n")
const fire = async (event: unknown) => toolHooks["execute.after"](event)
const skillCall = (id: string, output = "SKILL BODY") => ({
  tool: "skill", status: "completed", sessionID: "ses_test",
  input: { id }, result: { output: { output } },
})
const shellCall = (command: string, output = "stdout\n", id = "call_shell") => ({
  tool: "shell", status: "completed", sessionID: "ses_test", id,
  input: { command }, result: { output: { output } },
})

// --- 2: the session-start reminder reaches the model, once per session ------
let ev = await runContext(newContextEvent("ses_a"))
check("session start → a notice is injected into the model's context",
  injected(ev).includes("workflow-dev"))
const firstGreeting = injected(ev)
check("the greeting names a skill to run next", /workflow-dev:(resume|plan)/.test(firstGreeting))

ev = await runContext(newContextEvent("ses_a"))
check("the same session is not greeted twice", injected(ev) === "")

ev = await runContext(newContextEvent("ses_b"))
check("a different session gets its own greeting", injected(ev).includes("workflow-dev"))

// The injected message must be the part-array shape: a plain string `content`
// crashes a real request (measured), so a regression here is not cosmetic.
ev = await runContext(newContextEvent("ses_c"))
const parts = (ev.messages as any[])[0]
check("the injected message uses the part-array shape",
  Array.isArray(parts?.content) && parts.content[0]?.type === "text")

// --- 3: the shell path — a commit gets the pre-commit notices ---------------
// The regression this pins first: `execute.after` on its own must say nothing
// about validate. The marker that reminder compares against fingerprints the
// files the commit is about to consume, so asking it once the command has run
// answers "no matching record" for *every* commit — validated, deferred, or
// not. Delivering that is a notice that is always wrong, which is what this
// used to do; it trains people to ignore notices, and it is worse than parity.
const afterOnly = shellCall('git commit -m "feat: x"', "stdout\n", "call_after_only")
await fire(afterOnly)
check("execute.after alone never claims validate is missing",
  !/validated/i.test(afterOnly.result.output.output))

// Decided before the command (where the diff still exists), delivered after it,
// paired by the call id both hooks carry.
await toolHooks["execute.before"](shellCall('git commit -m "feat: x"', "stdout\n", "call_full"))
const committed = shellCall('git commit -m "feat: x"', "stdout\n", "call_full")
await fire(committed)
const shellOut = committed.result.output.output
check("a commit with no validate marker → the reminder is appended",
  shellOut.includes("[workflow-dev]") && /validated/i.test(shellOut))
check("...and the Part 12 review notice comes with it",
  /Git History Disclosure/.test(shellOut))

const repeated = shellCall('git commit -m "feat: x"', "stdout\n", "call_full")
await fire(repeated)
check("...and it is consumed, so a second after-hook for that id is silent",
  !/validated/i.test(repeated.result.output.output))

const ordinary = shellCall("ls -la")
await toolHooks["execute.before"](ordinary)
await fire(ordinary)
check("an ordinary shell command → nothing appended", ordinary.result.output.output === "stdout\n")

// WD-0024: a real gh pr create hands back its URL; a mention of one does not.
const prCreate = shellCall(
  'gh pr create --title "T" --body "B"',
  "Creating pull request...\nhttps://github.com/lbecjx/workflow-dev/pull/44",
  "call_pr_create",
)
await toolHooks["execute.before"](prCreate)
await fire(prCreate)
check("a real gh pr create → its URL is appended",
  prCreate.result.output.output.includes("https://github.com/lbecjx/workflow-dev/pull/44"))

const prMention = shellCall(
  'echo "later this will run gh pr create"',
  "later this will run gh pr create\n",
  "call_pr_mention",
)
await toolHooks["execute.before"](prMention)
await fire(prMention)
check("a mention of gh pr create → no URL appended",
  !/pull\/\d+/.test(prMention.result.output.output))

// A command that only *mentions* a commit/PR is data: the matcher lives in the
// shared scripts, so this path must say nothing for it either — and still ask
// for a real commit written in a form a substring match would have missed.
const mentioned = shellCall('echo "run git commit, then gh pr create"', "stdout\n", "call_mention")
await toolHooks["execute.before"](mentioned)
await fire(mentioned)
check("a command that only mentions a commit → nothing appended",
  mentioned.result.output.output === "stdout\n")

const docWrite = shellCall("cat > notes.md <<'EOF'\nthen run git commit\nEOF", "stdout\n", "call_doc")
await toolHooks["execute.before"](docWrite)
await fire(docWrite)
check("a heredoc that writes about a commit → nothing appended",
  docWrite.result.output.output === "stdout\n")

const withDir = shellCall('git -C ../other commit -m "feat: x"', "stdout\n", "call_dir")
await toolHooks["execute.before"](withDir)
await fire(withDir)
check("a real `git -C <dir> commit` → still gets the reminders",
  /validated/i.test(withDir.result.output.output) && /Git History Disclosure/.test(withDir.result.output.output))

// --- 4: skills — the tiering reminder, unchanged ---------------------------
posted.length = 0
await fire(skillCall("workflow-dev-help"))
check("unmapped role → notice", posted.length === 1)
check("notice names setup-models", (posted[0] ?? "").includes("setup-models"))

posted.length = 0
await fire(skillCall("other-plugin-thing"))
check("another plugin's skill → no notice", posted.length === 0)

posted.length = 0
await fire({ tool: "bash", status: "completed", input: { command: "ls" } })
check("an unknown tool name is ignored", posted.length === 0)

mkdirSync(`${HOME_DIR}/.workflow-dev`, { recursive: true })
writeFileSync(`${HOME_DIR}/.workflow-dev/tiering.json`, '{"optOut": true}')
posted.length = 0
await fire(skillCall("workflow-dev-help"))
check("opt-out → no notice", posted.length === 0)
rmSync(`${HOME_DIR}/.workflow-dev/tiering.json`)

const ROOT = join(dirname(PLUGIN), "..")
const HASH = execFileSync("bash", [join(ROOT, "scripts", "roles-hash.sh")], { encoding: "utf8" }).trim()
const rolesMd = readFileSync(join(ROOT, "skills/setup-models/references/roles.md"), "utf8")
const roles = [...rolesMd.matchAll(/^### `([^`]+)`/gm)].map((m) => m[1])
mkdirSync(`${HOME_DIR}/.claude/agents`, { recursive: true })
for (const [i, role] of roles.entries()) {
  writeFileSync(`${HOME_DIR}/.claude/agents/${role}.md`,
    `---\nname: ${role}\n---\nbody\n\n<!-- workflow-dev:roles-hash ${i === 0 ? "deadbeef" : HASH} -->\n`)
}
posted.length = 0
await fire(skillCall("workflow-dev-help"))
check("stale role → notice", posted.length === 1)
check("stale notice says stale", (posted[0] ?? "").toLowerCase().includes("stale"))

posted.length = 0
syntheticThrows = true
const body = skillCall("workflow-dev-help")
await fire(body)
check("no synthetic API → notice appended to the skill text",
  body.result.output.output.includes("workflow-dev"))
check("no synthetic API → posted nothing", posted.length === 0)
syntheticThrows = false

// --- 5: attribution is reported on this path too (blocking is a later group) -
const pr = shellCall('gh pr create --title "T" --body "Co-Authored-By: Claude <n@anthropic.com>"')
await fire(pr)
check("AI attribution → the reason is surfaced to the agent",
  /Part 12\.3/.test(pr.result.output.output))

// --- 6: the one hard block --------------------------------------------------
const attempt = async (event: any) => {
  try { await toolHooks["execute.before"](event); return undefined }
  catch (e: any) { return e?.message ?? String(e) }
}

let blocked = await attempt(shellCall('git commit -m "feat: x\n\nCo-Authored-By: Claude <n@anthropic.com>"'))
check("AI attribution → the command is blocked", typeof blocked === "string" && /Part 12\.3/.test(blocked!))

blocked = await attempt(shellCall('git commit -m "feat: a clean unreviewed change"'))
check("a clean but unreviewed commit is NOT blocked (it is an ask on Claude Code)",
  blocked === undefined)

blocked = await attempt(shellCall("ls -la"))
check("a non-commit command is never blocked", blocked === undefined)

// The false deny that motivated the shared matcher: a doc-writing heredoc that
// mentions a commit and carries attribution text as a fixture is data.
blocked = await attempt(shellCall("cat > notes.md <<'EOF'\nExample: git commit -m x\nCo-Authored-By: Claude <n@anthropic.com>\nEOF"))
check("a mention plus an attribution fixture is NOT blocked", blocked === undefined)

blocked = await attempt(shellCall('git -C ../other commit -m "x\n\nCo-Authored-By: Claude <n@anthropic.com>"'))
check("a real `git -C <dir> commit` with attribution is still blocked",
  typeof blocked === "string" && /Part 12\.3/.test(blocked!))

blocked = await attempt(shellCall('bash -c "git commit -m x\nCo-Authored-By: Claude <n@anthropic.com>"'))
check("an ambiguous wrapped commit with attribution is NOT blocked (it asks)", blocked === undefined)

blocked = await attempt({ tool: "skill", status: "completed", sessionID: "ses_test", input: { id: "workflow-dev-help" } })
check("a non-shell tool is never blocked", blocked === undefined)

// A blocked call never reaches the validate stash, so its id cannot later
// deliver a notice for a command that never ran.
const blockedCall = shellCall('git commit -m "x\n\nCo-Authored-By: Claude <n@anthropic.com>"', "stdout\n", "call_blocked")
await attempt(blockedCall)
await fire(blockedCall)
check("a blocked call leaves no validate notice behind",
  !/validated/i.test(blockedCall.result.output.output))

// --- 7: an armed compaction state is delivered on the context hook ----------
writeFileSync(`${PROJECT}/.workflow-dev/context/.compaction-state/WD-0001.json`,
  '{"current":"opencode","opencodeSession":"ses_a","opencodeSeq":1,"pendingSave":true}')
ev = await runContext(newContextEvent("ses_d"))
check("an armed compaction state → the save reminder is injected",
  /workflow-dev:save/.test(injected(ev)))
ev = await runContext(newContextEvent("ses_e"))
check("...and it clears, so it is not repeated", !/workflow-dev:save/.test(injected(ev)))

// --- 8: firing a compaction event actually arms the state -------------------
// The only path that ever calls `pre-compact-check.sh --arm`, and the one the
// stub used to make unreachable by discarding the callback.
const STATE = `${PROJECT}/.workflow-dev/context/.compaction-state/WD-0001.json`
writeFileSync(STATE, '{"current":"opencode","opencodeSession":"ses_x","opencodeSeq":7,"pendingSave":false}')
check("the compaction event callback was registered", typeof subscribed["session.compacted"] === "function")
await subscribed["session.compacted"]!()
check("firing a compaction event arms pendingSave",
  readFileSync(STATE, "utf8").includes('"pendingSave":true'))
check("...while the save flow's session fields survive it",
  readFileSync(STATE, "utf8").includes('"opencodeSession":"ses_x"') &&
  readFileSync(STATE, "utf8").includes('"opencodeSeq":7'))

// --- 9: the live-catalog notice ---------------------------------------------
// `tools` is a record keyed by tool name (measured, 2.0.20). The notice may name
// only those keys, must leave the record itself untouched — adding a name that
// is not real is the rejected alias — and must be re-sent on every call, since
// nothing a context hook adds survives to the next one.
const catalogEvent = (sessionID: string, tools: unknown) => ({ ...newContextEvent(sessionID), tools })
const systemText = (event: any): string =>
  (event.system ?? []).map((p: any) => p?.text ?? "").join("\n")
const liveTools = {
  read: { description: "d", input: {} },
  shell: { description: "d", input: {} },
  question: { description: "d", input: {} },
}
const toolsBefore = JSON.stringify(liveTools)

ev = await runContext(catalogEvent("ses_cat", liveTools))
const notice = systemText(ev)
check("catalog → a notice is added to system", notice.includes("[workflow-dev]"))
check("...naming exactly the event's tools", /exactly: read, shell, question\./.test(notice))
check("...and no tool the event did not carry", !/\b(edit|write|glob|grep|patch)\b/.test(notice))
check("...without touching the advertised catalog", JSON.stringify(ev.tools) === toolsBefore)
check("...and not as a message, which would read as the human's",
  !injected(ev).includes("available in this session"))

ev = await runContext(catalogEvent("ses_cat", liveTools))
check("the same session gets it again on the next call", systemText(ev).includes("exactly: read, shell, question."))

const otherTools = { patch: { description: "d", input: {} }, shell: { description: "d", input: {} } }
ev = await runContext(catalogEvent("ses_cat2", otherTools))
check("a different catalog → the notice follows it", /exactly: patch, shell\./.test(systemText(ev)))

for (const [label, tools] of [
  ["missing", undefined],
  ["empty", {}],
  ["an array", ["shell"]],
  ["null", null],
] as const) {
  ev = await runContext(catalogEvent("ses_cat_" + label, tools))
  check(`tools ${label} → no catalog notice`, !systemText(ev).includes("available in this session"))
}

const PLAIN = join(dirname(PROJECT), "plain")
mkdirSync(PLAIN, { recursive: true })
ctx.location.directory = PLAIN
ev = await runContext(catalogEvent("ses_plain", liveTools))
check("a project without .workflow-dev/ → no catalog notice", systemText(ev) === "")
ctx.location.directory = PROJECT

// --- 10: the liveness marker ------------------------------------------------
// Everything above ran as a non-service process (no `--service` in argv), which
// is what a private `opencode run` server is — so it must have left no marker.
const LIVE = `${HOME_DIR}/.workflow-dev/opencode-live.json`
check("a non-service process writes no liveness marker", !existsSync(LIVE))

// A second module instance (a fresh URL defeats the module cache) that sees
// itself running as the service, with its own stub context.
process.argv.push("--service")
const service = (await import(pathToFileURL(PLUGIN).href + "?service")).default
let serviceContext: ((event: any) => Promise<void>) | undefined
const serviceCtx = {
  location: { directory: PLAIN },
  tool: { hook: async () => ({ dispose: async () => {} }) },
  session: {
    hook: async (name: string, cb: (event: any) => Promise<void>) => {
      if (name === "context") serviceContext = cb
      return { dispose: async () => {} }
    },
    synthetic: async () => {},
  },
  event: { subscribe: async () => ({ dispose: async () => {} }) },
}
await service.setup(serviceCtx)
const readLive = () => JSON.parse(readFileSync(LIVE, "utf8"))
const pluginHash = createHash("sha256").update(readFileSync(PLUGIN)).digest("hex")
check("the service writes a marker on load", existsSync(LIVE))
check("...with its own pid", readLive().pid === process.pid)
check("...and the sha256 of the bytes it loaded", readLive().hash === pluginHash)
check("...and nothing claiming it fired yet", readLive().firedAt === undefined)

await serviceContext!(catalogEvent("ses_live_plain", liveTools))
check("a context call outside a workflow-dev project does not count as firing",
  readLive().firedAt === undefined)

serviceCtx.location.directory = PROJECT
await serviceContext!(catalogEvent("ses_live", liveTools))
const firstFired = readLive().firedAt
check("the notice actually going out records firedAt", typeof firstFired === "string")

await serviceContext!(catalogEvent("ses_live", {}))
await service.setup(serviceCtx)
check("a later setup (another project) keeps the evidence",
  readLive().firedAt === firstFired && readLive().hash === pluginHash)

await new Promise((r) => setTimeout(r, 5))
await serviceContext!(catalogEvent("ses_live", liveTools))
check("the notice going out again does not move firedAt", readLive().firedAt === firstFired)

// `$HOME/.workflow-dev` always exists — the marker itself lives there — so it
// cannot be what makes a directory a workflow-dev project.
serviceCtx.location.directory = HOME_DIR
ev = catalogEvent("ses_home", liveTools)
await serviceContext!(ev)
check("a session opened in $HOME (which has .workflow-dev/) → no catalog notice",
  !systemText(ev).includes("available in this session"))
ctx.location.directory = HOME_DIR
ev = await runContext(catalogEvent("ses_home2", liveTools))
check("...from the main instance either", !systemText(ev).includes("available in this session"))
ctx.location.directory = PROJECT

// The hash is of the bytes evaluated, not of whatever is on disk by the time
// `setup` first runs: the service only calls `setup` once a session opens a
// project, and a file replaced in that gap must read as stale, not live.
rmSync(LIVE)
const COPY = join(dirname(PROJECT), "copy", "plugin.ts")
mkdirSync(dirname(COPY), { recursive: true })
writeFileSync(COPY, readFileSync(PLUGIN))
const copyHash = createHash("sha256").update(readFileSync(COPY)).digest("hex")
const copied = (await import(pathToFileURL(COPY).href + "?late-setup")).default
writeFileSync(COPY, readFileSync(PLUGIN, "utf8") + "\n// replaced after import\n")
await copied.setup(serviceCtx)
check("a file replaced between import and setup → the marker keeps the evaluated bytes' hash",
  readLive().hash === copyHash)
process.argv.pop()

console.log(`\n${pass} passed, ${fail} failed`)
process.exit(fail === 0 ? 0 : 1)
HARNESS

PLUGIN_PATH="$PLUGIN" HOME_DIR="$HOME_DIR" PROJECT="$PROJECT" TMPDIR="$TMP/markers" node "$TMP/harness.ts"
