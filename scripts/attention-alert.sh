#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Plays workflow-dev's attention sounds (WD-0052): short spoken alerts that
# mean "workflow-dev needs you, or finished something you should review" — and
# nothing else. Claude Code's own alerts (a user `Stop` hook,
# `Notification:idle_prompt`, the terminal bell) fire after almost every
# response, so the human learns to ignore them; these are worth trusting only
# because they stay quiet the rest of the time.
#
# Eleven sounds, one per meaning (assets/attention-<kind>.wav):
#
#   need        "I need your input."        a question waits on the human
#   away        "Hello? Are you there?" … "I need your input."
#                                           the same, mid autonomous run
#   permission  "I need your permission."   a permission dialog is open
#   commit      "Ready to commit."          commit/PR text waits for the human's yes
#   pr          "Pull request created!"     the PR was just opened
#   done        "Task completed."           something is ready to review
#   passed      "Validation passed."        the quality gate passed
#   fail        "Something went wrong."     a check failed, or the run is stuck
#   saved       "Context saved."            a save the human asked for finished
#   story       fanfare + "Congrats! Story complete."
#   start       "Ok, let's start!"          the alerts were just turned on (played, never armed)
#
#   attention-alert.sh play [kind]   play one now (default need; also a preview)
#   attention-alert.sh arm [kind]    a skill says "the turn I am ending hands
#                                    control to the human" — the next Stop plays
#                                    that kind (default need)
#   attention-alert.sh --stop        Stop hook: plays only when this session is armed
#   attention-alert.sh --ask         PreToolUse:AskUserQuestion hook (need; away mid autonomous run)
#   attention-alert.sh --notify      Notification:permission_prompt hook (permission)
#   attention-alert.sh --prompt      UserPromptSubmit hook: drops a stale arm
#   attention-alert.sh devices | suggest
#                                    the audio outputs, and the built-in one (below)
#
# An unknown kind falls back to `need`: a typo in a skill must still call the
# human, never go silent. When to arm, and with which kind, is the skills' rule,
# owned by references/attention-alert.md; this file only owns the mechanics.
#
# ## Configuration — none in the environment
#
# Whether a story sounds, and on which output, is its `notifications` entry in
# `.workflow-dev/config.json` and nothing else (see "Alerts are per story"
# below). No environment variable is read to switch the alerts off
# (WORKFLOW_DEV_ATTENTION), to swap the sound (WORKFLOW_DEV_ATTENTION_SOUND) or
# to force the output (WORKFLOW_DEV_ATTENTION_DEVICE): each of them was a second
# control that could override the story's own, silencing or redirecting a story
# the human had just turned on, with no sign of why. Removed in WD-0072.
#
# It is silent, whatever the story says, in CI (`CI` set to anything but
# `false`/`0`) and in a non-interactive session: Claude Code exports
# `CLAUDE_CODE_SESSION_ATTENDED=1` to an interactive session and `0` under
# `claude -p` (measured 2026-10-10). A missing variable (an older Claude Code)
# counts as attended, so the sound is not lost on an upgrade path.
#
# ## Why a plain Stop is silent, and how each event sounds once
#
# A `Stop` fires after every response; sounding on it is exactly the noise this
# replaces. So `--stop` plays only when a skill armed the session first. The
# arm is one file per session (re-arming overwrites it, never queues), and
# `--stop` consumes it with a single `mv`: of two hooks racing for it, only one
# `mv` succeeds, and the next Stop finds nothing. Every play also deletes the
# session's arm, so a question asked through the ask tool and the Stop that ends
# the same turn sound once, not twice. A new prompt from the human clears the
# arm too (`--prompt`, on UserPromptSubmit): a turn the human interrupts ends
# without a Stop, and its arm must not sound at the end of the next, ordinary
# response.
#
# The dedupe window is narrow on purpose: only an ask followed by a permission
# prompt within DEDUPE_SECONDS is one event — the question, then the dialog it
# raised. A prompt followed by an ask, two asks, two prompts, or an armed Stop
# are separate events and always sound; a window over every play silenced a
# task group's hand-back that came right after an approved permission prompt.
# The check-then-write of that timestamp can race; the worst case is a second
# sound, never a block, so it is accepted rather than locked.
#
# One limit no command hook can close: Claude Code runs a session's Stop hooks
# side by side and tells none of them what the others decided. If another
# plugin's Stop hook blocks the stop (`decision: block`), the turn goes on after
# this one already played. The arm was consumed, so the turn's real end is
# silent; the sound came early, never twice.
#
# `--ask` and `--notify` play only in a workflow-dev project (`.workflow-dev/context`
# in the session's cwd or one of its parents, as when Claude Code runs in a
# package of a monorepo): hooks run for every project on the machine, and a
# hook cannot see which skill asked. `idle_prompt` is never registered — it
# fires after any response, blocked or not.
#
# Files live in the shared marker store (scripts/marker-dir.sh), keyed by the
# session id, which must match ^[A-Za-z0-9_-]+$ before it becomes part of a
# path. An untrusted store means no sound: a planted file can at worst cause a
# beep, so there is nothing to ask the human about.
#
# ## Never in the way
#
# The player runs detached with all three streams on /dev/null, so a hook that
# calls this returns at once, even while the sound plays. Nothing is printed,
# and every path exits 0 — a sound must never fail or slow down the step that
# asked for it. Only a usage error exits 2.

set -u

usage() {
  printf 'usage: %s play [kind] | play start <output> | arm [kind] | --stop | --ask | --notify | --prompt | devices | suggest | set-pref <device> | pref | activate <story> <device> | deactivate <story> | entries | active | offer | prune\n' "${0##*/}" >&2
  exit 2
}

# `need` for anything that is not one of the eleven kinds (see the header).
alert_kind() {
  case "${1:-}" in
    need|away|permission|commit|pr|done|passed|fail|saved|story|start) printf '%s' "$1" ;;
    *) printf 'need' ;;
  esac
}

# Parameter expansion, not `dirname`: this runs on every Stop of every project.
case "$0" in
  */*) HERE="${0%/*}" ;;
  *) HERE=. ;;
esac
HERE="$(cd -P "$HERE" 2>/dev/null && pwd -P)"
PLUGIN_ROOT="${HERE%/*}"
DEDUPE_SECONDS=5

# shellcheck source=marker-dir.sh
. "$HERE/marker-dir.sh" 2>/dev/null || exit 0

lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# 0 when the sound may play at all.
alert_enabled() {
  case "$(lower "${CI:-}")" in
    ''|false|0) ;;
    *) return 1 ;;
  esac
  [[ "${CLAUDE_CODE_SESSION_ATTENDED:-1}" != "0" ]]
}

# The bundled file for a kind.
sound_file() {
  local bundled
  bundled="$PLUGIN_ROOT/assets/attention-$(alert_kind "$1").wav"
  # A kind whose file is missing still calls the human, with the general line.
  [[ -f "$bundled" ]] || bundled="$PLUGIN_ROOT/assets/attention-need.wav"
  printf '%s' "$bundled"
}

# The player for this OS, or nothing when there is none: afplay on macOS,
# paplay (PulseAudio/PipeWire) then aplay (ALSA) on Linux.
pick_player() {
  case "$(uname -s 2>/dev/null)" in
    Darwin) command -v afplay 2>/dev/null ;;
    Linux) command -v paplay 2>/dev/null || command -v aplay 2>/dev/null ;;
  esac
}

# The bell is the last resort, written straight to the controlling terminal.
# `_WD_ATTENTION_TTY` exists only so the tests can point it at a file; with no
# terminal (a hook usually has none) the write fails and is ignored.
ring_bell() {
  # `>>`, not `>`: a stray value of the seam must never truncate a real file.
  { printf '\a' >> "${_WD_ATTENTION_TTY:-/dev/tty}"; } 2>/dev/null
}

# The alerts sound only for a story that turned them on. Sets ACTIVE_STORY and
# ACTIVE_DEVICE from the active entry of the repo that holds <dir> (default
# $PWD); exit 1, silent, when there is none: no entry, no story, no jq.
ACTIVE_STORY=""
ACTIVE_DEVICE=""
story_gate() { # story_gate [dir] [story id the arm recorded]
  local entry="" id device
  # An armed turn remembers the story it was armed for: by the Stop the branch
  # may no longer name it (a checkout to main), and its fanfare must still sound.
  # (The tests' seam names the entry itself, so there is nothing to look up.)
  if [[ -n "${2:-}" && -z "${_WD_ATTENTION_ACTIVE+x}" ]]; then
    while IFS=$'\t' read -r id device; do
      if [[ "$(lower "$id")" == "$(lower "$2")" ]]; then
        entry="$id"$'\t'"$device"
        break
      fi
    done < <(entries "${1:-}")
  fi
  # An arm that names a story no longer holding an entry (its alerts were turned
  # off) is silent: the branch must not hand its sound to another story.
  [[ -n "${2:-}" && -z "${_WD_ATTENTION_ACTIVE+x}" && -z "$entry" ]] && return 1
  [[ -n "$entry" ]] || entry="$(active_entry "${1:-}")"
  [[ -n "$entry" ]] || return 1
  ACTIVE_STORY="${entry%%$'\t'*}"
  ACTIVE_DEVICE="${entry#*$'\t'}"
}

play_now() { # play_now <kind>
  alert_enabled || return 0
  local player sound device helper name
  player="$(pick_player)"
  sound="$(sound_file "$1")"
  if [[ -z "$player" || ! -f "$sound" ]]; then
    ring_bell
    return 0
  fi
  device="$ACTIVE_DEVICE"
  helper="$(helper_bin)"
  name="${player##*/}"
  # A chosen output is tried first; when it fails (unplugged, renamed, no
  # helper), the default output plays instead, so the human is never left
  # without the alert.
  if [[ -n "$device" && "$device" != default ]]; then
    case "$name" in
      afplay)
        if [[ -x "$helper" ]]; then
          ( { "$helper" "$device" "$sound" || "$player" "$sound"; } </dev/null >/dev/null 2>&1 & ) 2>/dev/null
          return 0
        fi
        ;;
      paplay)
        ( { "$player" --device="$device" "$sound" || "$player" "$sound"; } </dev/null >/dev/null 2>&1 & ) 2>/dev/null
        return 0
        ;;
      aplay)
        ( { "$player" -D "$device" "$sound" || "$player" "$sound"; } </dev/null >/dev/null 2>&1 & ) 2>/dev/null
        return 0
        ;;
    esac
  fi
  ( "$player" "$sound" </dev/null >/dev/null 2>&1 & ) 2>/dev/null
  return 0
}

# ## Where the sounds play
#
# `afplay` and friends play on the system's default output, which is often a
# headset the human takes off when they walk away. So the story's entry names
# the output to use; `default` is the system's default output.
#
# On macOS a chosen output needs scripts/attention-play.swift, compiled once with
# `swiftc` into ~/.workflow-dev/bin/ — never in a hook. Without `swiftc` the
# default output plays. On Linux, `paplay --device` / `aplay -D` take the output
# name directly.

machine_dir() {
  printf '%s/.workflow-dev' "${HOME:-}"
}

helper_bin() {
  printf '%s/bin/attention-play' "$(machine_dir)"
}

# ## Alerts are per story
#
# A story turns the alerts on by having an entry in the repo's
# `.workflow-dev/config.json`, and the human's last choice of output is kept in
# `~/.workflow-dev/config.json`:
#
#   repo:  {"notifications": [{"storyId": "WD-0068", "device": "<output>"}]}
#   user:  {"userPref": {"notifications": {"device": "<output>"}}}
#
# Both files hold other keys that are not ours (gitignored, language, ...), so
# every write goes through `jq` and replaces the file whole, or not at all. With
# no `jq`, an unreadable file or a root that is not an object, a write prints
# `unavailable` and touches nothing, and a read finds no entry: the alerts stay
# off, never the file lost. Two writers at the same instant (a Stop and an `init`)
# can lose one update: the window is milliseconds, and nothing is half-written.

user_config() {
  printf '%s/config.json' "$(machine_dir)"
}

# The nearest directory at or above $1 (default $PWD) that holds
# `.workflow-dev/context`, or nothing.
workflow_root() {
  local dir="${1:-}"
  [[ -n "$dir" ]] || dir="$PWD"
  while :; do
    [[ -d "$dir/.workflow-dev/context" ]] && { printf '%s' "$dir"; return 0; }
    [[ "$dir" == / || "$dir" == . || -z "$dir" ]] && return 1
    dir="$(dirname "$dir")"
  done
}

# Which JSON tool this machine has: `jq`, else `perl` with JSON::PP (core since
# perl 5.14, on every macOS and nearly every Linux), else none: then nothing can
# be written or read, and the alerts stay off.
json_engine() {
  if command -v jq >/dev/null 2>&1; then
    printf 'jq'
  elif command -v perl >/dev/null 2>&1 && perl -MJSON::PP -e1 >/dev/null 2>&1; then
    printf 'perl'
  fi
}

# The perl engine: the same operations as the jq programs, on stdin's JSON
# object, printing the new document (or, for `entries`/`pref`, the lines read).
# A document that is not one JSON object makes it exit 1, as jq's checks do.
PERL_JSON='
use strict; use warnings; use JSON::PP; use B;
my ($op, @a) = @ARGV;
utf8::decode($_) for @a;
local $/; my $src = <STDIN>;
$src =~ s/^\xEF\xBB\xBF// if defined $src;
$src = "{}" unless defined $src && $src =~ /\S/;
my $d = eval { JSON::PP->new->allow_bignum->utf8->decode($src) };
exit 1 if $@ || ref $d ne "HASH";
sub str {
  my $v = shift;
  return undef if !defined $v || ref $v;
  my $f = B::svref_2object(\$v)->FLAGS;
  return ($f & B::SVp_POK) && !($f & (B::SVp_IOK | B::SVp_NOK)) ? $v : undef;
}
if ($op eq "entries") {
  my $n = $d->{notifications};
  exit 0 unless ref $n eq "ARRAY";
  for my $r (@$n) {
    next unless ref $r eq "HASH";
    my ($i, $v) = (str($r->{storyId}), str($r->{device}));
    next unless defined $i && defined $v && !JSON::PP::is_bool($r->{storyId}) && !JSON::PP::is_bool($r->{device});
    utf8::encode($i); utf8::encode($v);
    print "$i\t$v\n";
  }
  exit 0;
}
if ($op eq "pref") {
  my $u = $d->{userPref};
  my $v = ref $u eq "HASH" && ref $u->{notifications} eq "HASH" ? str($u->{notifications}{device}) : undef;
  if (defined $v) { utf8::encode($v); print "$v\n" }
  exit 0;
}
if ($op eq "set_pref") {
  $d->{userPref} = {} unless defined $d->{userPref};
  exit 1 unless ref $d->{userPref} eq "HASH";
  $d->{userPref}{notifications} = { device => $a[0] };
} elsif ($op eq "activate" || $op eq "deactivate") {
  my $n = $d->{notifications};
  my $absent = !defined $n || (JSON::PP::is_bool($n) && !$n && $op eq "activate");
  exit 0 if $absent && $op eq "deactivate" && do { print JSON::PP->new->pretty->canonical->allow_bignum->utf8->encode($d); 1 };
  $n = [] if $absent;
  exit 1 unless ref $n eq "ARRAY";
  my $id = $a[0]; $id =~ tr/A-Z/a-z/;
  my @keep = grep {
    my $s = ref $_ eq "HASH" && defined $_->{storyId} && !ref $_->{storyId} ? $_->{storyId} : "";
    $s =~ tr/A-Z/a-z/;
    !(ref $_ eq "HASH" && $s eq $id)
  } @$n;
  push @keep, { storyId => $a[0], device => $a[1] } if $op eq "activate";
  $d->{notifications} = \@keep;
} else { exit 1 }
print JSON::PP->new->pretty->canonical->allow_bignum->utf8->encode($d);
'

json_perl() { # json_perl <op> [args...], the document on stdin
  perl -MJSON::PP -e "$PERL_JSON" -- "$@"
}

# The jq programs, one per write. $1 is the operation, the rest its arguments.
json_jq() { # json_jq <op> [args...], the document on stdin
  local op="$1" prog
  shift
  case "$op" in
    set_pref)
      prog='.userPref.notifications = {device: $d}'
      jq --arg d "$1" "if type == \"object\" then ($prog) else error(\"not an object\") end" ;;
    activate)
      prog='.notifications = (((.notifications // []) | if type == "array" then . else error("not a list") end) | map(select(((.storyId? // "") | tostring | ascii_downcase) != ($i | ascii_downcase)))) + [{storyId: $i, device: $d}]'
      jq --arg i "$1" --arg d "$2" "if type == \"object\" then ($prog) else error(\"not an object\") end" ;;
    deactivate)
      prog='if .notifications == null then . else (.notifications | if type == "array" then . else error("not a list") end) as $n | .notifications = ($n | map(select(((.storyId? // "") | tostring | ascii_downcase) != ($i | ascii_downcase)))) end'
      jq --arg i "$1" "if type == \"object\" then ($prog) else error(\"not an object\") end" ;;
    *) return 1 ;;
  esac
}

# Apply a write to the JSON object in <file> (a missing file is `{}`) and put
# the result in its place. Exit 1, file untouched, when there is no JSON tool,
# the file is not one JSON object, or the write fails.
json_edit() { # json_edit <file> <op: set_pref|activate|deactivate> [args...]
  local file="$1" dir lock link hops=0 rc wait_s=10 deadline
  shift
  # How long to wait for the lock, in real seconds (a count of tries drifts:
  # each try also forks `find` and `sleep`). 2 s dropped the last of ten queued
  # writers on a busy machine, so the agent's own writes (`init`'s activate,
  # set-pref) wait up to 10 s. `deactivate` runs inside the Stop hook, whose
  # timeout is 5 s and which has already done work by then, so it waits 3 s.
  [[ "${1:-}" == deactivate ]] && wait_s=3
  [[ -n "$(json_engine)" ]] || return 1
  # A symlinked config (dotfiles) is edited where it points, so the link stays.
  while [[ -L "$file" && $hops -lt 10 ]]; do
    link="$(readlink "$file")"
    case "$link" in /*) file="$link" ;; *) file="${file%/*}/$link" ;; esac
    hops=$((hops + 1))
  done
  [[ -d "$file" ]] && return 1
  dir="${file%/*}"
  ( umask 077 && mkdir -p "$dir" ) || return 1
  # One writer at a time: a Stop deleting an entry and an `init` adding one
  # would otherwise each read the old file and the last write would win.
  lock="$dir/.config.json.lock"
  deadline=$((SECONDS + wait_s))
  until mkdir "$lock" 2>/dev/null; do
    # Wait only while another writer holds it: a read-only folder, or a file at
    # the lock's path, will not clear by waiting.
    [[ -d "$lock" ]] || return 1
    # A lock a minute old belongs to a writer that died.
    [[ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]] && rmdir "$lock" 2>/dev/null
    [[ $SECONDS -ge $deadline ]] && return 1
    sleep 0.05
  done
  # A writer killed here (the human interrupts `init`) must not leave the lock.
  trap 'rmdir "$lock" 2>/dev/null; exit 0' INT TERM
  json_write "$file" "$@"
  rc=$?
  trap - INT TERM
  rmdir "$lock" 2>/dev/null
  return $rc
}

json_write() { # json_write <file> <op> [args...] — the read-edit-replace, under the lock
  local file="$1" src out tmp engine
  shift
  engine="$(json_engine)"
  if [[ -f "$file" ]]; then
    src="$(cat "$file" 2>/dev/null)" || return 1
  else
    src='{}'
  fi
  src="${src#$'\xef\xbb\xbf'}"
  # A file that holds only whitespace (a stray `touch`) is an empty config.
  [[ -n "${src//[[:space:]]/}" ]] || src='{}'
  case "$engine" in
    jq)
      # Two documents glued together are not a config: rewriting them would
      # double the entry.
      [[ "$(printf '%s' "$src" | jq -s 'length' 2>/dev/null)" == 1 ]] || return 1
      out="$(printf '%s' "$src" | json_jq "$@" 2>/dev/null)" || return 1 ;;
    perl) out="$(printf '%s' "$src" | json_perl "$@" 2>/dev/null)" || return 1 ;;
    *) return 1 ;;
  esac
  [[ -n "$out" ]] || return 1
  tmp="$(mktemp "${file%/*}/.config.json.XXXXXX")" || return 1
  # cp -p first, so the new file keeps the old one's mode.
  [[ -f "$file" ]] && cp -p "$file" "$tmp" 2>/dev/null
  { printf '%s\n' "$out" > "$tmp" && mv "$tmp" "$file"; } || { rm -f "$tmp"; return 1; }
}

# A story id is letters, digits, dot, dash and underscore: it is matched against
# a branch name and written into JSON, never trusted as anything else.
valid_story_id() {
  [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]
}

# An output name has no control character: none exists, and one would break the
# tab-separated lists below.
valid_device() {
  [[ -n "$1" && "$1" != *[[:cntrl:]]* ]]
}

# Save the human's last choice of output. Prints `saved`, `invalid` or `unavailable`.
do_set_pref() {
  valid_device "$1" || { printf 'invalid\n'; return 0; }
  if json_edit "$(user_config)" set_pref "$1"; then
    printf 'saved\n'
  else
    printf 'unavailable\n'
  fi
}

# The saved output of the last choice, or `unset`. Reading needs jq: with none,
# or an unreadable file, it is `unset`.
do_pref() {
  local file device
  file="$(user_config)"
  if [[ -f "$file" ]]; then
    case "$(json_engine)" in
      jq) device="$(jq -s -r 'if length != 1 then empty else .[0] | .userPref.notifications.device // empty | select(type == "string") end' "$file" 2>/dev/null)" ;;
      perl) device="$(json_perl pref < "$file" 2>/dev/null)" ;;
    esac
  fi
  printf '%s\n' "${device:-unset}"
}

# Turn the alerts on for a story, on the given output: one entry per story id,
# compared without regard to case. Prints `saved`, `invalid` or `unavailable`.
do_activate() { # do_activate <story id> <device>
  local root
  valid_story_id "$1" && valid_device "$2" || { printf 'invalid\n'; return 0; }
  root="$(workflow_root)" || { printf 'unavailable\n'; return 0; }
  if json_edit "$root/.workflow-dev/config.json" activate "$1" "$2"; then
    printf 'saved\n'
  else
    printf 'unavailable\n'
  fi
}

# Turn the alerts off for a story: drop its entry. Prints `removed` (also when
# there was none) or `unavailable`.
do_deactivate() { # do_deactivate <story id> [dir]
  local root file
  valid_story_id "$1" || { printf 'invalid\n'; return 0; }
  root="$(workflow_root "${2:-}")" || { printf 'unavailable\n'; return 0; }
  file="$root/.workflow-dev/config.json"
  [[ -f "$file" ]] || { printf 'removed\n'; return 0; }
  if json_edit "$file" deactivate "$1"; then
    printf 'removed\n'
  else
    printf 'unavailable\n'
  fi
}

# Every entry of the repo that holds <dir> (default $PWD), one per line:
# <story id>\t<device>. Nothing when there is none, or jq cannot read the file.
entries() { # entries [dir]
  local root file
  root="$(workflow_root "${1:-}")" || return 0
  file="$root/.workflow-dev/config.json"
  [[ -f "$file" ]] || return 0
  {
    case "$(json_engine)" in
      jq)
        jq -s -r 'if length != 1 then empty else .[0] | (.notifications // []) | if type == "array" then .[] else empty end
          | select(type == "object" and (.storyId | type) == "string" and (.device | type) == "string")
          | [.storyId, .device] | join("\t") end' "$file" 2>/dev/null ;;
      perl) json_perl entries < "$file" 2>/dev/null ;;
    esac
  } | while IFS=$'\t' read -r id device; do
    # An id that could not have been written is not trusted on the way back:
    # it ends up in a regex.
    valid_story_id "$id" && printf '%s\t%s\n' "$id" "$device"
  done
}

# The entry of the story being worked on, as <story id>\t<device>, or nothing.
# That is the entry whose id stands in the current branch's name (an id inside a
# longer word does not count: WD-006 is not WD-0068); when none does, the only
# entry there is; with several and no match, none.
active_entry() { # active_entry [dir]
  local list count id device root branch pat idl rest match best="" best_pos=-1 prefix num got
  # `_WD_ATTENTION_ACTIVE` exists only so the tests can name the active entry
  # without a repo or jq; an empty value means no active story.
  if [[ -n "${_WD_ATTENTION_ACTIVE+x}" ]]; then
    [[ -z "$_WD_ATTENTION_ACTIVE" ]] || printf '%s\n' "$_WD_ATTENTION_ACTIVE"
    return 0
  fi
  list="$(entries "${1:-}")"
  [[ -n "$list" ]] || return 0
  root="$(workflow_root "${1:-}")" || return 0
  branch="$(git -C "$root" symbolic-ref --short HEAD 2>/dev/null)"
  branch="$(lower "$branch")"
  if [[ -n "$branch" ]]; then
    while IFS=$'\t' read -r id device; do
      idl="$(lower "$id")"
      pat="${idl//./\\.}"
      if [[ "$branch" =~ (^|[^a-z0-9])${pat}($|[^a-z0-9]) ]]; then
        # Two ids in one branch: the one named first is the story it is for.
        # The position is the match's own (with its boundaries), so PROJ-1 does
        # not claim the start of PROJ-12.
        match="${BASH_REMATCH[0]}"
        rest="${branch%%"$match"*}"
        if [[ $best_pos -lt 0 || ${#rest} -lt $best_pos ]]; then
          best="$id"$'\t'"$device"
          best_pos=${#rest}
        fi
      fi
    done <<< "$list"
    [[ -n "$best" ]] && { printf '%s\n' "$best"; return 0; }
  fi
  count="$(printf '%s\n' "$list" | wc -l | tr -d ' ')"
  [[ "$count" == 1 ]] || return 0
  # A lone entry stands in for a branch that does not name a story, but not for
  # one that names another story of the same kind (wd-0070 when it holds
  # WD-0068). The same story written another way (wd_0068, wd0068, wd-68) is the
  # entry's own, and its numbers are compared without their leading zeros.
  id="${list%%$'\t'*}"
  prefix="$(lower "$id")"
  prefix="${prefix%%[-0-9._]*}"
  if [[ -n "$prefix" && -n "$branch" ]]; then
    num="$(lower "$id")"; num="${num#"$prefix"}"; num="${num#[-_.]}"; num="${num%%[!0-9]*}"
    num="${num#"${num%%[!0]*}"}"
    rest="$branch"
    while [[ "$rest" =~ (^|[^a-z0-9])${prefix}[-_.]?([0-9]+) ]]; do
      got="${BASH_REMATCH[2]}"; got="${got#"${got%%[!0]*}"}"
      [[ "$got" == "$num" ]] || return 0
      rest="${rest#*"${BASH_REMATCH[0]}"}"
    done
  fi
  printf '%s\n' "$list"
}

# Compile the macOS helper when it is missing or older than its source.
build_helper() {
  local bin src tmp
  bin="$(helper_bin)"
  src="$HERE/attention-play.swift"
  [[ -x "$bin" && ! "$src" -nt "$bin" ]] && return 0
  command -v swiftc >/dev/null 2>&1 || return 1
  ( umask 077 && mkdir -p "${bin%/*}" ) 2>/dev/null || return 1
  tmp="$bin.tmp.$$"
  if ( umask 077 && swiftc -O -o "$tmp" "$src" ) >/dev/null 2>&1; then
    mv "$tmp" "$bin"
  else
    rm -f "$tmp"
    return 1
  fi
}

# Every output, one per line: <transport>\t<default|->\t<name>. Empty when the
# machine cannot tell (no helper on macOS, no pactl on Linux).
do_devices() {
  case "$(uname -s 2>/dev/null)" in
    Darwin)
      build_helper || return 0
      "$(helper_bin)" --list 2>/dev/null
      ;;
    Linux)
      command -v pactl >/dev/null 2>&1 || return 0
      local def name
      def="$(pactl get-default-sink 2>/dev/null)"
      pactl list short sinks 2>/dev/null | while IFS=$'\t' read -r _ name _; do
        [[ -n "$name" ]] || continue
        # A PCI analog sink is the machine's own speakers or jack.
        case "$name" in
          *pci*analog*) printf 'builtin' ;;
          *bluez*) printf 'bluetooth' ;;
          *usb*) printf 'usb' ;;
          *) printf 'other' ;;
        esac
        printf '\t%s\t%s\n' "$([[ "$name" == "$def" ]] && echo default || echo -)" "$name"
      done
      ;;
  esac
}

# 0 when an output's name says it is a headset or a headphone jack.
headset_name() {
  case "$(lower "$1")" in
    *headphone*|*headset*|*auricular*) return 0 ;;
  esac
  return 1
}

# The output to suggest as "speakers": the first built-in one, or nothing.
do_suggest() {
  do_devices | while IFS=$'\t' read -r transport _ name; do
    [[ "$transport" == builtin ]] && ! headset_name "$name" && { printf '%s\n' "$name"; break; }
  done
}

# What `init` shows the human when it asks about the alerts. Line 1 is the
# state of the saved choice: `first` (never turned on), `suggest\t<output>` (the
# last choice, still connected) or `list` (a last choice that is gone). Then one
# line per output, `<recommended|->\t<default|->\t<name>`: the built-in speakers
# first and marked, the rest after. `nospeaker` follows when there are none to
# mark, and `default-only` when this machine cannot name the outputs (macOS
# without the helper): then nothing can be chosen and the default output plays.
# A built-in output that is a headset jack is not a speaker.
do_offer() {
  local pref devs state transport isdef name found=0 first_rec="" rest=""
  pref="$(do_pref)"
  devs="$(do_devices)"
  state=first
  if [[ "$pref" != unset ]]; then
    state=list
    [[ "$pref" == default ]] && state="suggest"$'\t'"default"
    while IFS=$'\t' read -r _ _ name; do
      [[ "$name" == "$pref" ]] && state="suggest"$'\t'"$pref"
    done <<< "$devs"
  fi
  printf '%s\n' "$state"
  if [[ -z "$devs" ]]; then
    printf 'default-only\n'
    return 0
  fi
  while IFS=$'\t' read -r transport isdef name; do
    [[ -n "$name" ]] || continue
    if [[ "$transport" == builtin && "$found" == 0 ]] && ! headset_name "$name"; then
      found=1
      first_rec="recommended"$'\t'"$isdef"$'\t'"$name"$'\n'
    else
      rest+="-"$'\t'"$isdef"$'\t'"$name"$'\n'
    fi
  done <<< "$devs"
  printf '%s%s' "$first_rec" "$rest"
  [[ "$found" == 1 ]] || printf 'nospeaker\n'
  return 0
}

# 0 when the story context <file> has the heading `### Implementation Status:
# <status>` on a line of its own. A heading inside a fenced code block is not the
# story's status, text after the status makes it another one, and a leading BOM
# or CRLF endings do not hide it.
context_status() { # context_status <file> <status>
  LC_ALL=C awk -v want="### Implementation Status: $2" '
    NR == 1 { sub(/^\357\273\277/, "") }
    { sub(/[ \t\r]+$/, "") }
    /^```/ { fence = !fence; next }
    !fence && $0 == want { found = 1 }
    END { exit !found }' "$1" 2>/dev/null
}

# 0 when the context of story <id> in the repo that holds <dir> says it is Done.
# That line is what ends a story's alerts: `save` writes it when the story is over.
story_done() { # story_done <id> [dir]
  local root file
  root="$(workflow_root "${2:-}")" || return 1
  file="$root/.workflow-dev/context/$1.md"
  [[ -f "$file" ]] || file="$(find "$root/.workflow-dev/context" -maxdepth 1 -iname "$1.md" 2>/dev/null | head -n 1)"
  [[ -n "$file" && -f "$file" ]] && context_status "$file" Done
}

# Drop the entries of stories that are no longer in progress here: an entry is
# only kept while `.workflow-dev/context/<id>.md` says the story is In Progress.
# Prints `pruned <id>` for each one dropped.
do_prune() {
  local root id _d file
  root="$(workflow_root)" || return 0
  while IFS=$'\t' read -r id _d; do
    [[ -n "$id" ]] || continue
    file="$root/.workflow-dev/context/$id.md"
    # The id is kept as it was typed, and a file system may tell cases apart.
    [[ -f "$file" ]] || file="$(find "$root/.workflow-dev/context" -maxdepth 1 -iname "$id.md" 2>/dev/null | head -n 1)"
    if [[ -n "$file" && -f "$file" ]] && context_status "$file" "In Progress"; then
      continue
    fi
    [[ "$(do_deactivate "$id")" == removed ]] && printf 'pruned %s\n' "$id"
  done < <(entries)
  return 0
}

# A top-level string field of a hook payload. Same reading as command-match.sh's
# command_from_payload (jq when present; otherwise an escape-aware grep and a
# one-pass unescape), generalised from `.tool_input.command` to any key.
payload_field() {
  local payload="$1" key="$2" raw
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$payload" | jq -r --arg k "$key" 'if type == "object" then (.[$k] // empty) | strings else empty end' 2>/dev/null
    return 0
  fi
  raw=$(printf '%s' "$payload" | grep -oE "\"$key\"[[:space:]]*:[[:space:]]*\"([^\"\\\\]|\\\\.)*\"" | head -1 | sed -E "s/^\"$key\"[[:space:]]*:[[:space:]]*\"(.*)\"\$/\\1/")
  printf '%s' "$raw" | awk 'BEGIN { RS = "\001" } {
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

valid_session() {
  [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]]
}

store_dir() {
  printf '%s/attention' "$(marker_root)"
}

# 0 when the store may be used: it exists (or was just created) and is trusted
# all the way up to the marker root.
store_ready() {
  marker_ensure_dir "$(store_dir)" 2>/dev/null
}

# The one way a hook plays: gate, dedupe window, record the play, drop the
# session's arm (so the same event cannot sound again at the next Stop), play.
play_event() { # play_event <session> <source: stop|ask|notify> <sound kind> <cwd> [story id]
  local session="$1" kind="$2" sound="$3" dir last last_time last_kind now
  dir="$(store_dir)"
  rm -f "$dir/armed-$session" 2>/dev/null
  alert_enabled || return 0
  story_gate "$4" "${5:-}" || return 0
  now="$(date +%s)"
  last="$(cat "$dir/last-$session" 2>/dev/null)"
  last_time="${last%% *}"
  last_kind="${last#* }"
  # Only an ask followed by a permission prompt is one event (the question, then
  # the dialog it raised). A prompt followed by an ask is a new question, and a
  # record with no known kind merges with nothing.
  if [[ "$last_time" =~ ^[0-9]+$ && "$last_kind" == ask && "$kind" == notify ]] \
    && (( now - last_time < DEDUPE_SECONDS && now >= last_time )); then
    return 0
  fi
  printf '%s %s\n' "$now" "$kind" | marker_write "$dir/last-$session" 2>/dev/null
  play_now "$sound"
}

# The session's cwd or any parent holds `.workflow-dev/context`.
in_workflow_project() {
  workflow_root "$1" >/dev/null
}

# Drop this store's files older than a day: one small `last-` file per session
# would otherwise pile up for as long as `$TMPDIR` lives (a long-lived Linux
# /tmp is never purged), and an arm that old belongs to a finished session.
sweep_store() {
  find "$(store_dir)" -maxdepth 1 -type f \( -name 'armed-*' -o -name 'last-*' \) -mtime +0 -exec rm -f {} + 2>/dev/null
}

do_arm() { # do_arm [kind] — the arm file holds the kind the next Stop plays
  local session="${CLAUDE_CODE_SESSION_ID:-}" entry
  valid_session "$session" || return 0
  store_ready || return 0
  sweep_store
  # The arm holds the kind, then the id of the story it is armed for (the branch
  # still names it now; at the Stop it may not).
  entry="$(active_entry "$PWD")"
  {
    printf '%s\n' "$(alert_kind "${1:-}")"
    [[ -n "$entry" ]] && printf '%s\n' "${entry%%$'\t'*}"
  } | marker_write "$(store_dir)/armed-$session" 2>/dev/null
  return 0
}

# UserPromptSubmit: the human is back, so whatever was armed is moot. A turn the
# human interrupts ends without a Stop; without this its arm would sound at the
# end of the next, ordinary response.
do_prompt() {
  local payload session
  any_armed || return 0
  read_payload
  session="$(hook_session "$payload")" || return 0
  rm -f "$(store_dir)/armed-$session" 2>/dev/null
  return 0
}

# `--stop` and `--prompt` run after every response in every project, so they
# check the store first and, with nothing armed, return without reading the
# payload or starting any process. Leaving stdin unread is safe: Claude Code
# already runs user hooks that never read it (`afplay … &`). When something is
# armed, `cat` reads the payload: bash's `read` takes a pipe one byte at a time,
# about 0.5 s per MB.
read_payload() {
  payload="$(cat)"
}

# 0 when some session has an arm in the store — a glob, no process.
any_armed() {
  local f
  for f in "$(store_dir)"/armed-*; do
    [[ -e "$f" ]] && return 0
  done
  return 1
}

hook_session() { # hook_session <payload> — the payload's id, else the env's
  local session
  session="$(payload_field "$1" session_id)"
  [[ -n "$session" ]] || session="${CLAUDE_CODE_SESSION_ID:-}"
  valid_session "$session" && printf '%s' "$session"
}

do_stop() {
  local payload session dir claimed sound cwd armed_id
  any_armed || return 0
  read_payload
  session="$(hook_session "$payload")" || return 0
  dir="$(store_dir)"
  [[ -f "$dir/armed-$session" ]] || return 0
  [[ -z "$(marker_chain_reason "$dir")" ]] || return 0
  claimed="$dir/.claimed-$session-$$"
  mv "$dir/armed-$session" "$claimed" 2>/dev/null || return 0
  # An arm written before kinds existed holds `armed`, which reads as `need`.
  sound="$(alert_kind "$(head -n 1 "$claimed" 2>/dev/null)")"
  armed_id="$(sed -n 2p "$claimed" 2>/dev/null)"
  valid_story_id "$armed_id" || armed_id=""
  rm -f "$claimed"
  cwd="$(payload_field "$payload" cwd)"
  play_event "$session" stop "$sound" "$cwd" "$armed_id"
  # The story's alerts end with the story: its entry goes only when its context
  # says Done, so a fanfare armed too early (or a story reopened) keeps them.
  # (Also when the sound itself is off: the story is over either way.)
  if [[ "$sound" == story ]]; then
    [[ -n "$ACTIVE_STORY" ]] || story_gate "$cwd" "$armed_id" || true
    if [[ -n "$ACTIVE_STORY" ]] && story_done "$ACTIVE_STORY" "$cwd"; then
      do_deactivate "$ACTIVE_STORY" "$cwd" >/dev/null
    fi
  fi
  return 0
}

# 0 while this session runs an autonomous story: the run keeps the Mac awake
# with a `caffeinate` tied to the session (autonomous-keep-awake.sh), so its
# `status` is the one signal that already exists — no second marker to drift.
# `_WD_KEEP_AWAKE` exists only so the tests can point it at a stub.
in_autonomous_run() {
  local status
  status="$("${_WD_KEEP_AWAKE:-$HERE/autonomous-keep-awake.sh}" status 2>/dev/null)"
  [[ "$status" == running* ]]
}

do_ask() {
  local payload session sound=need
  read_payload
  session="$(hook_session "$payload")" || return 0
  in_workflow_project "$(payload_field "$payload" cwd)" || return 0
  store_ready || return 0
  # Mid autonomous run the human walked away, so the question calls them back.
  in_autonomous_run && sound=away
  play_event "$session" ask "$sound" "$(payload_field "$payload" cwd)"
}

do_notify() {
  local payload session kind
  read_payload
  session="$(hook_session "$payload")" || return 0
  in_workflow_project "$(payload_field "$payload" cwd)" || return 0
  # The matcher is the filter; this is the backstop for a registration that
  # loses its matcher. No type field at all is trusted to the matcher.
  kind="$(payload_field "$payload" notification_type)"
  [[ -z "$kind" || "$kind" == "permission_prompt" ]] || return 0
  store_ready || return 0
  play_event "$session" notify permission "$(payload_field "$payload" cwd)"
}

case "${1:-}:$#" in
  play:1|play:2|play:3|arm:1|arm:2|--stop:1|--ask:1|--notify:1|--prompt:1) ;;
  devices:1|suggest:1|pref:1|entries:1|active:1|offer:1|prune:1|set-pref:2|deactivate:2|activate:3) ;;
  *) usage ;;
esac
[[ "$1" == set-pref || "$1" == activate || "$1" == deactivate ]] && [[ -z "${2:-}" ]] && usage
[[ "$1" == activate && -z "${3:-}" ]] && usage
[[ "$1" == play && $# -eq 3 && "$2" != start ]] && usage
# Past the usage check nothing is worth showing: a hook's stray stderr (a tool
# missing on some host) would only reach the human as noise.
exec 2>/dev/null
case "$1" in
  play)
    # `play start <output>` is the confirmation `init` plays right after turning
    # the alerts on: the entry may not be the one the branch names yet, so it
    # asks for no entry and takes the output it is given.
    if [[ "${2:-}" == start && -n "${3:-}" ]]; then
      alert_enabled && { valid_device "$3" && ACTIVE_DEVICE="$3"; play_now start; }
    else
      alert_enabled && story_gate "$PWD" && play_now "${2:-need}"
    fi ;;
  arm) do_arm "${2:-}" ;;
  --stop) do_stop ;;
  --ask) do_ask ;;
  --notify) do_notify ;;
  --prompt) do_prompt ;;
  devices) do_devices ;;
  suggest) do_suggest ;;
  set-pref) do_set_pref "$2" ;;
  pref) do_pref ;;
  activate) do_activate "$2" "$3" ;;
  deactivate) do_deactivate "$2" ;;
  entries) entries ;;
  active) active_entry ;;
  offer) do_offer ;;
  prune) do_prune ;;
  *) usage ;;
esac
exit 0
