#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Keeps the Mac awake while an autonomous run works (WD-0055), and lets it
# sleep again when the run ends. The agent runs it; no hook does. The rules for
# when to call `start` and `stop` live in references/autonomous-mode.md
# ("Keeping the Mac awake"); this file only owns the mechanics.
#
#   autonomous-keep-awake.sh start|stop|status [--watch <pid>]
#
# It prints one status word (plus PIDs) on stdout and the agent writes the
# chat notice in the conversation's language — a script cannot know that
# language (references/user-language.md, "Out of scope"):
#
#   started <pid>    launched a new caffeinate
#   running <pid>    one for this session is already alive; nothing launched
#   stopped <pid...> this session's caffeinate is ended
#   not-running      none for this session is alive (already gone is not an error)
#   unsupported      not macOS, or no caffeinate: skipped
#   no-session       no Claude Code session PID to tie caffeinate to: skipped
#   unknown          pgrep failed; nothing launched or ended
#
# All of them exit 0, because none may stop the run. Only a usage error exits 2.
#
# ## Why `-i -w <session>` and nothing else
#
# - `-i` holds PreventUserIdleSystemSleep only: the system does not idle-sleep,
#   but the display still turns off and the screen still locks. `-d` (keep the
#   display on) and `-u` (declare user activity, which also defers the lock)
#   would leave an unattended Mac unlocked, so they are never used. `-s` adds
#   nothing for idle sleep and only applies on AC power.
# - `-w <session pid>` ends caffeinate when the Claude Code session ends, so a
#   closed or crashed session never leaves the Mac awake for good. The PID of
#   the Bash tool's own shell would be useless here: that shell exits as soon as
#   the tool call returns.
#
# ## The session PID is the identity
#
# There is no PID file and no lock. The command line `caffeinate -i -w
# <session>` names the session it belongs to, so `pgrep` on it answers "is
# ours running?" and `pkill` on it ends it. Only this user's processes match,
# and only that exact command line: another session's caffeinate (another
# `-w`), or the human's `caffeinate -t …`, is never touched. The executable
# must be the full path this script launches, so a caffeinate the human types
# by hand (argv `caffeinate …`) is not ours either. If pgrep fails (any exit
# but 0 or 1), the answer is `unknown` and nothing is launched or ended. Each
# `start` and `stop` is a sequential step of the run (`start` repeats at every
# task group), so two calls racing each other is not a case this handles.
#
# Known limit, stated on purpose: caffeinate does not stop the sleep that comes
# from closing a laptop lid with no external display. Linux (`systemd-inhibit`)
# is out of scope: there the script answers `unsupported`.

set -u

usage() {
  printf 'usage: %s start|stop|status [--watch <pid>]\n' "$(basename "$0")" >&2
  exit 2
}

is_pid() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 > 1 ))
}

# The Claude Code session process: `CLAUDE_PID` (Claude Code exports it into the
# Bash tool's shell, measured 2026-10-09), else the nearest ancestor whose
# command name is `KEEP_AWAKE_SESSION_COMM` (default `claude`). The name is
# configurable only so the tests can prove the `no-session` path while they
# themselves run inside a Claude Code session.
find_session() {
  local want="${KEEP_AWAKE_SESSION_COMM:-claude}" pid="$$" line ppid comm hops=0
  if [[ -n "${CLAUDE_PID:-}" ]] && is_pid "$CLAUDE_PID" && kill -0 "$CLAUDE_PID" 2>/dev/null; then
    printf '%s' "$CLAUDE_PID"
    return 0
  fi
  # Bounded walk: a cycle is impossible in a real process table, but a bound
  # costs nothing and keeps a broken `ps` from looping forever.
  while (( hops < 64 )); do
    line="$(ps -o ppid= -o comm= -p "$pid" 2>/dev/null)" || return 1
    ppid="$(printf '%s' "$line" | awk '{print $1}')"
    comm="$(printf '%s' "$line" | sed -E 's/^ *[0-9]+ +//')"
    comm="${comm##*/}"
    comm="${comm#-}"
    if [[ "$pid" != "$$" && "$comm" == "$want" ]]; then
      printf '%s' "$pid"
      return 0
    fi
    is_pid "$ppid" || return 1
    pid="$ppid"
    hops=$((hops + 1))
  done
  return 1
}

[[ $# -ge 1 ]] || usage
action="$1"; shift
case "$action" in start|stop|status) ;; *) usage ;; esac

watch=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --watch)
      [[ $# -ge 2 ]] || usage
      is_pid "$2" || usage
      watch="$2"; shift 2 ;;
    *) usage ;;
  esac
done

# Platform first, so a non-macOS run does nothing at all.
if [[ "$(uname -s 2>/dev/null)" != "Darwin" ]]; then
  echo "unsupported"; exit 0
fi
cafe="$(command -v caffeinate 2>/dev/null)" || cafe=""
if [[ -z "$cafe" ]]; then
  echo "unsupported"; exit 0
fi

if [[ -z "$watch" ]]; then
  watch="$(find_session)" || watch=""
fi
if [[ -z "$watch" ]] || ! kill -0 "$watch" 2>/dev/null; then
  echo "no-session"; exit 0
fi
# One spelling per session: `0123` and `123` are the same process, and the
# command line has to be matched the way it was launched.
watch=$((10#$watch))

# This user's caffeinate for this session: exactly the caffeinate this script
# launches (`$cafe`, resolved from PATH above) followed by exactly `-i -w
# <session>` and nothing after it, so session 12 never matches 123. A process
# that only names caffeinate in its arguments (`less caffeinate …`), or another
# executable that happens to be called caffeinate, never matches. The one
# prefix allowed is /bin/bash or /bin/sh, which is how a shell-script test
# double at that same path shows up in the process table.
cafe_re="$(printf '%s' "$cafe" | sed 's/[][\\.*^$+?(){}|]/\\&/g')"
pattern="^(/bin/(ba)?sh )?${cafe_re} -i -w ${watch}\$"

# pgrep exits 0 on a match and 1 on none; anything else means it could not
# look (a sandbox, a broken process table). Then the answer is unknown, and
# start must not launch a second caffeinate, nor stop kill blindly.
pids=""
ours() {
  local out rc
  out="$(pgrep -U "$(id -u)" -f "$pattern" 2>/dev/null)"; rc=$?
  case "$rc" in
    0) pids="$(printf '%s' "$out" | tr '\n' ' ' | sed 's/ $//')"; return 0 ;;
    1) pids=""; return 0 ;;
    *) return 1 ;;
  esac
}

if ! ours; then
  echo "unknown"; exit 0
fi

case "$action" in
  status)
    if [[ -n "$pids" ]]; then echo "running $pids"; else echo "not-running"; fi
    ;;
  start)
    # Safe to call again and again: one alive → `running`; none (never
    # started, or it died) → launch a new one.
    if [[ -n "$pids" ]]; then
      echo "running $pids"; exit 0
    fi
    # nohup + full redirection: the Bash tool's shell exits when the call
    # returns, and caffeinate must outlive it (it is reparented to launchd).
    nohup "$cafe" -i -w "$watch" </dev/null >/dev/null 2>&1 &
    echo "started $!"
    ;;
  stop)
    if [[ -n "$pids" ]] && pkill -U "$(id -u)" -f "$pattern" 2>/dev/null; then
      echo "stopped $pids"
    else
      echo "not-running"
    fi
    ;;
esac
exit 0
