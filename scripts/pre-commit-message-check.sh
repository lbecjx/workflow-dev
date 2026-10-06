#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# PreToolUse hook (matcher: Bash) — the actual guarantee behind validate's
# Git History Disclosure dimension (references/rules.md Part 12). A skill
# can be told to self-review the commit message or PR description it just
# drafted, but "the skill was told to" isn't certainty it happened — this
# hook fires on every real `git commit` / `gh pr create` / `gh pr edit`
# command regardless of which skill produced it (or whether any workflow-dev
# skill was involved at all) — and stays silent on a command that only
# mentions one (command-match.sh decides which is which).
#
# Two different enforcement levels, not one:
# - Most of Part 12 (tone, length, disclosure framing) is a judgment call,
#   so an unreviewed message gets a non-blocking "ask" — same pattern as
#   pre-commit-validate-check.sh, never denies outright, but an advisory
#   string alone is easy to read past in an auto-accept session, so this
#   makes the human (or the agent acting for them) actually confront the
#   question at the moment it matters.
# - AI/agent/LLM attribution (Part 12.3's hard rule) is not a judgment
#   call, so it's checked separately and **denied outright** — the only
#   rule in this file that is — regardless of whether the text carries a
#   reviewed-marker. `git-message-mark-reviewed.sh` already refuses to
#   mark text containing it, so reaching this point means that step got
#   bypassed somehow; deny is the backstop for that, not the first line
#   of defense.
#
# Message extraction is best-effort, not a real shell parser. It reads a quoted
# body after git's `-m` / `--message` (also inside a combined short-flag cluster
# such as `-qm` / `-am`) or gh's `--body`, single- or double-quoted, plus the
# text kept in a file (`-F`, `--file`, `--body-file`, `$(cat FILE)`). An
# unquoted argument, a flag glued to its value with no space, and a body the
# shell will expand (`$(...)`, a backtick, `$VAR`) are not guessed at — this
# hook silently does nothing rather than guess, same philosophy as Part 6's
# "can't discover it, skip, don't fail": a check that can't run confidently
# shouldn't produce a false sense of either safety or danger.
#
# Four modes, one owner of both the text and the verdict:
#   pre-commit-message-check.sh
#       Claude Code `PreToolUse` (matcher: Bash) — emits the JSON envelope.
#   pre-commit-message-check.sh --status [payload]
#       Prints one word and exits 0: `ok` (nothing to raise), `block` (the
#       attribution rule — the one hard denial) or `notify` (the Part 12
#       review). OpenCode's plugin reads this to know *whether* to raise
#       something, and how hard.
#   pre-commit-message-check.sh --message [payload]
#       Prints the reason as plain text for whichever of those two fired, and
#       nothing when the answer is `ok`.
#   pre-commit-message-check.sh --verdict [payload]
#       Prints the verdict and the reason from **one** run: the verdict word on
#       the first line, and, when there is one, the reason on the rest. OpenCode's
#       plugin reads this so it never runs the script twice and pairs a verdict
#       from one run with a reason computed at another moment (WD-0020).
# The verdict and the wording are both decided here, never re-derived by the
# caller — a second "should this fire?" test in the plugin would be free to
# disagree with the one Claude Code gets.

MODE="hook"
PAYLOAD_ARG=""
case "${1:-}" in
  --status)  MODE="status";  PAYLOAD_ARG="${2:-}" ;;
  --message) MODE="message"; PAYLOAD_ARG="${2:-}" ;;
  --verdict) MODE="verdict"; PAYLOAD_ARG="${2:-}" ;;
esac

# The one place a decision becomes an envelope. `verdict` is the one-word form
# (`ok` / `block` / `notify`), `reason` the text; `--verdict` is the only mode
# that prints both, which is what lets OpenCode's plugin decide and explain from
# a single run instead of two runs that could disagree (WD-0020).
emit() {
  local verdict="$1" reason="$2" decision
  case "$MODE" in
    status)  printf '%s' "$verdict" ;;
    message) [[ -n "$reason" ]] && printf '%s' "$reason" ;;
    verdict) printf '%s' "$verdict"; [[ -n "$reason" ]] && printf '\n%s' "$reason" ;;
    *)
      # Hook mode: `ok` is silent, the attribution rule denies, everything else
      # asks — so "silence is not one of the three words" holds for the other
      # modes without inventing output here.
      [[ "$verdict" == "ok" ]] && exit 0
      decision=ask
      [[ "$verdict" == "block" ]] && decision=deny
      printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":"%s"}}' "$decision" "$reason"
      ;;
  esac
  exit 0
}

# Every early exit goes through this, so `--status` always answers a verdict
# instead of exiting silently — silence is not one of the three words, and a
# caller that had to read it as one would be guessing.
quiet() { emit ok ""; }

if [[ "$MODE" != "hook" && -n "$PAYLOAD_ARG" ]]; then
  INPUT="$PAYLOAD_ARG"
else
  INPUT=$(cat)
fi

# command-match.sh owns both questions every commit hook asks: what the command
# was (one JSON extractor, shared) and whether it is really a commit/PR (see its
# header for the real/maybe/no contract). `no` means the words only appear as
# data (a heredoc body, an `echo`, a `grep`), so there is nothing to review and
# nothing to deny.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=command-match.sh
source "$HERE/command-match.sh"
# The marker directory's path and its trust check — one owner, shared with the
# other three scripts and validate/SKILL.md's Step 6 (WD-0027).
# shellcheck source=marker-dir.sh
source "$HERE/marker-dir.sh"

COMMAND=$(command_from_payload "$INPUT")

[[ -n "$COMMAND" ]] || quiet

# One scan answers both questions: the strongest verdict over every verb, and the
# strongest over the PR verbs alone (it decides whether a --title joins the hash).
SCAN=$(command_match_scan git-commit,gh-pr-create,gh-pr-edit "$COMMAND")
VERDICT="${SCAN%% *}"
PR_VERDICT="${SCAN##* }"
[[ "$VERDICT" == "no" ]] && quiet

# Kept byte-identical to git-message-mark-reviewed.sh's AI_ATTRIBUTION_PATTERN
# — if you change one, change the other, or a message could get marked
# reviewed under a pattern this hook doesn't also enforce. Checked against
# the whole raw command, not just the extracted body below, so it still
# catches attribution even if heredoc/-m extraction fails for some reason.
AI_ATTRIBUTION_PATTERN='(co-authored-by:.*(claude|anthropic|openai|chatgpt|copilot|gemini|codex))|(generated (with|by)[^.]*(claude|copilot|chatgpt|anthropic))|🤖|(claude\.ai)|(claude\.com/claude-code)|(anthropic\.com)|(ai-generated)|(ai-assisted)|(written (with|by) (an )?(ai|llm)\b)'

# The flag that carries a message and the quoted text after it: git's `-m` /
# `--message` (alone or in a combined short-flag cluster such as `-qm` / `-am`)
# and gh's `--body`. Only a quoted body is read — an unquoted argument, or a
# flag glued to its value with no space, is left to the "cannot read it, stay
# quiet" side on purpose (see the extraction comment below).
MSG_FLAG='(-[A-Za-z]*m[A-Za-z]*|--message|--body)'

if printf '%s' "$COMMAND" | grep -qiE "$AI_ATTRIBUTION_PATTERN"; then
  if [[ "$VERDICT" == "real" ]]; then
    ATTRIBUTION_REASON="This commit/PR contains AI/agent/LLM attribution or co-authorship (validate Part 12.3 — hard rule, no exceptions). Every commit and PR here is attributed to the human alone. Remove the attribution and re-run."
    emit block "$ATTRIBUTION_REASON"
  else
    # `maybe`: the command could be a commit/PR wrapped in `bash -c`, `eval`
    # and the like, or merely mention one. An ambiguous command must not be
    # refused on a guess, so this asks instead of denying.
    ATTRIBUTION_ASK_REASON="This command may be a commit/PR (it is wrapped in something the hook cannot read) and it contains AI/agent/LLM attribution or co-authorship (validate Part 12.3 — hard rule). If it is a commit/PR, remove the attribution before running it; every commit and PR here is attributed to the human alone."
    emit notify "$ATTRIBUTION_ASK_REASON"
  fi
fi

# Everything below is the Part 12 review ask, which belongs to a workflow-dev
# project: this plugin is installed per user, so without this it would question
# every commit and PR in every repo on the machine. The attribution rule above is
# deliberately not behind this gate; it stays as it was. Same test, from the same
# working directory, as pre-commit-validate-check.sh.
[[ -d ".workflow-dev/context" ]] || quiet

# Pulls the body of the first heredoc in the command: everything between a
# `<<[-]['"]DELIM['"]` opener and the next line that is exactly DELIM.
extract_heredoc_body() {
  local text="$1"
  local delim="" in_body=0 body=""
  while IFS= read -r line; do
    if [[ $in_body -eq 0 ]]; then
      if [[ "$line" =~ \<\<-?[[:space:]]*[\'\"]?([A-Za-z_]+)[\'\"]?[[:space:]]*$ ]]; then
        delim="${BASH_REMATCH[1]}"
        in_body=1
      fi
    elif [[ "$line" == "$delim" ]]; then
      printf '%s' "$body"
      return 0
    else
      body+="$line"$'\n'
    fi
  done <<< "$text"
  # Heredoc opener found but never closed within the command text — return
  # whatever was captured rather than nothing, best-effort.
  [[ -n "$body" ]] && printf '%s' "$body"
}

# The text of a message kept in a file: `-m "$(cat FILE)"`, `--body "$(cat FILE)"`,
# `--title "$(cat FILE)"`, `-F FILE`, `--file FILE`, `--body-file FILE`. summarize-
# changes marks a text as `printf '%s' "$text"`, and `$(cat FILE)` drops trailing
# newlines the same way, so the file's text hashes to the very value that was
# marked. Nothing is executed: the path is only read, and only `$VAR` / `${VAR}`
# from the hook's own environment are expanded. A path that cannot be resolved, a
# file that does not exist yet, or one that is not readable is "text this cannot
# read", and the hook stays quiet as its header says.
cat_arg() {
  printf '%s' "$COMMAND" | grep -oE -- "$1"'[[:space:]]+"\$\(cat[[:space:]]+("[^"]*"|[^[:space:]")]+)[[:space:]]*\)"' | head -1 | sed -E 's/^.*\$\(cat[[:space:]]+//; s/[[:space:]]*\)"$//'
}
file_arg() {
  printf '%s' "$COMMAND" | grep -oE -- '(-F|--file|--body-file)[[:space:]]+("[^"]*"|[^[:space:]]+)' | head -1 | sed -E 's/^(-F|--file|--body-file)[[:space:]]+//'
}
# The temp directory to fall back to when a path names `$TMPDIR` but the hook
# process has no TMPDIR of its own (whether a live Claude Code hook carries one
# is not measured; the shell that wrote the file does). macOS: the per-user temp
# dir, the same value `$TMPDIR` holds there; elsewhere /tmp. Only TMPDIR/TMP get
# this — any other unset variable stays unreadable.
temp_dir() {
  [[ -n "${TMPDIR:-}" ]] && { printf '%s' "$TMPDIR"; return; }
  local d
  d="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null)" && [[ -n "$d" ]] && { printf '%s' "${d%/}"; return; }
  printf '%s' /tmp
}

resolve_path() {
  local p="$1" name val
  p="${p#\"}"; p="${p%\"}"; p="${p#\'}"; p="${p%\'}"
  while [[ "$p" =~ \$\{([A-Za-z_][A-Za-z0-9_]*)\} || "$p" =~ \$([A-Za-z_][A-Za-z0-9_]*) ]]; do
    name="${BASH_REMATCH[1]}"
    val="${!name-}"
    if [[ -z "$val" && ( "$name" == "TMPDIR" || "$name" == "TMP" ) ]]; then
      val="$(temp_dir)"
    fi
    [[ -n "$val" ]] || return 1
    p="${p//"${BASH_REMATCH[0]}"/$val}"
  done
  case "$p" in
    ""|*'$'*|*'`'*|*'*'*|*'?'*|-) return 1 ;;
    "~/"*) p="$HOME/${p#\~/}" ;;
  esac
  printf '%s' "$p"
}
file_text() {
  local f t
  f=$(resolve_path "$1") || return 1
  [[ -f "$f" && -r "$f" ]] || return 1
  t=$(cat "$f")
  printf '%s' "$t"
}

BODY=$(extract_heredoc_body "$COMMAND")

if [[ -z "$BODY" ]]; then
  BODY=$(printf '%s' "$COMMAND" | grep -oE -- "$MSG_FLAG[[:space:]]+(\"[^\"]*\"|'[^']*')" | head -1 \
    | sed -E "s/^$MSG_FLAG[[:space:]]+[\"'](.*)[\"']\$/\2/")
  # Inside double quotes the shell expands `$(...)`, `$VAR` and backticks, so what
  # sits between the quotes is not the message that will be written:
  # `--body "$(cat file)"` reads as the fragment `$(cat `. Take the text from the
  # file when that is what the command does; otherwise it cannot be read.
  if [[ "$BODY" == *'$'* || "$BODY" == *'`'* ]]; then
    BODY=""
    TOKEN=$(cat_arg "$MSG_FLAG")
    [[ -n "$TOKEN" ]] && BODY=$(file_text "$TOKEN")
  elif [[ -z "$BODY" ]]; then
    TOKEN=$(file_arg)
    [[ -n "$TOKEN" ]] && BODY=$(file_text "$TOKEN")
  fi
fi

[[ -n "$BODY" ]] || quiet

# For a PR, the reviewed text is title+description concatenated — same
# convention summarize-changes/SKILL.md uses when marking it
# (`printf '%s\n\n%s' "<title>" "<description>"`). A commit has no separate
# title, so HASH_TEXT is just the message body.
HASH_TEXT="$BODY"
if [[ "$PR_VERDICT" != "no" ]]; then
  TITLE=$(printf '%s' "$COMMAND" | grep -oE -- '--title[[:space:]]+"[^"]*"' | head -1 | sed -E 's/^--title[[:space:]]+"(.*)"$/\1/')
  if [[ "$TITLE" == *'$'* || "$TITLE" == *'`'* ]]; then
    TOKEN=$(cat_arg '--title')
    [[ -n "$TOKEN" ]] || quiet
    TITLE=$(file_text "$TOKEN") || quiet
    [[ -n "$TITLE" ]] || quiet
  fi
  [[ -n "$TITLE" ]] && HASH_TEXT=$(printf '%s\n\n%s' "$TITLE" "$BODY")
fi

MESSAGE_HASH=$(printf '%s' "$HASH_TEXT" | shasum | cut -d' ' -f1)
MARKER_DIR="$(marker_subdir)"
MARKER_FILE="$MARKER_DIR/$MESSAGE_HASH.json"
# Trust is checked immediately before the read, with nothing slow in between —
# the read side of marker-write's "re-check at the moment of consequence" rule
# (WD-0027). Empty means trusted; a non-empty reason skips the read below and
# joins the review ask, so an untrusted directory asks — with the reason —
# rather than silently treating the message as reviewed. It never denies: the
# only deny here is the attribution rule above, which never consults a marker.
MARKER_TRUST_REASON="$(marker_chain_reason "$MARKER_DIR")"

[[ -z "$MARKER_TRUST_REASON" && -f "$MARKER_FILE" ]] && quiet

REVIEW_REASON="This commit message / PR description has not been through the Git History Disclosure review (validate Part 12 — formality, no security-incident narration, no personal or internal-workflow exposure). Confirm it is safe to use as-is, or run the check and mark it reviewed first with git-message-mark-reviewed.sh."
# `marker_trust_note` owns the wording and the JSON-safe quoting of the reason.
REVIEW_REASON="$REVIEW_REASON$(marker_trust_note "$MARKER_TRUST_REASON")"
emit notify "$REVIEW_REASON"
