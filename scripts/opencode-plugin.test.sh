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
# plain JS, so it runs here under node against the real check script, with a
# stub plugin context that records what the plugin would have posted. Real
# OpenCode is still the only thing that can load the plugin and render a
# notice — this covers everything after a hook fires.
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
mkdir -p "$HOME_DIR"

cat > "$TMP/harness.ts" <<'HARNESS'
import { execFileSync } from "node:child_process"
import { mkdirSync, writeFileSync, rmSync, readFileSync } from "node:fs"
import { dirname, join } from "node:path"

const PLUGIN = process.env.PLUGIN_PATH!
const HOME_DIR = process.env.HOME_DIR!

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
const hooks: Record<string, (event: unknown) => Promise<void>> = {}
const posted: string[] = []
let syntheticThrows = false

const ctx = {
  tool: {
    hook: async (name: string, callback: (event: unknown) => Promise<void>) => {
      hooks[name] = callback
      return { dispose: async () => {} }
    },
  },
  session: {
    synthetic: async ({ text }: { text: string }) => {
      if (syntheticThrows) throw new Error("no synthetic messages here")
      posted.push(text)
    },
  },
}

const plugin = (await import(PLUGIN)).default
await plugin.setup(ctx)

check("setup registers execute.after", typeof hooks["execute.after"] === "function")

const skillCall = (id: string, output = "SKILL BODY") => ({
  tool: "skill",
  status: "completed",
  sessionID: "ses_test",
  input: { id },
  result: { output: { output } },
})
const fire = async (event: unknown) => hooks["execute.after"](event)

// 1: a tool that isn't the skill tool is ignored
await fire({ tool: "bash", status: "completed", input: { command: "ls" } })
check("non-skill tool → no notice", posted.length === 0)

// 2: our skill with nothing bound → a notice naming the fix
await fire(skillCall("workflow-dev-help"))
check("unmapped role → notice", posted.length === 1)
check("notice names setup-models", (posted[0] ?? "").includes("setup-models"))

// 3: someone else's skill is left alone
posted.length = 0
await fire(skillCall("other-plugin-thing"))
check("another plugin's skill → no notice", posted.length === 0)

// 4: opted out → silence
mkdirSync(`${HOME_DIR}/.workflow-dev`, { recursive: true })
writeFileSync(`${HOME_DIR}/.workflow-dev/tiering.json`, '{"optOut": true}')
await fire(skillCall("workflow-dev-help"))
check("opt-out → no notice", posted.length === 0)
rmSync(`${HOME_DIR}/.workflow-dev/tiering.json`)

// 5: every role bound, one carrying an older registry hash → says "stale"
const ROOT = join(dirname(PLUGIN), "..")
const HASH = execFileSync("bash", [join(ROOT, "scripts", "roles-hash.sh")], {
  encoding: "utf8",
}).trim()
const rolesMd = readFileSync(join(ROOT, "skills/setup-models/references/roles.md"), "utf8")
const roles = [...rolesMd.matchAll(/^### `([^`]+)`/gm)].map((m) => m[1])
mkdirSync(`${HOME_DIR}/.claude/agents`, { recursive: true })
for (const [i, role] of roles.entries()) {
  const hash = i === 0 ? "deadbeef" : HASH
  writeFileSync(
    `${HOME_DIR}/.claude/agents/${role}.md`,
    `---\nname: ${role}\n---\nbody\n\n<!-- workflow-dev:roles-hash ${hash} -->\n`,
  )
}
posted.length = 0
await fire(skillCall("workflow-dev-help"))
check("stale role → notice", posted.length === 1)
check("stale notice says stale", (posted[0] ?? "").toLowerCase().includes("stale"))

// 6: a build with no synthetic-message API still reaches the agent
posted.length = 0
syntheticThrows = true
const body = skillCall("workflow-dev-help")
await fire(body)
check("no synthetic API → notice appended to the skill text", body.result.output.output.includes("workflow-dev"))
check("no synthetic API → posted nothing", posted.length === 0)

console.log(`\n${pass} passed, ${fail} failed`)
process.exit(fail === 0 ? 0 : 1)
HARNESS

PLUGIN_PATH="$PLUGIN" HOME_DIR="$HOME_DIR" node "$TMP/harness.ts"
