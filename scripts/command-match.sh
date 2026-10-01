#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# One definition of "this shell command is really a `git commit` / `gh pr
# create` / `gh pr edit`" for every hook that has to ask. Two scripts used to
# answer it with a substring match on the whole command text, so a command that
# merely *mentioned* the words — a heredoc writing a doc, an `echo`, a `grep` —
# was treated as the real thing, and the one hard block in the plugin (AI
# attribution) could deny an innocent command. The same match also *missed*
# real commits (`git -C dir commit`, `git -c k=v commit`, anything after an
# escaped quote), so it was wrong in both directions.
#
# Usage:
#   source command-match.sh; command_match <verbs> <command>
#   command-match.sh <verbs> <command>          (or `-` / no command: read stdin)
# <verbs> is a comma list of `git-commit`, `gh-pr-create`, `gh-pr-edit`. The
# answer is the strongest verdict over the listed verbs, one word:
#   real   the verb is in command position — a command that will run
#   maybe  the phrase is somewhere this cannot clear: inside `bash -c "..."`,
#          `sh -c`, `eval`, `xargs`, `ssh`, `watch`, `timeout`, or an
#          unterminated quote
#   no     it is only data: an argument, a quoted string, a heredoc body, a comment
#
# THE POLICY, which every caller must keep: when the answer is `maybe`, the
# reminders (which only ask) fire as if it were `real` — a missed real commit is
# worse than one extra question. The hard block does the opposite: it never
# denies on `maybe`, because an ambiguous command must not be refused on a
# guess. Callers decide which side of that line they are on; this file only
# reports how sure it is.
#
# It is a best-effort scanner, not a shell parser. It tracks quotes, `$(...)`,
# backticks, heredocs, comments and the separators `; & | ( )` and newline, then
# looks at each simple command's program word (after env assignments, wrappers
# such as `sudo`/`env`/`command`, and the global options of git and gh). Aliases,
# functions and variable-built commands are invisible to it. awk, not a bash
# loop: the hooks run it on every shell call, and macOS ships bash 3.2 and a BSD
# awk, so only what both accept is used here.

command_match() {
  printf '%s\n' "${2-}" | awk -v verbs="${1-}" '
function hit(verb, level,    k) {
  for (k = 1; k <= nverbs; k++)
    if (V[k] == verb && level > best) best = level
}

function loose(s) {
  if (match(s, /git[ \t]+([^;&|]*[ \t])?commit($|[^A-Za-z0-9_-])/)) hit("git-commit", 1)
  if (match(s, /gh[ \t]+([^;&|]*[ \t])?pr[ \t]+create($|[^A-Za-z0-9_-])/)) hit("gh-pr-create", 1)
  if (match(s, /gh[ \t]+([^;&|]*[ \t])?pr[ \t]+edit($|[^A-Za-z0-9_-])/)) hit("gh-pr-edit", 1)
}

function evaluate(    i, j, k, x, o, p, nf, joined) {
  if (nw == 0) return
  nf = 0
  for (i = 1; i <= nw; i++) {
    x = w[i]
    if (x ~ /^[0-9]*(>>|>\||>|<>|<)&?-?$/) { i++; continue }
    if (x ~ /^[0-9]*(>>|>\||>|<>|<)/) continue
    f[++nf] = x
  }
  i = 1
  while (i <= nf) {
    x = f[i]
    if (x ~ /^[A-Za-z_][A-Za-z0-9_]*=/) { i++; continue }
    if (x == "!" || x == "{" || x == "if" || x == "then" || x == "else" || x == "elif" || \
        x == "do" || x == "while" || x == "until" || x == "time" || x == "command" || \
        x == "builtin" || x == "exec" || x == "nohup") { i++; continue }
    if (x == "env" || x == "sudo" || x == "nice") {
      i++
      while (i <= nf && f[i] ~ /^-/) {
        o = f[i]; i++
        if (o ~ /^-[ugCDhnprtS]$/) i++
      }
      continue
    }
    break
  }
  if (i > nf) return
  p = f[i]
  sub(/^.*\//, "", p)
  if (p == "git") {
    j = i + 1
    while (j <= nf && f[j] ~ /^-/) {
      o = f[j]; j++
      if (o == "-C" || o == "-c" || o == "--git-dir" || o == "--work-tree" || \
          o == "--namespace" || o == "--super-prefix" || o == "--config-env") j++
    }
    if (j <= nf && f[j] == "commit") hit("git-commit", 2)
  } else if (p == "gh") {
    j = i + 1
    while (j <= nf && f[j] ~ /^-/) {
      o = f[j]; j++
      if (o == "-R" || o == "--repo") j++
    }
    if (j + 1 <= nf && f[j] == "pr") {
      if (f[j + 1] == "create") hit("gh-pr-create", 2)
      else if (f[j + 1] == "edit") hit("gh-pr-edit", 2)
    }
  } else if (p ~ /^(bash|sh|zsh|dash|ksh|eval|xargs|ssh|watch|timeout|su)$/) {
    joined = ""
    for (k = i + 1; k <= nf; k++) joined = joined " " f[k]
    loose(joined)
  }
}

function endword() {
  if (!inword) return
  if (want) { np++; pd[np] = cur; pdash[np] = wantdash; want = 0 }
  else { w[++nw] = cur }
  cur = ""; inword = 0
}

function endcmd() { endword(); evaluate(); nw = 0 }

function push(kindname,    k) {
  sp++
  ocur[sp] = cur; oin[sp] = inword; onw[sp] = nw
  for (k = 1; k <= nw; k++) ow[sp, k] = w[k]
  nw = 0; cur = ""; inword = 0
  st[sp] = "cmd"; kind[sp] = kindname; depth[sp] = 0
}

function pop(    k) {
  endcmd()
  cur = ocur[sp] "S"; inword = 1; nw = onw[sp]
  for (k = 1; k <= nw; k++) w[k] = ow[sp, k]
  sp--
}

function scan(s,    i, L, c, c2, nx, prev, top, dash) {
  L = length(s); i = 1
  while (i <= L) {
    c = substr(s, i, 1); c2 = substr(s, i, 2); top = st[sp]
    if (top == "sq") {
      if (c == SQ) sp--
      else { cur = cur c; inword = 1 }
      i++; continue
    }
    if (top == "dq") {
      if (c == DQ) { sp--; i++; continue }
      if (c == "\\") {
        nx = substr(s, i + 1, 1)
        if (nx == "") { contline = 1; i++; continue }
        if (nx == "$" || nx == DQ || nx == "\\" || nx == BT) cur = cur nx
        else cur = cur "\\" nx
        i += 2; continue
      }
      if (c2 == "$(") { push("sub"); i += 2; continue }
      if (c == BT) { push("bt"); i++; continue }
      cur = cur c; inword = 1; i++; continue
    }
    if (c == " " || c == "\t") { endword(); i++; continue }
    if (c == "\\") {
      nx = substr(s, i + 1, 1)
      if (nx == "") { contline = 1; i++; continue }
      cur = cur nx; inword = 1; i += 2; continue
    }
    if (c == SQ) { sp++; st[sp] = "sq"; inword = 1; i++; continue }
    if (c == DQ) { sp++; st[sp] = "dq"; inword = 1; i++; continue }
    if (c == "#" && !inword) { i = L + 1; continue }
    if (c2 == "$(") { push("sub"); i += 2; continue }
    if (c == BT) {
      if (kind[sp] == "bt") pop(); else push("bt")
      i++; continue
    }
    if (c == ";" || c == "|") { endcmd(); i++; continue }
    if (c == "&") {
      prev = substr(s, i - 1, 1); nx = substr(s, i + 1, 1)
      if (prev == ">" || prev == "<" || nx == ">") { cur = cur c; inword = 1; i++; continue }
      endcmd(); i++; continue
    }
    if (c == "(") { endcmd(); depth[sp]++; i++; continue }
    if (c == ")") {
      if (depth[sp] > 0) { depth[sp]--; endcmd() }
      else if (kind[sp] == "sub") pop()
      else endcmd()
      i++; continue
    }
    if (c2 == "<<") {
      if (substr(s, i, 3) == "<<<") { cur = cur "<<<"; inword = 1; i += 3; continue }
      dash = (substr(s, i + 2, 1) == "-")
      endword(); want = 1; wantdash = dash
      i += 2 + dash; continue
    }
    cur = cur c; inword = 1; i++
  }
}

BEGIN {
  SQ = "\047"; DQ = "\042"; BT = "\140"
  nverbs = split(verbs, V, ",")
  best = 0
  sp = 1; st[1] = "cmd"; kind[1] = "top"; depth[1] = 0
  nw = 0; cur = ""; inword = 0
  np = 0; pi = 1; hdactive = 0; want = 0
}

{
  raw = raw $0 "\n"
  if (hdactive) {
    chk = $0
    if (pdash[pi]) sub(/^\t+/, "", chk)
    if (chk == pd[pi]) {
      pi++
      if (pi > np) { hdactive = 0; np = 0; pi = 1 }
    }
    next
  }
  contline = 0
  scan($0)
  if (contline) { }
  else if (st[sp] == "sq" || st[sp] == "dq") { cur = cur "\n"; inword = 1 }
  else endcmd()
  if (np >= pi) hdactive = 1
}

END {
  endcmd()
  if (sp > 1) loose(raw)
  print (best == 2) ? "real" : (best == 1) ? "maybe" : "no"
}
'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  if [[ $# -lt 1 ]]; then
    echo "usage: command-match.sh <git-commit|gh-pr-create|gh-pr-edit>[,...] [command | -]" >&2
    exit 2
  fi
  verbs="$1"
  shift
  if [[ $# -eq 0 || "${1-}" == "-" ]]; then
    cmd=$(cat)
  else
    cmd="$1"
  fi
  command_match "$verbs" "$cmd"
fi
