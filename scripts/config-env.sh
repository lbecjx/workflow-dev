#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# The one owner of workflow-dev's two settings files, sourced by every script
# that reads or writes them, and run as a small CLI by the skills:
#
#   ~/.workflow-dev/config.env     this machine: notifications=on|off
#   .workflow-dev/config.env       this repo:    gitignored=true|false
#                                                language=<ISO 639-1 code>
#                                                agentCoauthorship=yes|no
#                                                tiering=default
#
# One `key=value` per line, the dotenv shape, never named `.env`: Vite, Docker
# Compose and `dotenv` load a `.env` they find in a project by themselves.
#
# Why not JSON any more: bash cannot read JSON, so every read and write went
# through jq, else perl, plus a lock, a symlink walk and checks against two
# documents or a NUL byte. Each validation found new bugs in that machinery
# (jq and perl disagreeing, a near-quadratic write on bash 3.2, a NUL that left
# the alerts stuck on, a lock race that lost writes). Bash reads this format
# with `read` alone and replaces it whole with `mv`.
#
# Reading: line by line, never `source` or `eval`. A value is the text after the
# first `=`, kept verbatim, so `$(…)`, quotes or backticks are data and nothing
# runs. A key counts only at the start of its line (no spaces, no `export`). A
# trailing CR is dropped (a file saved on Windows), and the last line of a key
# wins, except for the strict keys below. Bash's `read` drops NUL bytes, so the reader and the writer always see
# the same text; a caller that must refuse a NUL checks the bytes itself
# (coauthor-decision.sh).
#
# Writing: every other line is copied, `key=value` is appended, and the result
# replaces the file through a temp file in the same folder and `mv`, under a
# kernel lock (see config_env_set), so two writers never drop each other's keys.
#
# Older versions kept these answers in `config.json`. That file is ignored, not
# read and not deleted: reading it needs jq or perl, the very tools this format
# drops, so each answer is asked once again.
#
#   config-env.sh get <key>            the repo's value, or nothing (exit 1)
#   config-env.sh set <key> <value>    write it (exit 1 when it cannot)
#
# Both act on `.workflow-dev/config.env` under the current directory. Sourcing defines functions only, with no side effects.

# Keys that are never read two ways: agentCoauthorship lets attribution into a
# commit, so written twice it reads as missing (not the last line), and the
# skills and the commit hook agree that there is no answer.
CONFIG_ENV_STRICT_KEYS="agentCoauthorship"

config_env_key_ok() { # config_env_key_ok <key>
  [[ "${1:-}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]
}

# The file a config path stands for. A symlinked config (dotfiles) is read and
# written where it points: `mv` onto the link itself would replace the link with
# a plain file and leave the real one behind. A chain longer than ten links to a
# real file is refused (exit 1) for reading and writing alike, so a read never
# sees a file a write would not touch. A chain that ends nowhere (a loop, a
# dangling link) is returned as is: there is no target to keep.
config_env_target() { # config_env_target <path>
  local file="$1" link hops=0
  while [[ -L "$file" && $hops -lt 10 ]]; do
    link="$(readlink "$file")"
    case "$link" in /*) file="$link" ;; *) file="${file%/*}/$link" ;; esac
    hops=$((hops + 1))
  done
  [[ -L "$file" && -e "$file" ]] && return 1
  printf '%s' "$file"
}

# Prints the value of <key>, exit 0; nothing and exit 1 when there is no file or
# no such line.
config_env_get() { # config_env_get <file> <key>
  local file key="$2" line value found=0
  config_env_key_ok "$key" || return 1
  file="$(config_env_target "$1")" || return 1
  [[ -f "$file" && -r "$file" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    # Not ${line%$'\r'}: on bash 3.2 that is quadratic in the line's length, and
    # a cloned repo controls this file (a 1 MB line took minutes per hook).
    [[ "$line" == *$'\r' ]] && line="${line:0:${#line}-1}"
    case "$line" in
      "$key="*) value="${line#*=}"; found=$((found + 1)) ;;
    esac
  done < "$file"
  [[ $found -gt 0 ]] || return 1
  # A strict key written twice is two answers, not one: no answer at all.
  case " $CONFIG_ENV_STRICT_KEYS " in
    *" $key "*) [[ $found -eq 1 ]] || return 1 ;;
  esac
  printf '%s' "$value"
}

# The lines of <file> without any line of <key>, CRs dropped, each ending in a
# newline. A missing file prints nothing.
config_env_others() { # config_env_others <file> <key>
  local line
  [[ -f "$1" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    # Not ${line%$'\r'}: on bash 3.2 that is quadratic in the line's length, and
    # a cloned repo controls this file (a 1 MB line took minutes per hook).
    [[ "$line" == *$'\r' ]] && line="${line:0:${#line}-1}"
    case "$line" in "$2="*) continue ;; esac
    printf '%s\n' "$line"
  done < "$1"
}

# Exit 1, file untouched, for a bad key, a value with a line break, an
# unreadable file, a folder that cannot be written, or a lock not had in 5 s.
#
# Two writers of different keys at once (an agent running two `set`s in
# parallel) would each copy the other lines before either wrote, and the last
# `mv` would drop the other key. So the read-copy-replace runs under a kernel
# lock (flock(2), through macOS's lockf(1) or util-linux's flock(1)) on a
# `<file>.lock` beside it. Not a lock folder: the kernel drops the lock when
# the process ends, however it ends, so nothing is ever left to clean up, and
# the empty `.lock` file stays harmless. With neither tool the write runs
# unlocked, as before.
config_env_set() { # config_env_set <file> <key> <value>
  local file key="$2" value="${3-}" dir
  config_env_key_ok "$key" || return 1
  case "$value" in *$'\n'*|*$'\r'*) return 1 ;; esac
  file="$(config_env_target "$1")" || return 1
  [[ -d "$file" ]] && return 1
  [[ ! -e "$file" || -r "$file" ]] || return 1
  # Opening a lock that is a link would create or touch its target, which a
  # cloned repo could point anywhere.
  [[ -L "$file.lock" ]] && return 1
  dir="${file%/*}"
  [[ "$dir" != "$file" ]] || dir=.
  ( umask 077 && mkdir -p "$dir" ) 2>/dev/null || return 1
  (
    # A lock that cannot be opened (a folder in its place) is no reason to
    # write unlocked: refuse instead.
    exec 9>>"$file.lock" || exit 1
    if command -v lockf >/dev/null 2>&1; then
      lockf -s -t 5 9 || exit 1
    elif command -v flock >/dev/null 2>&1; then
      flock -w 5 9 || exit 1
    fi
    config_env_write "$file" "$key" "$value"
  ) 2>/dev/null
}

# One read-copy-replace of <file> with `key=value`.
config_env_write() { # config_env_write <file> <key> <value>
  local file="$1" dir tmp
  dir="${file%/*}"
  [[ "$dir" != "$file" ]] || dir=.
  ( umask 077 && mkdir -p "$dir" ) 2>/dev/null || return 1
  tmp="$(mktemp "$dir/.config.env.XXXXXX" 2>/dev/null)" || return 1
  # cp -p first, so the new file keeps the old one's mode.
  [[ -f "$file" ]] && cp -p "$file" "$tmp" 2>/dev/null
  if { { config_env_others "$file" "$2" && printf '%s=%s\n' "$2" "$3"; } > "$tmp"; } 2>/dev/null \
    && mv "$tmp" "$file" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# The repo's config file, or exit 1 when a link is in the way. Unlike the
# machine's file, a repo's `.workflow-dev` comes from whoever made the clone, so
# it is never followed out: a committed link `.workflow-dev/config.env ->
# ~/.zshenv` would otherwise have `set` write the repo's values into the user's
# shell startup. A link at `.workflow-dev` or at `config.env` makes the repo
# config unreadable and unwritable: no answer, as if the file were missing.
repo_config_file() { # repo_config_file <root>
  local dir="$1/.workflow-dev"
  [[ -L "$dir" || -L "$dir/config.env" ]] && return 1
  printf '%s/config.env' "$dir"
}

# The repo's value of <key>; same exits as config_env_get.
repo_config_get() { # repo_config_get <root> <key>
  local file
  file="$(repo_config_file "$1")" || return 1
  config_env_get "$file" "$2"
}

repo_config_set() { # repo_config_set <root> <key> <value>
  local file
  file="$(repo_config_file "$1")" || return 1
  config_env_set "$file" "$2" "${3-}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}:$#" in
    get:2) repo_config_get . "$2" && printf '\n' ;;
    set:3) repo_config_set . "$2" "$3" ;;
    *) printf 'usage: config-env.sh get <key> | set <key> <value>\n' >&2; exit 2 ;;
  esac
fi
