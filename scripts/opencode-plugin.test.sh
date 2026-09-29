#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Tests for opencode/plugin.ts. OpenCode loads that file on Bun, which doesn't
# have to be installed for its handler logic to be wrong — the logic is plain
# JS, so it runs here under node with a stub shell (`$`) that actually executes
# the same check script OpenCode would, and a stub SDK client that records
# toasts. Real OpenCode is still the only thing that can load the plugin; this
# covers everything after that.
#
#   bash scripts/opencode-plugin.test.sh
#
# Skips (exit 0) when node isn't available, since the plugin's own runtime is
# Bun and a missing node shouldn't read as a failure.

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

// Bun's shell is a tagged template; this reimplements just enough of it to run
// the real command, with each interpolated value single-quoted (the payload is
// JSON, so unquoted it would split on the shell).
const quote = (v: unknown) => "'" + String(v).replace(/'/g, "'\\''") + "'"
const $ = (strings: TemplateStringsArray, ...values: unknown[]) => {
  const cmd = strings.reduce(
    (acc, s, i) => acc + s + (i < values.length ? quote(values[i]) : ""),
    "",
  )
  return { text: async () => execFileSync("/bin/sh", ["-c", cmd], { encoding: "utf8" }) }
}

const toasts: string[] = []
const client = {
  tui: {
    showToast: async ({ body }: { body: { message: string } }) => {
      toasts.push(body.message)
    },
  },
}

let pass = 0
let fail = 0
const check = (label: string, condition: boolean) => {
  if (condition) { console.log("  ok   " + label); pass++ }
  else { console.log("  FAIL " + label); fail++ }
}

// This harness runs under node, but the script it calls detects the harness
// from the environment — pin it to Claude Code's signals so the check script
// looks at the agents dir this test controls.
delete process.env.OPENCODE
delete process.env.OPENCODE_TERMINAL
process.env.CLAUDECODE = "1"
process.env.HOME = HOME_DIR

const { WorkflowDevTiering } = await import(PLUGIN)
const hooks = await WorkflowDevTiering({ $, client })
const skillCall = (name: string) => ({ input: { tool: "skill" }, output: { args: { name } } })

// 1: a tool that isn't the skill tool is ignored
await hooks["tool.execute.before"]({ tool: "bash" }, { args: { command: "ls" } })
check("non-skill tool → no notice", toasts.length === 0)

// 2: our skill, nothing set up → a notice naming the fix
await hooks["tool.execute.before"](
  { tool: "skill" }, { args: { name: "workflow-dev-validate" } },
)
check("unmapped role → notice", toasts.length === 1)
check("notice names setup-models", (toasts[0] ?? "").includes("setup-models"))

// 3: someone else's skill is left alone
toasts.length = 0
await hooks["tool.execute.before"]({ tool: "skill" }, { args: { name: "other-plugin:thing" } })
check("another plugin's skill → no notice", toasts.length === 0)

// 4: opted out → silence
mkdirSync(`${HOME_DIR}/.workflow-dev`, { recursive: true })
writeFileSync(`${HOME_DIR}/.workflow-dev/tiering.json`, '{"optOut": true}')
await hooks["tool.execute.before"]({ tool: "skill" }, { args: { name: "workflow-dev-validate" } })
check("opt-out → no notice", toasts.length === 0)
rmSync(`${HOME_DIR}/.workflow-dev/tiering.json`)

// 5: a bound-but-stale role says so, in its own words
const ROOT = join(dirname(PLUGIN), "..")
const HASH = execFileSync("bash", [join(ROOT, "scripts", "roles-hash.sh")], {
  encoding: "utf8",
}).trim()
const rolesMd = readFileSync(join(ROOT, "skills/setup-models/references/roles.md"), "utf8")
const roles = [...rolesMd.matchAll(/^### `([^`]+)`/gm)].map((m) => m[1])
mkdirSync(`${HOME_DIR}/.claude/agents`, { recursive: true })
// every role bound, the first one carrying a hash from an older registry
for (const [i, role] of roles.entries()) {
  const hash = i === 0 ? "deadbeef" : HASH
  writeFileSync(
    `${HOME_DIR}/.claude/agents/${role}.md`,
    `---\nname: ${role}\n---\nbody\n\n<!-- workflow-dev:roles-hash ${hash} -->\n`,
  )
}
toasts.length = 0
await hooks["tool.execute.before"]({ tool: "skill" }, { args: { name: "workflow-dev-validate" } })
check("stale role → notice", toasts.length === 1)
check("stale notice says stale", (toasts[0] ?? "").toLowerCase().includes("stale"))

// 6: the typed-command path is covered too
toasts.length = 0
await hooks.event({ event: { type: "command.executed", properties: { name: "workflow-dev:save" } } })
check("typed command → notice", toasts.length === 1)

toasts.length = 0
await hooks.event({ event: { type: "command.executed", properties: { name: "something-else" } } })
check("unrelated command → no notice", toasts.length === 0)

console.log(`\n${pass} passed, ${fail} failed`)
process.exit(fail === 0 ? 0 : 1)
HARNESS

PLUGIN_PATH="$PLUGIN" HOME_DIR="$HOME_DIR" node "$TMP/harness.ts"
