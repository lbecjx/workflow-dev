---
name: setup-models
description: Binds each workflow-dev agent role to a model the harness actually offers, so the mechanical sub-agents run on a fast model and the judgment ones on your strongest. Use when the user runs /workflow-dev:setup-models, asks to configure model tiering, or when a workflow-dev skill reports the roles are unmapped or stale.
---

<!--
workflow-dev — a persistent-context development workflow for Claude Code and OpenCode
Copyright (C) 2026  lbecjx

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version. See LICENSE for the full text.
-->

# Setup Models

Binds every role in `references/roles.md` to a model the user picks from what
their harness offers. The plugin names roles, never models — this skill is the
one place a role gets a model, and the binding lands in the user's own agent
config.

Read `references/roles.md` first. It is the sole definition of a role: its name,
class, hint, and the agent `description`/`body` written below. Renaming or
adding a role happens there, never here.

## What it writes

| Harness | File | Frontmatter |
|---|---|---|
| Claude Code | `~/.claude/agents/<role>.md` | `name`, `description`, `model` |
| OpenCode | `~/.config/opencode/agents/<role>.md` | `description`, `mode: subagent`, `model` |

Each body ends with one comment line, `<!-- workflow-dev:roles-hash <hash> -->`,
so a later run — or the reminder hook — can tell a current file from a stale
one. Take the hash from `"$PLUGIN_ROOT"/scripts/roles-hash.sh`; never recompute
it by hand. The hook compares against that same script, and two formulas for one
value drift apart (the failure `REPO.md` §4 records for the other markers).

It is a body comment, not a frontmatter field, on purpose: Claude Code silently
ignores a frontmatter key it doesn't recognize, and OpenCode passes unknown
agent options **through to the provider** as model options.

These files belong to the user. The plugin ships no `agents/` directory — a
plugin agent gets a namespaced name and cannot carry the user's model — so
nothing here travels with a plugin update. See "Re-running" below.

## Execution

### Step 0: Resolve the plugin root

`"$PLUGIN_ROOT"` is used throughout; resolve it once:

```sh
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd -P "<this skill's directory>/../.." && pwd -P)}"
```

Claude Code sets `CLAUDE_PLUGIN_ROOT`; OpenCode doesn't, so the fallback derives
the root from where this skill lives. The `-P` is load-bearing — OpenCode
installs skills as symlinks, and a logical `..` stops at the link instead of
resolving through it.

### Step 1: Learn the harness, and the models it offers

```sh
HARNESS="$("$PLUGIN_ROOT"/scripts/list-models.sh --print-harness)"
"$PLUGIN_ROOT"/scripts/list-models.sh
```

The second command prints one `provider<TAB>model` line per selectable model.
Its exit code is the honest signal for what to do next — ask once per run, not
once per role:

| Exit | Meaning | Go to |
|---|---|---|
| 0 | models listed | Step 2 |
| 1 | cannot be enumerated (its stderr says why) | "No model source" |
| 2 | Claude Code with no gateway configured | "No model source" |

### Step 2: Pick a model per role — provider first, then model

For each role in `references/roles.md`, in file order:

1. **Say what the role is for**, in one line, using its `hint` — "Runs the
   procedure — a fast model is enough". The user is choosing with intent, not
   guessing which of two names is cheaper.
2. **Provider step:** list the distinct providers (the first column) as a
   numbered menu.
3. **Model step:** list that provider's models as a numbered menu.

**Order each model list by the role's class**, and only from what the list
actually holds:

- `operator` → fastest / cheapest first.
- `judge` → most capable first.

Where the harness exposes per-model cost or capability in-session, sort by it.
Where it doesn't — Claude Code's gateway list carries ids only — keep the order
the script returned and let the `hint` carry the guidance. Never reorder on a
guess about a model you have no data for.

**Adapt to the picker's limits.** A harness picker takes a handful of options; a
provider can list hundreds of models. So:

- **Four options or fewer** → the harness's own picker is fine.
- **More than four** → print a numbered list in prose and ask for the number.
  Page it at roughly 40 entries, offering `n` for the next page, and accept a
  substring to filter (a vendor or a family name). Never print a hundreds-long
  wall and ask the user to find their model in it.

Every entry offered is one the script returned, or one the user types
themselves. Never add a model the script didn't list, and never a "recommended"
one.

**Keeping the default is always an option, and for `judge` roles it comes first.**
Offer "keep the default model" for every role: it writes `model: inherit` on
Claude Code, and on OpenCode it leaves the role without a `model:` line, so the
role runs on whatever the session runs on. Say why for `judge` roles — Security,
Architecture and the adversarial pair need strong reasoning, and a model that is
weaker than the default makes them worse, not cheaper. So when the user cannot
tell the offered models reason well, keeping the default is the safe pick;
tiering pays off for the `operator` roles first.

### Step 3: Write the agent file per role

With `HASH="$("$PLUGIN_ROOT"/scripts/roles-hash.sh)"` and the chosen model, write
the file for the detected harness, using the role's own `description` and `body`
from `references/roles.md` verbatim.

**Claude Code** — `~/.claude/agents/<role>.md`:

```markdown
---
name: <role>
description: <the role's description from roles.md>
model: <the chosen model>
---

<the role's body from roles.md>

<!-- workflow-dev:roles-hash <hash> -->
```

`model:` takes whatever Claude Code accepts in that field — an alias, a full
model ID, or `inherit` (see the model-config link under "No model source").
Leave `tools:` out — the role inherits the subagent tool pool, which is what it
ran with before.

**OpenCode** — `~/.config/opencode/agents/<role>.md` (the filename is the agent
name):

```markdown
---
description: <the role's description from roles.md>
mode: subagent
model: <provider/model-id>
---

<the role's body from roles.md>

<!-- workflow-dev:roles-hash <hash> -->
```

Create the target directory if it doesn't exist. On Claude Code, a new
`~/.claude/agents/` directory is only picked up after a restart when it wasn't
present at session start — say so if that is the case, so the user knows why the
agent isn't visible yet.

### Step 4: Confirm

Report each role, its file, and the model bound to it. Then state plainly what
this changes: the skills that spawn sub-agents now reference these roles, and
any harness that cannot select a model per sub-agent runs everything on the
default and says so rather than pretending otherwise.

There is no machine-wide way out of tiering, and this skill never offers one:
the agent files live in the user's own agents directory, so binding them is the
one global act, and keeping the default is chosen per repo or per story (see
"Keeping the default instead" below).

### Re-running

The skill is idempotent, and re-running is the normal way to refresh after a
plugin update changes `roles.md`:

- If a generated file already exists, read its current `model:` line and offer
  it as the default for that role — confirming keeps it, so a refresh never
  silently rebinds a model the user chose.
- Rewrite the description, the body, and the hash from the current `roles.md`,
  preserving the model.
- If every file is already current (hashes match), say so and skip writing.

## Keeping the default instead

When the user wants no tiering here, record it where the reminder hook reads it —
never for the whole machine:

- **This story:** add the row `| <today> | Tiering: default model | Human |` to the
  Decisions table of the active story's file in `.workflow-dev/context/`.
- **This repo:** set `"tiering": "default"` in `.workflow-dev/config.json`, keeping
  its other keys.

Write one of them only if the user chooses it.

## No model source

Neither path invents a model. When Step 1 exits 1 or 2, tell the user which it
is and let them choose:

- **Exit 1 — cannot be enumerated.** The script's stderr says why. Offer: (a)
  type a model id or alias by hand, or (b) keep the default for this story or this
  repo, recorded as in "Keeping the default instead".
- **Exit 2 — Claude Code without a gateway.** Ask them to run `/model` inside
  Claude Code, read the list it shows, and give the name or id they want (or a
  full model id). The plugin still names no model — they do. The model-config
  documentation is at
  <https://docs.claude.com/en/docs/claude-code/model-config>.

Either way, when no model gets bound, the workflow **runs everything on the
default model and says so** — the honest fallback WD-0007 AC 11 declared, never
a silent pretence that tiering happened.

## The Claude Code limit

Per-sub-agent models on Claude Code accept its own aliases and full model IDs.
Routing a sub-agent to a **non-Claude** model needs a router or gateway in front
of Claude Code, which is also the only route by which Step 1 can enumerate a
list there. Documented as a fallback, not a promise — OpenCode has no such limit
(any `provider/model` it offers is selectable).
