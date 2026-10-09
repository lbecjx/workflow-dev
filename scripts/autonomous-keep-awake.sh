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
# It prints one status word (plus a PID) on stdout and the agent writes the
# chat notice in the conversation's language — a script cannot know that
# language (references/user-language.md, "Out of scope"):
#
#   started <pid>   launched a new caffeinate
#   running <pid>   ours is already alive; nothing launched (one per session)
#   stopped <pid>   ours was alive and is now ended
#   not-running     no caffeinate of ours is alive (already gone is not an error)
#   unsupported     not macOS, or no caffeinate: skipped, nothing written
#   no-session      no Claude Code session PID to tie caffeinate to: skipped
#
# Those are all normal outcomes and exit 0, because none of them may stop the
# run. A usage error exits 2; an untrusted marker directory, or a lock another
# live call holds for over ~5 s, exits 1 with the reason on stderr (the agent
# reports it as a skip and the run goes on).
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
# ## Why `stop` checks the command line, not just the PID
#
# The human may run caffeinate themselves, and other sessions may run their
# own; `killall caffeinate` would end those too. And a PID saved in the marker
# may have been reused by an unrelated process since. So a process is only ours
# when it belongs to this user and its command line is exactly
# `caffeinate -i -w <this session>` (see is_our_command). Anything else is left
# alone — including a caffeinate the human started with the very same
# arguments: only the PID this script saved is ever ended.
#
# Known limit, stated on purpose: caffeinate does not stop the sleep that comes
# from closing a laptop lid with no external display. Linux (`systemd-inhibit`)
# is out of scope: there the script answers `unsupported`.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=marker-dir.sh
source "$HERE/marker-dir.sh"

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

# 0 when the command line $1 is a caffeinate this script launches for session
# $2: `[<one word> ]<path>/caffeinate -i -w <session>`, nothing before or after.
# The one optional leading word covers `nohup` (the instant before it execs) and
# an interpreter running a test double (`/bin/bash <path>/caffeinate ...`). A
# shell whose `-c` string merely ends with those words has more than one word
# in front, so it never matches.
is_our_command() {
  local cmd="$1" session="$2" re
  re="^([^ ]+ )?([^ ]*/)?caffeinate -i -w ${session}\$"
  [[ "$cmd" =~ $re ]]
}

# 0 when $1 is a live caffeinate that this script launched for session $2.
owned_alive() {
  local pid="$1" session="$2" cmd
  is_pid "$pid" || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  cmd="$(ps -o command= -p "$pid" 2>/dev/null)" || return 1
  is_our_command "$cmd" "$session"
}

# Serialises `start` and `stop` for one session. Without it, two `start` calls
# in the same instant (parallel tool calls) both saw no caffeinate, both
# launched one, and the marker kept only the second: `stop` then ended one and
# the other kept the Mac awake until the session closed (found by WD-0055's
# adversarial pass).
#
# `mkdir` is atomic, so it is the lock; it holds the holder's PID. A lock is
# stale when its holder is gone: the PID is dead, or now belongs to a process
# that is not this script (PID reuse), or the PID file stayed empty for ~3 s
# (the holder died between `mkdir` and the write). Taking a stale lock over is
# guarded by a second `mkdir` (`.takeover`, also holding a PID and stale on
# the same terms), and the winner removes the lock only if it still names the
# same dead holder. A plain `rm` + `mkdir` let two waiters each delete the
# other's fresh lock and both launch. A lock held by a live call for longer
# than a few seconds is reported (exit 1), never waited on longer.
LOCK=""
release_lock() {
  [[ -n "$LOCK" && "$(cat "$LOCK/pid" 2>/dev/null)" == "$$" ]] && rm -rf "$LOCK"
}
pid_in() {
  head -c 16 "$1/pid" 2>/dev/null | tr -cd '0-9'
}
holder_alive() {
  is_pid "$1" && kill -0 "$1" 2>/dev/null \
    && [[ "$(ps -o command= -p "$1" 2>/dev/null)" == *autonomous-keep-awake* ]]
}
take_lock() {
  local lock="$1" guard="$1.takeover" tries=0 empty=0 guard_empty=0 holder g
  while :; do
    if mkdir "$lock" 2>/dev/null; then
      # The write fails only if a takeover removed the lock in between; then
      # it is not ours, so compete again rather than run unlocked.
      printf '%s\n' "$$" > "$lock/pid" 2>/dev/null && break
      continue
    fi
    tries=$((tries + 1))
    holder="$(pid_in "$lock")"
    if [[ -z "$holder" ]]; then empty=$((empty + 1)); else empty=0; fi
    # The guard is checked on every try, with a shorter grace than the lock,
    # so a dead guard is always gone by the time a stale lock is taken over:
    # both left empty by killed calls would otherwise block the session. The
    # empty count resets whenever the guard is missing: summed across different
    # guards, it let one waiter remove another's guard in the instant between
    # its `mkdir` and its PID write, and both then took the lock over.
    if [[ -d "$guard" ]]; then
      g="$(pid_in "$guard")"
      if [[ -z "$g" ]]; then guard_empty=$((guard_empty + 1)); else guard_empty=0; fi
      if { [[ -n "$g" ]] && ! holder_alive "$g"; } || (( guard_empty >= 20 )); then
        rm -rf "$guard"; guard_empty=0
      fi
    else
      guard_empty=0
    fi
    if { [[ -n "$holder" ]] && ! holder_alive "$holder"; } || (( empty >= 30 )); then
      if mkdir "$guard" 2>/dev/null; then
        printf '%s\n' "$$" > "$guard/pid" 2>/dev/null
        [[ "$(pid_in "$lock")" == "$holder" ]] && rm -rf "$lock"
        rm -rf "$guard"
        empty=0
        continue
      fi
    fi
    if (( tries >= 40 )); then
      printf 'keep-awake lock is held by process %s\n' "${holder:-unknown}" >&2
      return 1
    fi
    sleep 0.1
  done
  LOCK="$lock"
  trap release_lock EXIT
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

# Platform first, so a non-macOS run touches nothing on disk.
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

dir="$(marker_root)/keep-awake"
marker="$dir/$watch.pid"

reason="$(marker_chain_reason "$dir")" || true
if [[ -n "$reason" ]]; then
  printf 'keep-awake marker directory cannot be trusted: %s\n' "$reason" >&2
  exit 1
fi

if [[ "$action" != "status" ]]; then
  marker_ensure_dir "$dir" || exit 1
  take_lock "$dir/$watch.lock" || exit 1
fi

saved=""
if [[ -f "$marker" ]]; then
  saved="$(head -c 32 "$marker" 2>/dev/null | tr -d '[:space:]')"
fi

case "$action" in
  status)
    if owned_alive "$saved" "$watch"; then echo "running $saved"; else echo "not-running"; fi
    ;;
  start)
    if owned_alive "$saved" "$watch"; then
      echo "running $saved"; exit 0
    fi
    # nohup + full redirection: the Bash tool's shell exits when the call
    # returns, and caffeinate must outlive it (it is reparented to launchd).
    nohup "$cafe" -i -w "$watch" </dev/null >/dev/null 2>&1 &
    pid=$!
    printf '%s\n' "$pid" | marker_write "$marker" || { kill "$pid" 2>/dev/null; exit 1; }
    echo "started $pid"
    ;;
  stop)
    if owned_alive "$saved" "$watch" && kill "$saved" 2>/dev/null; then
      rm -f "$marker"
      echo "stopped $saved"
    else
      # Gone already, never ours, or garbage: nothing to end. The stale marker
      # goes; any process it pointed at that is not ours stays untouched.
      [[ -e "$marker" || -L "$marker" ]] && rm -f "$marker"
      echo "not-running"
    fi
    ;;
esac
exit 0
