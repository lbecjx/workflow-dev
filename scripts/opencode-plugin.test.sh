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
import { mkdirSync, writeFileSync, rmSync, readFileSync } from "node:fs"
import { dirname, join } from "node:path"

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
const subscribed: string[] = []
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
    subscribe: async (name: string) => {
      subscribed.push(name)
      return { dispose: async () => {} }
    },
  },
}

const plugin = (await import(PLUGIN)).default
await plugin.setup(ctx)

// --- 1: setup registers everything the reminders need -----------------------
check("setup registers execute.after", typeof toolHooks["execute.after"] === "function")
check("setup registers session.hook('context')", typeof contextHook === "function")
check("setup subscribes the compaction events", subscribed.length === 2)

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
const shellCall = (command: string, output = "stdout\n") => ({
  tool: "shell", status: "completed", sessionID: "ses_test",
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
let shell = shellCall('git commit -m "feat: x"')
await fire(shell)
const shellOut = shell.result.output.output
check("a commit with no validate marker → the reminder is appended",
  shellOut.includes("[workflow-dev]") && /validated/i.test(shellOut))
check("...and the Part 12 review notice comes with it",
  /Git History Disclosure/.test(shellOut))

shell = shellCall("ls -la")
await fire(shell)
check("an ordinary shell command → nothing appended", shell.result.output.output === "stdout\n")

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

// --- 6: an armed compaction state is delivered on the context hook ----------
writeFileSync(`${PROJECT}/.workflow-dev/context/.compaction-state/WD-0001.json`,
  '{"current":"opencode","opencodeSession":"ses_a","opencodeSeq":1,"pendingSave":true}')
ev = await runContext(newContextEvent("ses_d"))
check("an armed compaction state → the save reminder is injected",
  /workflow-dev:save/.test(injected(ev)))
ev = await runContext(newContextEvent("ses_e"))
check("...and it clears, so it is not repeated", !/workflow-dev:save/.test(injected(ev)))

console.log(`\n${pass} passed, ${fail} failed`)
process.exit(fail === 0 ? 0 : 1)
HARNESS

PLUGIN_PATH="$PLUGIN" HOME_DIR="$HOME_DIR" PROJECT="$PROJECT" TMPDIR="$TMP/markers" node "$TMP/harness.ts"
