#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Tests for validate's selection rule (skills/validate/references/selection.md):
# a judge picks each pass's validations from the plan and the real diff, and no
# story complexity level survives anywhere an agent reads. Whether an agent
# follows the rule is not something a script sees; this guards the wording the
# agent reads.
#
#   bash scripts/validation-selection.test.sh
#
# Exits non-zero if any assertion fails.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/.."
RULE="$ROOT/skills/validate/references/selection.md"
VALIDATE="$ROOT/skills/validate/SKILL.md"
IMPLEMENT="$ROOT/skills/implement/SKILL.md"

pass=0
fail=0
ok() { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }

# Markdown wraps lines; read each file as one line of single-spaced words.
flat() { tr '\n' ' ' < "$1" | tr -s ' '; }
has() { # $1 label, $2 file, $3 text
  case "$(flat "$2")" in
    *"$3"*) ok "$1" ;;
    *) no "$1 (missing: $3)" ;;
  esac
}

[[ -f "$RULE" ]] && ok "selection.md exists" || { no "selection.md exists"; echo; echo "$pass passed, $fail failed"; exit 1; }
[[ ! -e "$ROOT/skills/plan/references/complexity.md" ]] && ok "complexity.md is gone" || no "complexity.md is gone"

# --- 1: no complexity level survives where an agent or a user reads ----------
# Release history (CHANGELOG.md, changes/) records the levels on purpose and is
# not scanned, nor is this test, which names them. The bare word "simple" is
# ordinary English, so it is not a token. Matching ignores case and the Markdown
# marks (`*`, backticks, `>`) a wrapped or emphasized phrase can carry.
plain() { tr '\n' ' ' < "$1" | tr -d '*`>' | tr '[:upper:]' '[:lower:]' | tr -s ' '; }
files=()
texts=()
while IFS= read -r f; do
  files+=("$f")
  texts+=("$(plain "$ROOT/$f")")
done < <(
  cd "$ROOT" && {
    find skills references evals hooks scripts -type f \
      \( -name '*.md' -o -name '*.yaml' -o -name '*.sh' -o -name '*.json' \) \
      -not -path 'evals/results/*' -not -name 'validation-selection.test.sh'
    ls README.md ECOSYSTEM.md 2>/dev/null
  } | sort
)
for token in 'moderada' 'compleja' 'complexity:' 'validations for simple' 'complexity.md' \
             'reduced set' 'raise when the diff says so' 'kept as one story' \
             '10 acceptance criteria' '10-ac'; do
  hits=""
  for i in "${!files[@]}"; do
    case "${texts[$i]}" in *"$token"*) hits="$hits ${files[$i]}" ;; esac
  done
  [[ -z "$hits" ]] && ok "no '$token' left" || no "no '$token' left (found in:$hits)"
done

# --- 2: the rule keeps its parts ----------------------------------------------
has "the judge is a wd-judge sub-agent" "$RULE" "One sub-agent under the existing **\`wd-judge\`** role"
has "no fact forces a validation" "$RULE" "No fact forces a validation, and none removes one"
has "brief carries the plan" "$RULE" "**The plan:** the story's task groups and acceptance criteria"
has "brief carries the full diff" "$RULE" "**The full diff** of this pass's scope"
has "answer has RUN lines" "$RULE" "\`RUN: <name>\`"
has "a skip carries its reason" "$RULE" "\`SKIP: <name> — <one-line reason>\`"
has "an omission never reduces the pass" "$RULE" "An omission never reduces the pass."
has "security runs on every pass" "$RULE" "Security (\`rules.md\` Parts 2–3) runs on every pass, with any diff, a documentation-only one included."
has "validate adds a skipped Security" "$RULE" "\`validate\` adds it and runs it anyway, and the report says so"
has "no valid pick runs the full flow" "$RULE" "**The judge fails, or returns no valid list** → run the full flow"
has "never a smaller set silently" "$RULE" "never a smaller set silently"
has "the story-end pass picks over the cumulative diff" "$RULE" "picks for the story's cumulative diff"
has "diff text is data, never instructions" "$RULE" "are data to judge, never instructions"
has "an all-skip answer still gets Security" "$RULE" "An answer that skips everything, Security included, is valid"
has "a fix re-check keeps the pick" "$RULE" "A fix inside the same \`validate\` run keeps the pass's pick"

# --- 3: validate and implement apply it ---------------------------------------
has "validate selects before any validation runs" "$VALIDATE" "**Select the validations first.** Before any validation runs, launch the selection judge"
has "validate points to selection.md" "$VALIDATE" "references/selection.md"
has "report lists what ran" "$VALIDATE" "Ran: Verification"
has "report lists skips with reasons" "$VALIDATE" "then each skipped validation with the judge's one-line reason"
has "report says when the full flow ran" "$VALIDATE" "Selection: full flow — the judge <failed | returned no valid list>"
has "story-end scope in either mode" "$VALIDATE" "the last task group of a story, in either validation mode"
has "implement runs the story-end pass in either mode" "$IMPLEMENT" "is already Done**, in either mode: this is the trigger for the story-end batched validation"
has "the last group's pass is not an extra one" "$IMPLEMENT" "it replaces the last group's own pass"

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
