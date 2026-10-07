#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code and OpenCode
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
#   source command-match.sh; command_from_payload <hook-json>
#   command-match.sh <verbs> <command>          (or `-` / no command: read stdin)
# <verbs> is a comma list of `git-commit`, `gh-pr-create`, `gh-pr-edit`. The
# answer is the strongest verdict over the listed verbs, one word:
#   real   the verb is in command position — a command that will run. Wrappers
#          that only launch their argument (`sudo`, `env`, `time`, `timeout`,
#          `xargs`, `stdbuf`, `flock`, ...) are looked through, options and all
#   maybe  the phrase is somewhere this cannot clear: inside `bash -c "..."`,
#          `sh -c`, `eval`, `ssh`, `watch`, `trap`, a script fed to a shell by
#          heredoc or pipe, `git submodule foreach`, `git rebase -x`,
#          `git filter-branch --*-filter`, `vagrant ssh -c`, a program this
#          does not know that is handed a bare `git`/`gh` word, a program word
#          built from a variable (or `"$@"` after `set --`), `env -S`,
#          `flock -c`, `docker exec ... sh`, an unterminated quote, or a
#          command too long to scan
#   no     it is only data: an argument, a quoted string, a heredoc body, a comment
#
# command_from_payload reads `.tool_input.command` out of a hook's JSON payload —
# one extractor for every hook, so two scripts cannot disagree about what the
# command was (the old validate-check one stopped at the first escaped quote).
#
# THE POLICY, which every caller must keep: when the answer is `maybe`, the
# reminders (which only ask) fire as if it were `real` — a missed real commit is
# worse than one extra question. The hard block does the opposite: it never
# denies on `maybe`, because an ambiguous command must not be refused on a
# guess. Callers decide which side of that line they are on; this file only
# reports how sure it is. The same rule decides every doubt inside the scanner:
# an unknown program that is handed a bare `git` word is `maybe`, never `no`.
#
# It is a best-effort scanner, not a shell parser. It tracks quotes, `$(...)`,
# backticks, arithmetic `((...))` and `$[...]`, `${...}`, `$'...'`, `[[ ... ]]`,
# array literals, heredocs, comments, redirections and the
# separators `; & | ( )` and newline, then looks at each simple command's
# program word (after env assignments, wrappers, and the global options of git
# and gh). A `name=(` / `name+=(` array literal is opaque for as long as its
# closing `)` is not on the line: bare words inside it stay data, and only a
# substitution it holds comes back into view (the same rule the single-line
# array follows). An unterminated array is scanned at end of input, so the
# lines after it are not swallowed. Aliases and functions are not modelled. awk, not a bash loop: the hooks run it on
# every shell call, and macOS ships bash 3.2 and a BSD awk, so only what both
# accept is used here. BSD awk builds a word one character at a time in
# quadratic time (128 KB of one line took about 2 s), so a command over
# COMMAND_MATCH_MAX_BYTES is not scanned and answers `maybe`; one with none of
# the words `commit`, `create`, `edit`, `new` in it cannot be a commit or PR
# and answers `no` without starting awk. That pre-check misses a verb spelled
# with quotes or escapes inside the word (`co''mmit`), as the old match did.

COMMAND_MATCH_MAX_BYTES=50000

command_from_payload() {
  local c
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "${1-}" | jq -r '.tool_input.command // empty' 2>/dev/null
    return 0
  fi
  # Without jq: the string body is "any char but a quote or backslash, or a
  # backslash plus any char", so an escaped quote no longer ends the match.
  c=$(printf '%s' "${1-}" | grep -oE '"command"[[:space:]]*:[[:space:]]*"([^"\\]|\\.)*"' | head -1 | sed -E 's/^"command"[[:space:]]*:[[:space:]]*"(.*)"$/\1/')
  # One left-to-right pass, not a chain of sed substitutions: with a chain, an
  # escaped backslash before `n` (`\\n`) was read as backslash + newline.
  printf '%s' "$c" | awk 'BEGIN { RS = "\001" } {
    n = length($0); out = ""
    for (i = 1; i <= n; i++) {
      ch = substr($0, i, 1)
      if (ch == "\\" && i < n) {
        i++; nx = substr($0, i, 1)
        if (nx == "n") out = out "\n"
        else if (nx == "t") out = out "\t"
        else out = out nx
      } else out = out ch
    }
    printf "%s", out
  }'
}

# Prints two words from ONE scan: the strongest verdict over every listed verb,
# and the strongest over the `gh-*` verbs alone (a caller that must tell a PR
# from a commit does not pay for a second scan).
command_match_scan() {
  local cmd="${2-}"
  case "$cmd" in
    *commit*|*create*|*edit*|*new*) ;;
    *) printf 'no no\n'; return 0 ;;
  esac
  if [[ ${#cmd} -gt $COMMAND_MATCH_MAX_BYTES ]]; then
    printf 'maybe maybe\n'
    return 0
  fi
  printf '%s\n' "$cmd" | awk -v verbs="${1-}" '
function hit(verb, level,    k) {
  for (k = 1; k <= nverbs; k++)
    if (V[k] == verb) {
      if (level > best) best = level
      if (verb ~ /^gh-/ && level > bestpr) bestpr = level
    }
}

function word(l) { return (l == 2) ? "real" : (l == 1) ? "maybe" : "no" }

function loose(s) {
  if (match(s, /(^|[^A-Za-z0-9_-])git[ \t]+([^;&|]*[ \t])?commit($|[^A-Za-z0-9_-])/)) hit("git-commit", 1)
  if (match(s, /(^|[^A-Za-z0-9_-])gh[ \t]+([^;&|]*[ \t])?pr[ \t]+(create|new)($|[^A-Za-z0-9_-])/)) hit("gh-pr-create", 1)
  if (match(s, /(^|[^A-Za-z0-9_-])gh[ \t]+([^;&|]*[ \t])?pr[ \t]+edit($|[^A-Za-z0-9_-])/)) hit("gh-pr-edit", 1)
}

function basename(s) { sub(/^.*\//, "", s); return s }

# Fills f[1..nf] with w[1..n] minus the redirections and their targets; the text
# of a here-string goes to hsx. One place decides which words are real words.
function build_f(n,    i, x) {
  nf = 0; hsx = ""
  for (i = 1; i <= n; i++) {
    x = w[i]
    if (x == "<<<") { hsx = hsx " " w[i + 1]; i++; continue }
    if (x ~ /^(&|[0-9]*)(>>|>\||>|<>|<)&?-?$/) { i++; continue }
    if (x ~ /^(&|[0-9]*)(>>|>\||>|<>|<)/) continue
    f[++nf] = x
  }
}

# Counts, for a shell (or ssh) whose program word is f[i]: whether it was given
# -c (a command string), -s (read the script from stdin) and how many operands
# that are not options. `bash script.sh <<EOF` runs the FILE and feeds the
# heredoc to it as data; only `bash`, `bash -s` or `ssh host` read stdin as code.
function shell_flags(i, p,    k, a) {
  fl_c = 0; fl_s = 0; fl_nopt = 0; fl_rem = ""
  for (k = i + 1; k <= nf; k++) {
    a = f[k]
    if (p == "ssh") {
      if (a ~ /^-[bcDeFIiJLlmOopQRSWw]$/) { k++; continue }
      if (a ~ /^-/) continue
      fl_nopt++
      if (fl_nopt == 2) fl_rem = a
      continue
    }
    if (a == "-" || a == "/dev/stdin") { fl_s = 1; continue }
    if (a ~ /^[-+][oO]$/ || a == "--rcfile" || a == "--init-file") { k++; continue }
    if (a ~ /^-[A-Za-z]*c[A-Za-z]*$/) fl_c = 1
    else if (a ~ /^-[A-Za-z]*s[A-Za-z]*$/) fl_s = 1
    else if (a !~ /^[-+][A-Za-z-]/) fl_nopt++
  }
}

function stdin_is_code(i, p,    rt) {
  if (p !~ /^(bash|sh|zsh|dash|ksh|fish|su|ssh)$/) return 0
  shell_flags(i, p)
  if (p == "ssh") {
    if (fl_nopt <= 1) return 1
    split(fl_rem, rt, " ")
    return (basename(rt[1]) ~ /^(bash|sh|zsh|dash|ksh|fish)$/)
  }
  if (p == "su") return !fl_c
  if (fl_c) return 0
  return (fl_s || fl_nopt == 0)
}

# Is the command collected so far in w[] one that reads its stdin as a script? Judged
# by the program word after assignments and wrappers, never by any word that
# happens to say `sh`: `cat > tools/sh <<EOF` is data.
function is_shell_cmd(    i, p) {
  build_f(nw)
  i = prog_index()
  if (i > nf) return sudo_shell
  p = basename(f[i])
  if (p ~ /^(bash|sh|zsh|dash|ksh|fish|ssh|su)$/) return stdin_is_code(i, p)
  if (p ~ /^(docker|podman|kubectl|lima|limactl|vagrant|multipass|nsenter|chroot)$/ && has_runner_cmd(i)) return 1
  return 0
}

# Skips the options of a wrapper. An option word ending in one of `letters`
# takes the next word as its argument (`sudo -u bob`, `sudo -iu bob`, `xargs
# -n 1`); an attached argument (`stdbuf -oL`, `xargs -I{}`) does not match.
function skipopts(i, letters,    o) {
  while (i <= nf && f[i] ~ /^-/) {
    o = f[i]; i++
    if (o ~ /^-[A-Za-z]+$/ && index(letters, substr(o, length(o), 1)) > 0) i++
  }
  return i
}

# `git [global options] commit`, starting at the word after the program.
function check_git(j, lvl,    o, k, rest) {
  while (j <= nf && f[j] ~ /^-/) {
    o = f[j]; j++
    if (o == "-C" || o == "-c" || o == "--git-dir" || o == "--work-tree" || \
        o == "--namespace" || o == "--super-prefix" || o == "--config-env") j++
  }
  if (j > nf) return
  if (f[j] == "commit") hit("git-commit", lvl)
  else if (f[j] == "rebase") {
    for (k = j + 1; k <= nf; k++) {
      if (f[k] == "-x" || f[k] == "--exec") loose(f[k + 1])
      else if (f[k] ~ /^--exec=/) loose(substr(f[k], 8))
      else if (f[k] ~ /^-x./) loose(substr(f[k], 3))
    }
  }
  else if (f[j] == "submodule") {
    rest = ""
    for (k = j + 1; k <= nf; k++) rest = rest " " f[k]
    loose(rest)
  }
  else if (f[j] == "filter-branch") {
    # filter-branch --msg-filter <command> (and its siblings) hands the command
    # to a shell, exactly like rebase -x, so the command string is `maybe`.
    for (k = j + 1; k <= nf; k++) {
      if (f[k] ~ /^--(msg|tree|index|commit|env|parent|tag-name)-filter$/) loose(f[k + 1])
      else if (f[k] ~ /^--(msg|tree|index|commit|env|parent|tag-name)-filter=/) loose(substr(f[k], index(f[k], "=") + 1))
    }
  }
}

# `gh [-R repo] pr [-R repo] create|new|edit`. Flags may come before or after
# `pr`, and `new` is gh own alias for `create`.
function check_gh(j, lvl,    o) {
  while (j <= nf && f[j] ~ /^-/) {
    o = f[j]; j++
    if (o == "-R" || o == "--repo") j++
  }
  if (j > nf || f[j] != "pr") return
  j++
  while (j <= nf && f[j] ~ /^-/) {
    o = f[j]; j++
    if (o == "-R" || o == "--repo") j++
  }
  if (j > nf) return
  if (f[j] == "create" || f[j] == "new") hit("gh-pr-create", lvl)
  else if (f[j] == "edit") hit("gh-pr-edit", lvl)
}

# A program this does not know, handed a bare `git` or `gh` word, may be
# running it. Quoted strings are single words, so a mention in quotes never
# gets here; a program word built from a variable or a substitution is looked at
# for the bare subcommand instead.
function tokscan(i, p,    k) {
  for (k = i + 1; k <= nf; k++) {
    if (basename(f[k]) == "git") check_git(k + 1, 1)
    else if (basename(f[k]) == "gh") check_gh(k + 1, 1)
  }
  if (index(p, SUBST) > 0 || p ~ /^\$/) {
    loose(setargs)
    loose(vartext)
    for (k = i + 1; k <= nf; k++) {
      if (f[k] == "commit") hit("git-commit", 1)
      else if (f[k] == "pr" && (f[k + 1] == "create" || f[k + 1] == "new")) hit("gh-pr-create", 1)
      else if (f[k] == "pr" && f[k + 1] == "edit") hit("gh-pr-edit", 1)
    }
  }
}

function has_shell_word(i,    k) {
  for (k = i + 1; k <= nf; k++)
    if (basename(f[k]) ~ /^(bash|sh|zsh|dash|ksh|fish)$/) return 1
  return 0
}

# Is this runner program handed a command to run? A bash-like word counts for
# every runner (`docker exec c sh`). `vagrant` is the exception: it takes its
# command with `vagrant ssh -c <command>`, not with a shell word, so without
# this a real commit wrapped that way was missed. `vagrant ssh` / `vagrant up`
# with no `-c` are interactive, not a command, and stay `no`.
function has_runner_cmd(i,    k, seen_ssh) {
  if (has_shell_word(i)) return 1
  if (basename(f[i]) != "vagrant") return 0
  seen_ssh = 0
  for (k = i + 1; k <= nf; k++) {
    if (!seen_ssh) { if (f[k] == "ssh") seen_ssh = 1; continue }
    if (f[k] == "-c" || f[k] == "--command") return 1
    if (f[k] ~ /^-c./ || f[k] ~ /^--command=/) return 1
  }
  return 0
}

# Scans a block of buffered text with the SAME per-line logic the main input
# loop uses. A naive `scan(); endcmd()` per line was wrong: it ignored a
# trailing backslash (a line continuation, so `git \` + `commit` split into two
# commands and a real commit was missed) and it ignored heredoc bookkeeping (a
# `cat <<EOF` inside a re-scanned array had its body read as commands). feed()
# is that shared per-line step; the main loop and this both go through it.
function feed(line,    chk) {
  if (hdactive) {
    chk = line
    if (pdash[pi]) sub(/^\t+/, "", chk)
    if (chk == pd[pi]) {
      if (pshell[pi]) loose(pbody[pi])
      if (pipedshell) loose(pbody2[pi])
      pi++
      if (pi > np) { hdactive = 0; np = 0; pi = 1; pipedshell = 0 }
    }
    else {
      if (pshell[pi]) pbody[pi] = pbody[pi] line "\n"
      if (pipedshell) pbody2[pi] = pbody2[pi] line "\n"
      if (psub[pi]) subbody = subbody line "\n"
    }
    return
  }
  contline = 0
  pipedshell = 0
  scan(line)
  if (!contline) {
    if (st[sp] == "sq" || st[sp] == "dq" || st[sp] == "ansi") { cur = cur "\n"; inword = 1 }
    else endcmd()
  }
  if (np >= pi) hdactive = 1
}

function scan_text(text,    n, a, j) {
  n = split(text, a, "\n")
  for (j = 1; j <= n; j++) feed(a[j])
}

# Index of the program word in f[]: past assignments, keywords and wrappers (with
# their options). Anything a wrapper takes as a command string is looked at here.
function prog_index(    i, x, o, k0) {
  i = 1; sudo_shell = 0
  while (i <= nf) {
    x = f[i]
    if (x ~ /^[A-Za-z_][A-Za-z0-9_]*=/) { vartext = vartext " " x; i++; continue }
    if (x == "function") { i += 2; continue }
    if (x == "time" || x == "command" || x == "builtin" || x == "exec") {
      i++
      while (i <= nf && f[i] ~ /^-/) { o = f[i]; i++; if (x == "exec" && o == "-a") i++ }
      continue
    }
    if (x == "!" || x == "{" || x == "if" || x == "then" || x == "else" || x == "elif" || \
        x == "do" || x == "while" || x == "until" || x == "nohup" || x == "setsid") { i++; continue }
    if (x == "env") {
      i++
      while (i <= nf && f[i] ~ /^-/) {
        o = f[i]; i++
        if (o == "-S" || o == "--split-string") { loose(f[i]); i++ }
        else if (o ~ /^-S./) loose(substr(o, 3))
        else if (o ~ /^-[uCP]$/) i++
      }
      continue
    }
    if (x == "sudo") {
      for (k0 = i + 1; k0 <= nf && f[k0] ~ /^-/; k0++)
        if (f[k0] ~ /^-[A-Za-z]*[si][A-Za-z]*$/) sudo_shell = 1
      i = skipopts(i + 1, "ugCDhprtTU")
      continue
    }
    if (x == "doas")       { i = skipopts(i + 1, "uC"); continue }
    if (x == "nice")       { i = skipopts(i + 1, "n"); continue }
    if (x == "ionice")     { i = skipopts(i + 1, "cnp"); continue }
    if (x == "stdbuf")     { i = skipopts(i + 1, "ioe"); continue }
    if (x == "caffeinate") { i = skipopts(i + 1, "tw"); continue }
    if (x == "arch")       { i = skipopts(i + 1, ""); continue }
    if (x == "xargs")      { i = skipopts(i + 1, "InPLsEda"); continue }
    if (x == "timeout")    { i = skipopts(i + 1, "sk") + 1; continue }
    if (x == "flock") {
      i = skipopts(i + 1, "wE") + 1
      if (f[i] == "-c" || f[i] == "--command") loose(f[i + 1])
      continue
    }
    break
  }
  return i
}

function evaluate(    i, k, p, joined, me, usedpipe, hs, codein) {
  if (nw == 0) return
  usedpipe = psep; psep = 0
  if (!usedpipe) pipetext = ""
  build_f(nw); hs = hsx
  me = ""
  for (k = 1; k <= nf; k++) me = me " " f[k]
  me = me hs
  i = prog_index()
  if (i > nf && sudo_shell) {
    loose(hs)
    if (usedpipe && pipeprog ~ /^(echo|printf|cat)$/) { loose(pipetext); pipedshell = 1 }
  }
  if (i <= nf) {
    p = basename(f[i])
    if (!usedpipe) pipeprog = p
    if (p == "set" && f[i + 1] == "--") {
      setargs = ""
      for (k = i + 2; k <= nf; k++) setargs = setargs " " f[k]
    }
    if (p ~ /^(export|declare|local|readonly|typeset)$/)
      for (k = i + 1; k <= nf; k++) vartext = vartext " " f[k]
    if (p == "git") check_git(i + 1, 2)
    else if (p == "gh") check_gh(i + 1, 2)
    else if (p ~ /^(bash|sh|zsh|dash|ksh|fish|eval|ssh|watch|su|trap)$/) {
      shell_flags(i, p)
      codein = stdin_is_code(i, p)
      joined = ""
      for (k = i + 1; k <= nf; k++) {
        joined = joined " " f[k]
        if (index(f[k], SUBST) > 0 && (p ~ /^(eval|watch|trap|ssh)$/ || fl_c)) loose(subbody)
      }
      if (p !~ /^(bash|sh|zsh|dash|ksh|fish|su)$/ || fl_c) {
        loose(joined)
        if (index(joined, "$") > 0) loose(vartext)
      }
      if (codein) {
        loose(hs)
        if (usedpipe && pipeprog ~ /^(echo|printf|cat)$/) { loose(pipetext); pipedshell = 1 }
      }
    }
    else if (p ~ /^(docker|podman|kubectl|lima|limactl|vagrant|multipass|nsenter|chroot)$/ && has_runner_cmd(i)) {
      joined = ""
      for (k = i + 1; k <= nf; k++) joined = joined " " f[k]
      loose(joined)
    }
    else if (p !~ /^(echo|printf|grep|egrep|fgrep|rg|ag|cat|head|tail|less|more|wc|sort|uniq|tee|cut|tr|sed|awk|diff|cmp|ls|man|which|type|touch|rm|mkdir|cp|mv|ln|stat|file|basename|dirname|cd|export|set|source|read|test|true|false|exit|return|local|declare|unset|alias|pwd|pushd|popd|jq|curl|wget|for|in|select|case|esac|done|fi|function|\[|\[\[)$/)
      tokscan(i, f[i])
  }
  pipetext = pipetext " " me
  if (sp > 1) subbody = subbody " " me "\n"
  else { pipetext = pipetext " " subbody; subbody = "" }
}

function endword() {
  if (!inword) return
  if (want) {
    np++; pd[np] = cur; pdash[np] = wantdash; want = 0
    pshell[np] = is_shell_cmd(); psub[np] = (sp > 1); pbody[np] = ""; pbody2[np] = ""
  }
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
  cur = ocur[sp] SUBST; inword = 1; nw = onw[sp]
  for (k = 1; k <= nw; k++) w[k] = ow[sp, k]
  sp--
}

# Index just past the `))` that closes the arithmetic opened by the `((` at i, or
# 0 when it is not arithmetic. Bash decides by the paren that closes the SECOND
# `(`: it must be followed at once by `)`. So `((1+(2)))` is arithmetic while
# `((cd a); (cmd))` is two nested subshells and stays scannable. Without this,
# the `<<` of `$((1<<2))` opened a heredoc and swallowed every later line.
function arith_end(s, i,    d, L, c, seen1) {
  L = length(s); d = 0; seen1 = 0
  while (i <= L) {
    c = substr(s, i, 1)
    if (c == "(") d++
    else if (c == ")") {
      d--
      if (d == 1 && !seen1) { seen1 = 1; if (substr(s, i + 1, 1) != ")") return 0 }
      if (d == 0) return i + 1
    }
    i++
  }
  return 0
}

# Index just past the `}` / `)` matching the opener at i, on this line, or 0.
# Does s[a..b) hold a command substitution? An opaque span that does is scanned
# normally instead, so `[[ -n "$(git commit)" ]]` keeps its command visible.
function has_sub(s, a, b) {
  return index(substr(s, a, b - a), "$(") > 0 || index(substr(s, a, b - a), BT) > 0
}

function close_at(s, i, opn, cls,    d, L, c) {
  L = length(s); d = 0
  while (i <= L) {
    c = substr(s, i, 1)
    if (c == opn) d++
    else if (c == cls) { d--; if (d == 0) return i + 1 }
    i++
  }
  return 0
}

function scan(s,    i, L, c, c2, nx, prev, top, dash, op, e, k, rest) {
  L = length(s); i = 1
  if (arr_open > 0) {
    # This line is part of a `name=(` array literal whose closing `)` is on a
    # later line. Count parens to learn whether the array closes here; while it
    # does not, the content is opaque (bare words are data). When it closes, a
    # substitution it held is scanned so a command inside it stays visible, and
    # the rest of the line is scanned normally.
    for (k = 1; k <= L; k++) {
      c = substr(s, k, 1)
      if (c == "(") arr_open++
      else if (c == ")") { arr_open--; if (arr_open == 0) { k++; break } }
    }
    if (arr_open > 0) { arr_buf = arr_buf s "\n"; return }
    if (index(arr_buf, "$(") > 0 || index(arr_buf, BT) > 0) scan_text(arr_buf)
    arr_buf = ""
    s = substr(s, k); L = length(s); i = 1
    if (L <= 0) return
  }
  while (i <= L) {
    c = substr(s, i, 1); c2 = substr(s, i, 2); top = st[sp]
    if (top == "sq") {
      if (c == SQ) sp--
      else { cur = cur c; inword = 1 }
      i++; continue
    }
    if (top == "ansi") {
      if (c == "\\") { cur = cur substr(s, i + 1, 1); inword = 1; i += 2; continue }
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
      if (substr(s, i, 3) == "$((" && (e = arith_end(s, i + 1)) > 0 && !has_sub(s, i + 3, e)) { cur = cur "A"; inword = 1; i = e; continue }
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
    if (substr(s, i, 3) == "$((" && (e = arith_end(s, i + 1)) > 0 && !has_sub(s, i + 3, e)) { cur = cur "A"; inword = 1; i = e; continue }
    if (c2 == "((" && (e = arith_end(s, i)) > 0 && !has_sub(s, i, e)) { cur = cur "A"; inword = 1; i = e; continue }
    if (c2 == "$" SQ) { sp++; st[sp] = "ansi"; inword = 1; i += 2; continue }
    if (c2 == "${" && (e = close_at(s, i + 1, "{", "}")) > 0 && !has_sub(s, i, e)) { cur = cur "P"; inword = 1; i = e; continue }
    if (c2 == "$[" && (k = index(substr(s, i + 2), "]")) > 0 && !has_sub(s, i, i + k + 2)) { cur = cur "A"; inword = 1; i += k + 2; continue }
    if (c2 == "[[" && !inword && substr(s, i + 2, 1) ~ /[ \t]/ && (k = index(substr(s, i + 2), " ]]")) > 0 && !has_sub(s, i, i + k + 4)) {
      cur = cur "T"; inword = 1; i += k + 4; continue
    }
    if (c == "(" && inword && cur ~ /^[A-Za-z_][A-Za-z0-9_]*[+]?=$/ && (e = close_at(s, i, "(", ")")) > 0 && !has_sub(s, i, e)) {
      vartext = vartext " " substr(s, i, e - i)
      cur = cur "A"; i = e; continue
    }
    if (c == "(" && inword && cur ~ /^[A-Za-z_][A-Za-z0-9_]*[+]?=$/ && close_at(s, i, "(", ")") == 0) {
      # `name=(` whose closing `)` is not on this line: the array spans lines, so
      # its content must not be read as commands. Buffer the rest of this line
      # and let the pending-array handler at the top of scan() finish it.
      arr_open = 1
      rest = substr(s, i + 1)
      e = length(rest)
      for (k = 1; k <= e; k++) {
        c = substr(rest, k, 1)
        if (c == "(") arr_open++
        else if (c == ")") arr_open--
      }
      cur = cur "A"
      if (arr_open > 0) arr_buf = rest "\n"; else arr_open = 0
      i = L + 1
      continue
    }
    if (c2 == "$(") { push("sub"); i += 2; continue }
    if (c == BT) {
      if (kind[sp] == "bt") pop(); else push("bt")
      i++; continue
    }
    if (c == ";") { endcmd(); psep = 0; i++; continue }
    if (c == "|") {
      nx = substr(s, i + 1, 1)
      endcmd()
      if (nx == "|") { psep = 0; i += 2; continue }
      psep = 1
      i += (nx == "&") ? 2 : 1
      continue
    }
    if (c == "&") {
      prev = substr(s, i - 1, 1); nx = substr(s, i + 1, 1)
      if (prev == ">" || prev == "<" || nx == ">") { cur = cur c; inword = 1; i++; continue }
      endcmd(); psep = 0; i++; continue
    }
    if (c == "(") { endcmd(); depth[sp]++; i++; continue }
    if (c == ")") {
      if (depth[sp] > 0) { depth[sp]--; endcmd() }
      else if (kind[sp] == "sub") pop()
      else endcmd()
      i++; continue
    }
    if (c2 == "<<") {
      if (substr(s, i, 3) == "<<<") { endword(); cur = "<<<"; inword = 1; endword(); i += 3; continue }
      dash = (substr(s, i + 2, 1) == "-")
      endword(); want = 1; wantdash = dash
      i += 2 + dash; continue
    }
    if (c == ">" || c == "<") {
      # A redirection ends the word before it, unless that word is only an fd
      # number or the `&` of `&>`. Without this, `<<EOF>file` made the delimiter
      # `EOF>file`, which never closed, and the heredoc swallowed every later line.
      if (inword && cur !~ /^([0-9]+|&)$/) endword()
      op = c; nx = substr(s, i + 1, 1)
      if (c == ">" && (nx == ">" || nx == "|" || nx == "&")) { op = op nx; i++ }
      else if (c == "<" && (nx == ">" || nx == "&")) { op = op nx; i++ }
      cur = cur op; inword = 1; endword()
      i++; continue
    }
    cur = cur c; inword = 1; i++
  }
}

BEGIN {
  SQ = "\047"; DQ = "\042"; BT = "\140"
  SUBST = "\001"
  nverbs = split(verbs, V, ",")
  best = 0; bestpr = 0
  sp = 1; st[1] = "cmd"; kind[1] = "top"; depth[1] = 0
  nw = 0; cur = ""; inword = 0
  np = 0; pi = 1; hdactive = 0; want = 0
  psep = 0; vartext = ""; setargs = ""; subbody = ""; pipetext = ""; pipeprog = ""; pipedshell = 0
  arr_open = 0; arr_buf = ""
}

{
  raw = raw $0 "\n"
  feed($0)
}

END {
  if (arr_open > 0) { arr_open = 0; scan_text(arr_buf); arr_buf = "" }
  endcmd()
  if (hdactive && pshell[pi]) loose(pbody[pi])
  if (hdactive && pipedshell) loose(pbody2[pi])
  if (sp > 1) loose(raw)
  print word(best) " " word(bestpr)
}
'
}

command_match() {
  local out
  out=$(command_match_scan "$@")
  printf '%s\n' "${out%% *}"
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
