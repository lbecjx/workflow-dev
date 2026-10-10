#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Sourced, never run: the one owner of the AI/agent attribution rule
# (validate/references/rules.md §12.3) as both scripts that enforce it read it —
# git-message-mark-reviewed.sh (refuses to mark) and pre-commit-message-check.sh
# (denies the commit/PR). Both patterns and the human's co-authorship decision
# live here, so the two scripts cannot drift apart: they used to keep a copy of
# the pattern each, "byte-identical by hand", which only a comment enforced.
#
# The decision is the repository's, kept in `.workflow-dev/config.json` beside
# its other one-time answers (`gitignored`, `tiering`), written by
# summarize-changes or init when the human answers, and changed only when the
# human asks:
#   { "gitignored": true, "agentCoauthorship": "yes" }
# Only that key, present once, with the string value "yes", means yes.
# Everything else means no, which keeps the deny exactly as it was: no file, an
# unreadable or malformed one, no key, the key twice, or any other value.
#
# Defines functions and patterns only — sourcing it has no side effects.

# Phrases that credit an AI with the work in prose. They are part of the
# attribution pattern below, and are also checked on their own against the two
# lines a yes allows, so a yes never lets one ride inside an allowed line.
AI_CREDIT_PHRASE_PATTERN='(ai-generated)|(ai-assisted)|(written (with|by) (an )?(ai|llm|claude|chatgpt|copilot|gemini|codex)\b)'

# Attribution in any form: what the deny and the refusal-to-mark look for.
AI_ATTRIBUTION_PATTERN='(co-authored-by:.*(claude|anthropic|openai|chatgpt|copilot|gemini|codex))|(generated (with|by)[^.]*(claude|copilot|chatgpt|anthropic))|🤖|(claude\.ai)|(claude\.com/claude-code)|(anthropic\.com)|'"$AI_CREDIT_PHRASE_PATTERN"

# The only two forms a yes allows, each as a whole line: the commit trailer
# (`Co-Authored-By: <name> <email>`) and the PR line (`🤖 Generated with
# [<tool>](<url>)`). Any name, email and URL the harness supplies, so the plugin
# never names a model — but only plain characters in each: letters, digits,
# spaces, `._-` (and `+@` in the email, `/:` in the URL), and at most four words
# of name or link text ("Claude Opus 5.5", "Claude Code"), so no sentence fits. No quote, so a shell
# argument cannot be closed and reopened inside an allowed line. Trailing `"` /
# `'` are the quotes closing a `-m "..."` / `--body "..."` argument (two when it
# sits inside `bash -c '...'`), and quotes only. Anything else on the same line
# (a second flag, a sentence) makes it no longer a whole-line match, so it stays
# attribution and is denied — the safe side. Matched case-sensitively: the
# harness writes these exact forms.
AI_COAUTHOR_ALLOWED_LINE_PATTERN='^[[:space:]]*(Co-Authored-By: [A-Za-z0-9][A-Za-z0-9._-]*( [A-Za-z0-9._-]+){0,3} <[A-Za-z0-9._+-]+@[A-Za-z0-9.-]+>|🤖 Generated with \[[A-Za-z0-9][A-Za-z0-9._-]*( [A-Za-z0-9._-]+){0,3}\]\(https?://[A-Za-z0-9./_-]+\))[[:space:]]*["'"'"']*[[:space:]]*$'

# yes or no for the working directory's repository. Never fails: any error is
# no. The whole test runs inside jq on the file itself: exactly one JSON
# document, an object, whose top-level `agentCoauthorship` is the string "yes"
# — compared in jq, so "yes\n" or "yes\u0000" never pass through a bash capture
# that would trim them. Before that, the raw text must name the key once and
# hold no `\u` escape and no NUL byte, since jq would silently resolve a
# duplicate written as an escape ("agentCoauthorship") to the last one.
# Reading JSON needs jq: without it the answer is no.
coauthor_decision() {
  local f=".workflow-dev/config.json"
  command -v jq >/dev/null 2>&1 || { printf 'no'; return 0; }
  [[ -f "$f" && -r "$f" ]] || { printf 'no'; return 0; }
  [[ "$(wc -c < "$f")" == "$(tr -d '\000' < "$f" | wc -c)" ]] || { printf 'no'; return 0; }
  grep -q '\\u' "$f" && { printf 'no'; return 0; }
  [[ "$(grep -o 'oauthorship' "$f" | grep -c .)" == "1" ]] || { printf 'no'; return 0; }
  jq -e --slurp 'length == 1 and (.[0] | type) == "object" and .[0].agentCoauthorship == "yes"' "$f" >/dev/null 2>&1 \
    && printf 'yes' || printf 'no'
}

# $1 = text, $2 = the decision (yes|no; anything else is no). Succeeds when the
# text carries attribution the decision does not allow. With yes: any
# attribution outside the allowed lines, or a credit phrase inside one.
# Otherwise: any attribution at all.
has_ai_attribution() {
  local text="$1"
  if [[ "${2:-no}" != "yes" ]]; then
    printf '%s' "$text" | grep -qiE "$AI_ATTRIBUTION_PATTERN"
    return
  fi
  printf '%s\n' "$text" | grep -vE "$AI_COAUTHOR_ALLOWED_LINE_PATTERN" | grep -qiE "$AI_ATTRIBUTION_PATTERN" && return 0
  printf '%s\n' "$text" | grep -E "$AI_COAUTHOR_ALLOWED_LINE_PATTERN" | grep -qiE "$AI_CREDIT_PHRASE_PATTERN" && return 0
  # Each allowed form once, and never as the first line (a commit subject, a PR
  # title): the yes is for a trailer and a footer line, not for the headline.
  [[ $(printf '%s\n' "$text" | grep -E "$AI_COAUTHOR_ALLOWED_LINE_PATTERN" | grep -c 'Co-Authored-By: ') -gt 1 ]] && return 0
  [[ $(printf '%s\n' "$text" | grep -E "$AI_COAUTHOR_ALLOWED_LINE_PATTERN" | grep -c '🤖 Generated with ') -gt 1 ]] && return 0
  printf '%s\n' "$text" | grep -m1 -v '^[[:space:]]*$' | grep -qE "$AI_COAUTHOR_ALLOWED_LINE_PATTERN"
}

# Succeeds only when a command is plain enough for the human's yes to apply to
# it: exactly `git commit …` or `gh pr create|new|edit …`, one command, aimed at
# the repository of this working directory. Everything else gets the default
# no. This is an allowlist on purpose: the ways a shell can reach another
# repository (`cd`, `chdir`, `env --chdir`, `bash -c`, `eval`, `git -C`,
# `GIT_DIR=`, `GH_REPO=`, `gh -R`, a PR URL, a command substitution, a second
# command on the next line, …) cannot be listed in full, and each one missed was
# a way to spend this repository's yes on someone else's commit. A plain command:
# - starts with `git commit` (no git option before `commit`) or `gh pr
#   create|new|edit`, with no `-R` (also inside a short cluster, `-dR`) /
#   `--repo` / URL argument for gh;
# - has no `;`, `&`, `|`, `<`, `>`, backtick, `$`, parenthesis, brace or
#   backslash outside quotes, and no second command line;
# - quotes text only as the value of a message flag (`-m`, a short cluster
#   ending in `m`, `--message`, `--body`, `--title`, also `--flag="…"`), and
#   holds no `$` or backtick inside those quotes — except the one form
#   summarize-changes uses, `"$(cat <<'EOF'` ending its line, whose body is
#   skipped: its delimiter is single-quoted, so bash expands nothing in it. Any
#   other heredoc (on stdin, unquoted delimiter, an opener inside the text) is
#   refused, since bash would run a `$(…)` in its body. The body itself holds no
#   `$(` or backtick, and balanced parentheses only, never beside a quote, a
#   backslash or a `#`: bash
#   3.2 closes the `$(` at an unbalanced `)` in it. After the heredoc only
#   `)` and the closing quote may follow: more text there runs as a command.
# The awk walks each line once through split(), linear in its length.
coauthor_command_plain() {
  printf '%s\n' "$1" | awk '
    function vflag(w) { return w ~ /^(-[A-Za-z]*m|--message|--body|--title)$/ }
    function eqflag(w) { return w ~ /^(--message|--body|--title)=$/ }
    function flush() { if (word != "") { tok[++nt] = word; prev = word } word = "" }
    # A control character other than tab (CR, VT, FF, …) is a word character to
    # the shell but whitespace to [[:space:]] here, so the two would split the
    # command differently: refuse it anywhere.
    { ctl = $0; gsub(/\t/, "", ctl); if (ctl ~ /[[:cntrl:]]/) bad = 1 }
    hd != "" {
      t = $0
      if (hdash) sub(/^\t+/, "", t)
      if (t == hd) { hd = ""; aft = 1; if (depth != 0 || (parens && odd)) bad = 1; next }
      # bash 3.2 (macOS /bin/bash) ends the `$(` at the first unbalanced `)` even
      # inside a quoted heredoc, and runs what follows. So the body may hold no
      # `$(` or backtick, its parentheses must balance, and parentheses may not
      # sit beside a quote, a backslash or a `#`: each changes how that bash
      # counts them (a quoted or escaped paren, a comment), and `$\` plus a line
      # break rebuilds a `$(` after an early close.
      if ($0 ~ /`|\$\(/) bad = 1
      if ($0 ~ /[\047"\\#]/) odd = 1
      m = split($0, bc, "")
      for (j = 1; j <= m; j++) {
        if (bc[j] == "(") { depth++; parens = 1 }
        else if (bc[j] == ")") { depth--; parens = 1; if (depth < 0) bad = 1 }
      }
      next
    }
    {
      line = $0
      if (q == "" && ended && line ~ /[^[:space:]]/) bad = 1
      n = split(line, ch, "")
      for (i = 1; i <= n; i++) {
        c = ch[i]
        if (q != "") {
          # After the heredoc, only `)` and the closing quote may follow: inside
          # the `$(`, anything else is a command the shell would run.
          if (aft) {
            if (c ~ /[[:space:]]/) continue
            if (c == ")" && !paren) { paren = 1; continue }
            if (c == "\"" && paren) { q = ""; closed = 1; aft = 0; paren = 0; continue }
            bad = 1
            continue
          }
          if (q == "d" && (c == "$" || c == "`")) {
            rest = substr(line, i)
            if (rest ~ /^\$\(cat[[:space:]]+<<-?\047[A-Za-z_]+\047[[:space:]]*$/) {
              hdash = (rest ~ /<<-/)
              hd = rest
              sub(/^[^\047]*\047/, "", hd)
              sub(/\047.*$/, "", hd)
            } else bad = 1
            i = n
            continue
          }
          if (q == "d" && c == "\\") { i++; continue }
          if ((q == "s" && c == "\047") || (q == "d" && c == "\"")) { q = ""; closed = 1 }
          continue
        }
        if (c == "\047" || c == "\"") {
          if (closed) bad = 1
          if (word != "") { if (!eqflag(word)) bad = 1; word = "" }
          else if (!vflag(prev)) bad = 1
          prev = ""
          q = (c == "\"") ? "d" : "s"
          continue
        }
        if (c ~ /[[:space:]]/) { flush(); closed = 0; continue }
        if (closed) bad = 1
        if (c ~ /[;&|<>`$(){}\\]/) bad = 1
        word = word c
      }
      if (q == "") { flush(); closed = 0; if (nt > 0) ended = 1 }
    }
    END {
      if (q != "" || hd != "" || bad || nt < 2) { print "no"; exit }
      ok = 0
      if (tok[1] == "git" && tok[2] == "commit") ok = 1
      if (tok[1] == "gh" && tok[2] == "pr" && (tok[3] == "create" || tok[3] == "new" || tok[3] == "edit")) {
        ok = 1
        for (k = 4; k <= nt; k++)
          if (tok[k] ~ /^-[A-Za-z]*R/ || tok[k] ~ /^--repo/ || tok[k] ~ /:\/\// || tok[k] ~ /github\./) ok = 0
      }
      print ok ? "yes" : "no"
    }' | grep -qx yes
}
