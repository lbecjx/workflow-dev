#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Tests for config-check.sh, the configuration interceptor (WD-0108). Every run
# uses a throwaway HOME and a throwaway git repo, so the developer's real
# ~/.workflow-dev and ~/.claude/agents are never read or written.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/config-check.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

HOME_DIR="$TMP/home"; mkdir -p "$HOME_DIR/.claude/agents"
REPO="$TMP/repo"; mkdir -p "$REPO/sub"
git -C "$REPO" init -q -b main

pass=0
fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
no()  { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }
has() { # $1 substring, $2 haystack, $3 label
  case "$2" in
    *"$1"*) ok "$3" ;;
    *) no "$3 (missing: $1 — got: $2)" ;;
  esac
}
lacks() { # $1 substring, $2 haystack, $3 label
  case "$2" in
    *"$1"*) no "$3 (unexpected: $1)" ;;
    *) ok "$3" ;;
  esac
}
json_ok() { # $1 JSON, $2 label
  command -v jq >/dev/null 2>&1 || return 0
  printf '%s' "$1" | jq -e . >/dev/null 2>&1 && ok "$2" || no "$2 (invalid JSON: $1)"
}

# run MODE SKILL [CWD] -> stdout, as Claude Code would call the hook.
run() {
  local cwd="${3:-$REPO}" payload
  if [[ "$1" == "--expansion" ]]; then
    payload="{\"command_name\":\"$2\",\"cwd\":\"$cwd\"}"
  else
    payload="{\"tool_name\":\"Skill\",\"cwd\":\"$cwd\",\"tool_input\":{\"skill\":\"$2\"}}"
  fi
  printf '%s' "$payload" | env HOME="$HOME_DIR" CLAUDECODE=1 bash "$SCRIPT" ${1:-}
}

# --- 1: not ours, and the skills that only read or fix, stay silent ----------
for s in someone-else:thing init plan workflow-dev:setup-models workflow-dev:help workflow-dev:usage workflow-dev:nonexistent; do
  OUT="$(run "" "$s")"
  [[ -z "$OUT" ]] && ok "$s → silent" || no "$s → silent (got: $OUT)"
done

# --- 2: everything missing → one allow, every question listed ----------------
OUT="$(run "" workflow-dev:init)"
has '"permissionDecision":"allow"' "$OUT" "missing answers → allow, never ask or deny"
lacks '"deny"' "$OUT" "missing answers → no deny"
lacks '"permissionDecision":"ask"' "$OUT" "missing answers → no ask dialog"
has 'before the run-mode question' "$OUT" "the context puts the setup before init's run-mode question"
has '.workflow-dev/ folder gitignored' "$OUT" "gitignored is listed"
has 'model of each agent role' "$OUT" "tiering is listed"
has 'credit the agent as co-author' "$OUT" "co-authorship is listed"
has 'notifications on for this machine' "$OUT" "the alerts are listed"
has 'Ask all of them together, in one ask-question call' "$OUT" "the context asks for one batch"
has 'Phase 0 step 3: save it instead of asking' "$OUT" "an answer already given counts, under init's one rule"
has 'apply each owner'"'"'s fallback and save it' "$OUT" "an unattended default is saved, so it is not asked again"
has 'do not ask it again in this conversation' "$OUT" "an answer that cannot be saved is not asked over and over"
has 'do not call it again' "$OUT" "the skill goes on, not called twice"
has 'references/tiering-question.md' "$OUT" "the tiering owner is named"
json_ok "$OUT" "PreToolUse output is valid JSON"

# --- 3: the typed path carries the same text as context ----------------------
OUT="$(run --expansion workflow-dev:plan)"
has '"hookEventName":"UserPromptExpansion"' "$OUT" "expansion → UserPromptExpansion output"
lacks 'permissionDecision' "$OUT" "expansion → no permission decision"
has 'credit the agent as co-author' "$OUT" "expansion lists the same questions"
json_ok "$OUT" "expansion output is valid JSON"

# --- 4: every skill that works on a story is intercepted ---------------------
for s in init init-auto plan implement validate save resume refresh summarize-changes manual-qa; do
  OUT="$(run "" "workflow-dev:$s")"
  has '"permissionDecision":"allow"' "$OUT" "$s → intercepted"
done

# --- 5: all answered → silent -----------------------------------------------
mkdir -p "$REPO/.workflow-dev" "$HOME_DIR/.workflow-dev"
printf 'gitignored=true\ntiering=default\nagentCoauthorship=no\n' > "$REPO/.workflow-dev/config.env"
printf 'notifications=on\n' > "$HOME_DIR/.workflow-dev/config.env"
OUT="$(run "" workflow-dev:init)"
[[ -z "$OUT" ]] && ok "all answered → silent" || no "all answered → silent (got: $OUT)"
OUT="$(run "" workflow-dev:init "$REPO/sub")"
[[ -z "$OUT" ]] && ok "a subdirectory reads the repo's answers" || no "a subdirectory reads the repo's answers (got: $OUT)"

# --- 6: only what is missing is listed ---------------------------------------
printf 'gitignored=false\ntiering=default\n' > "$REPO/.workflow-dev/config.env"
OUT="$(run "" workflow-dev:validate)"
has 'credit the agent as co-author' "$OUT" "co-authorship alone missing → listed"
lacks 'gitignored' "$OUT" "gitignored=false is an answer"
lacks 'model of each agent role' "$OUT" "a repo tiering default is an answer"
lacks 'notifications on for this machine' "$OUT" "notifications=on is an answer"
printf 'gitignored=true\ntiering=default\nagentCoauthorship=maybe\n' > "$REPO/.workflow-dev/config.env"
OUT="$(run "" workflow-dev:validate)"
has 'credit the agent as co-author' "$OUT" "an unreadable co-authorship value counts as missing"
printf 'gitignored=true\ntiering=default\nagentCoauthorship=no\n' > "$REPO/.workflow-dev/config.env"
printf 'notifications=off\n' > "$HOME_DIR/.workflow-dev/config.env"
OUT="$(run "" workflow-dev:validate)"
[[ -z "$OUT" ]] && ok "notifications=off is an answer" || no "notifications=off is an answer (got: $OUT)"
rm -f "$HOME_DIR/.workflow-dev/config.env"
OUT="$(run "" workflow-dev:validate)"
has 'notifications on for this machine' "$OUT" "no machine answer → the alerts are listed"
lacks 'gitignored' "$OUT" "…and only the alerts"

# --- 6b: a repo path with a quote keeps its tiering default -----------------
QREPO="$TMP/r\"quote"; mkdir -p "$QREPO/.workflow-dev"; git -C "$QREPO" init -q -b main
printf 'gitignored=true\ntiering=default\nagentCoauthorship=no\n' > "$QREPO/.workflow-dev/config.env"
mkdir -p "$HOME_DIR/.workflow-dev"; printf 'notifications=on\n' > "$HOME_DIR/.workflow-dev/config.env"
OUT="$(printf '{"tool_name":"Skill","tool_input":{"skill":"workflow-dev:plan"}}' | (cd "$QREPO" && env HOME="$HOME_DIR" CLAUDECODE=1 bash "$SCRIPT"))"
[[ -z "$OUT" ]] && ok "a quoted repo path keeps its tiering default" || no "a quoted repo path keeps its tiering default (got: $OUT)"

# --- 6c: the typed command may carry a leading slash ------------------------
rm -f "$HOME_DIR/.workflow-dev/config.env"
OUT="$(printf '{"command_name":"/workflow-dev:plan"}' | (cd "$QREPO" && env HOME="$HOME_DIR" CLAUDECODE=1 bash "$SCRIPT" --expansion))"
has 'notifications on for this machine' "$OUT" "a leading slash on the typed command still counts"

# --- 7: the interceptor never writes an answer --------------------------------
rm -rf "$REPO/.workflow-dev" "$HOME_DIR/.workflow-dev"
run "" workflow-dev:init >/dev/null
run --expansion workflow-dev:init >/dev/null
[[ ! -e "$REPO/.workflow-dev" && ! -e "$HOME_DIR/.workflow-dev" ]] \
  && ok "no answer is written by the hook" || no "the hook wrote a config file"

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
