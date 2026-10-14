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
#   attention-alert.sh get           this machine's answer: on, off or unset
#   attention-alert.sh set on|off    save it (prints saved or unavailable)
#   attention-alert.sh phone get     the phone's answer: on, off or unset
#   attention-alert.sh phone on [-] | phone reset
#                                    turn the phone notices on (keeping the
#                                    topic, reading a pasted one from stdin with
#                                    `-`, or making one); prints `topic <t>` and
#                                    `clipboard copied|unavailable` (or `topic
#                                    kept` when the phone already had it), then
#                                    `remote-control active|inactive`; or
#                                    `invalid-topic`, `linked-config` (the
#                                    config is a symlink: the topic is not
#                                    written) or `unavailable`
#   attention-alert.sh phone off     turn them off, topic kept (saved or unavailable)
#   attention-alert.sh phone test    send a test notice now (sent, failed or no-topic)
#
# An unknown kind falls back to `need`: a typo in a skill must still call the
# human, never go silent. When to arm, and with which kind, is the skills' rule,
# owned by references/attention-alert.md; this file only owns the mechanics.
#
# ## Configuration — one answer per machine, none in the environment
#
# Whether anything sounds is one yes/no for the whole machine, saved by `init`
# (see "One answer per machine" below). No environment variable is read to
# switch the alerts off (WORKFLOW_DEV_ATTENTION), to swap the sound
# (WORKFLOW_DEV_ATTENTION_SOUND) or to force the output
# (WORKFLOW_DEV_ATTENTION_DEVICE): each of them was a second control that could
# override the human's own answer, with no sign of why. Removed in WD-0072.
#
# It is silent, whatever the answer says, in CI (`CI` set to anything but
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
  printf 'usage: %s play [kind] | arm [kind] | --stop | --ask | --notify | --prompt | get | set on|off | phone on [-]|off|reset|get|test\n' "${0##*/}" >&2
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
# shellcheck source=config-env.sh
. "$HERE/config-env.sh" 2>/dev/null || exit 0

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

play_now() { # play_now <kind>
  alert_enabled || return 0
  local player sound
  player="$(pick_player)"
  sound="$(sound_file "$1")"
  if [[ -z "$player" || ! -f "$sound" ]]; then
    ring_bell
    return 0
  fi
  # No output is ever named: the sound plays wherever the system plays sound
  # now. A saved output went silent the day the human took that headset off
  # (WD-0089), and the default output is the one they last chose themselves.
  ( "$player" "$sound" </dev/null >/dev/null 2>&1 & ) 2>/dev/null
  return 0
}

# ## One answer per machine
#
# The human says once whether they want the alerts, and that answer holds for
# every story of every repo on this machine:
#
#   ~/.workflow-dev/config.env    notifications=on|off
#
# Nothing about the alerts lives in a repo's `.workflow-dev/config.env`, so a
# new clone or a worktree does not ask again, and no story turns them off when
# it ends. Only `on` or `off` is an answer; anything else (no file, no line,
# `true`, `yes`) is no answer: then nothing sounds and `init` asks once.
#
# The file is read line by line and never sourced, and `set` replaces it whole
# keeping its other lines (config-env.sh owns both). Neither needs jq or perl.
# The `~/.workflow-dev/config.json` older versions wrote is ignored, so a
# machine that answered there is asked once again. `set` prints `unavailable`
# only when the file cannot be written.

machine_dir() {
  printf '%s/.workflow-dev' "${HOME:-}"
}

user_config() {
  printf '%s/config.env' "$(machine_dir)"
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

# This machine's answer: `on`, `off` or `unset`. Reading never writes. `_WD_ATTENTION_ON` exists only so the tests can give the
# answer without a file.
read_answer() {
  local answer=""
  if [[ -n "${_WD_ATTENTION_ON+x}" ]]; then
    case "$_WD_ATTENTION_ON" in on|off) answer="$_WD_ATTENTION_ON" ;; esac
    printf '%s\n' "${answer:-unset}"
    return 0
  fi
  answer="$(config_env_get "$(user_config)" notifications)"
  case "$answer" in on|off) ;; *) answer=unset ;; esac
  printf '%s\n' "$answer"
}

# 0 when the alerts may sound for a session in <dir>: a workflow-dev project
# (hooks run for every project on the machine) and a yes from the human.
alerts_gate() { # alerts_gate [dir]
  workflow_root "${1:-}" >/dev/null || return 1
  sound_answer_on
}

# 0 when this machine said yes to the sounds. play_event asks it apart from the
# project check, since the phone may be on while the sounds are off.
sound_answer_on() {
  [[ "$(read_answer)" == on ]]
}

# Save the answer. Prints `saved` or `unavailable`.
do_set() { # do_set <on|off>
  if config_env_set "$(user_config)" notifications "$1"; then
    printf 'saved\n'
  else
    printf 'unavailable\n'
  fi
}

# ## The phone — a second answer per machine (WD-0109)
#
# A push to the human's phone through ntfy.sh, for the few kinds that matter when
# nobody is at the Mac. Its own yes/no, beside the alerts' one, in the same file:
#
#   ~/.workflow-dev/config.env    phone=on|off
#                                 phone_topic=wd-xxxx-xxxx-xxxx
#
# An ntfy.sh topic has no owner and no password: whoever knows its name reads the
# notices and can send forged ones. So the topic is 12 random letters, the file
# is kept 600, and nothing but `phone on|reset` (at setup, once, for the human
# to paste into the app) ever prints it.
#
# The pattern is this script's own shape and nothing broader: a topic pasted
# from another Mac is one this script generated there, and the strict shape
# keeps every character that is special to curl's config format (quotes,
# backslashes, line breaks) out of the request. Letters only, no digits: they
# are typed on a phone keyboard.
TOPIC_RE='^wd-[a-z]{4}-[a-z]{4}-[a-z]{4}$'

valid_topic() {
  [[ "${1:-}" =~ $TOPIC_RE ]]
}

gen_topic() {
  local raw
  # A bounded read, not `tr </dev/urandom`: that pipe ends only when SIGPIPE
  # kills tr, and a caller that ignores SIGPIPE would leave tr spinning
  # forever. 4096 random bytes hold about 400 letters.
  raw="$(head -c 4096 /dev/urandom 2>/dev/null | LC_ALL=C tr -dc 'a-z' | head -c 12)"
  [[ ${#raw} -eq 12 ]] || return 1
  printf 'wd-%s-%s-%s' "${raw:0:4}" "${raw:4:4}" "${raw:8:4}"
}

# The saved topic, only when it has this script's shape.
read_topic() {
  local topic
  topic="$(config_env_get "$(user_config)" phone_topic)" || return 1
  valid_topic "$topic" && printf '%s' "$topic"
}

# `on`, `off` or `unset`. `phone=on` without a valid topic would push to nobody
# forever, so it reads as unset and the setup is offered again.
phone_state() {
  case "$(config_env_get "$(user_config)" phone)" in
    on) read_topic >/dev/null && printf 'on\n' || printf 'unset\n' ;;
    off) printf 'off\n' ;;
    *) printf 'unset\n' ;;
  esac
}

# The Remote Control session id, only when it is safe in a header and a URL.
bridge_session() {
  local id="${CLAUDE_CODE_BRIDGE_SESSION_ID:-}"
  [[ "$id" =~ ^[A-Za-z0-9_-]{1,128}$ ]] && printf '%s' "$id"
}

# `on` keeps a saved topic; a pasted one replaces it; else a new one. `reset`
# always makes a new one. Prints the topic once, then whether it reached the
# clipboard and whether Remote Control is on (the setup's `/rc` hint).
phone_on() { # phone_on <on|reset> [-]   (`-`: a pasted topic comes on stdin)
  local mode="$1" topic file show=1
  file="$(user_config)"
  # A linked config usually lives in a dotfiles repo, and the next push of that
  # repo would publish the secret: mode 600 does not stop a commit. The sounds'
  # answer may live there; the topic never does.
  # When the phone has no answer yet, `phone=off` (no secret) is written through
  # the link, so the question is not asked again in every session; moving the
  # config out of the link and running `phone on` turns it on later. A phone
  # already set up is left as it is: its topic is in that file already.
  if [[ -L "$file" || -L "$(machine_dir)" ]]; then
    if [[ "$(phone_state)" == unset ]] && ! config_env_set "$file" phone off; then
      printf 'unavailable\n'
      return 0
    fi
    printf 'linked-config\n'
    return 0
  fi
  if [[ "${2:-}" == - ]]; then
    # On stdin, not as an argument: any local user can read a process's
    # arguments with `ps`. The whole input must be the topic, nothing more.
    topic="$(cat)"
    topic="${topic%$'\r'}"
    valid_topic "$topic" || { printf 'invalid-topic\n'; return 0; }
  elif [[ "$mode" == on ]] && topic="$(read_topic)"; then
    # Set up before (on or off): the phone is already subscribed, so the secret
    # is not shown or copied again.
    [[ "$(phone_state)" == unset ]] || show=0
  else
    topic="$(gen_topic)" || { printf 'unavailable\n'; return 0; }
  fi
  # 600 before the topic lands: config-env.sh keeps an existing file's mode, so
  # a config made by hand as 644 would otherwise hold the secret readable.
  [[ -f "$file" ]] && chmod 600 "$file"
  # `phone=on` first: if the topic's write then fails, the file keeps the old
  # topic (already on the phone) or none (read as unset, so asked again), never
  # `on` with a topic nobody saw.
  if ! config_env_set "$file" phone on || ! config_env_set "$file" phone_topic "$topic"; then
    printf 'unavailable\n'
    return 0
  fi
  chmod 600 "$file"
  if (( show )); then
    printf 'topic %s\n' "$topic"
    if command -v pbcopy >/dev/null 2>&1 && printf '%s' "$topic" | pbcopy; then
      printf 'clipboard copied\n'
    else
      printf 'clipboard unavailable\n'
    fi
  else
    printf 'topic kept\n'
  fi
  if [[ -n "$(bridge_session)" ]]; then
    printf 'remote-control active\n'
  else
    printf 'remote-control inactive\n'
  fi
}

# Only the kinds that matter when nobody is at the Mac reach the phone: a
# question mid autonomous run, a permission dialog, a failure, a finished story.
push_kind() {
  case "${1:-}" in away|permission|fail|story) return 0 ;; *) return 1 ;; esac
}

# ntfy's default priority for the good news, high for anything blocking.
push_priority() {
  case "${1:-}" in away|permission|fail) printf 'high' ;; esac
}

# The repo's folder name, cut to characters that need no quoting in curl's
# config, and to 40 bytes: a lock screen shows about two lines, and the kind's
# own line must still fit after the name.
safe_name() {
  local dir="${1%/}"
  # Bytes 0x80-0xFF are kept: a UTF-8 letter (año, 日本) never holds a quote,
  # a backslash or a line break. The cut is in bytes, and iconv then drops a
  # letter it split in half (and any byte that is not UTF-8 at all).
  printf '%s' "${dir##*/}" | LC_ALL=C tr -cd 'A-Za-z0-9._\200-\377-' | head -c 40 \
    | iconv -c -f UTF-8 -t UTF-8 2>/dev/null
}

# The story this session works on, when there is exactly one.
story_code() { # story_code <transcript> <workflow root>
  local ids
  ids="$(session_stories "$1" "$2/.workflow-dev/context" 2>/dev/null)"
  [[ "$ids" =~ ^[A-Z][A-Z0-9]*-[0-9]+$ ]] && printf '%s' "$ids"
}

push_text() { # push_text <lang> <kind> <repo> <story>
  local where="$3"
  [[ -n "$4" ]] && where="${where:+$where · }$4"
  printf '%s%s' "${where:+$where — }" "$(hook_msg "$1" "phone_$2")"
}

# One notice to ntfy.sh. The URL goes to curl through a config on stdin, never
# in argv: any local user can read argv with `ps` while the request lives, and
# the topic is the only key to the notices. Every value written into that
# config is either built in or checked first (the topic, the session id, the
# repo name, the story code), so nothing can close a quote or add a line.
# The body never carries the question, code or a path: ntfy.sh keeps what it
# relays for hours. Returns 0 only when ntfy accepted it.
send_push() { # send_push <kind> <cwd> <payload>
  local kind="$1" dir="$2" payload="$3" topic root="" repo="" story="" lang prio id
  topic="$(read_topic)" || return 1
  command -v curl >/dev/null 2>&1 || return 1
  # shellcheck source=hook-language.sh
  . "$HERE/hook-language.sh" 2>/dev/null || return 1
  # shellcheck source=session-story.sh
  . "$HERE/session-story.sh" 2>/dev/null
  if root="$(workflow_root "$dir")"; then
    repo="$(safe_name "$root")"
    story="$(story_code "$(payload_field "$payload" transcript_path)" "$root")"
  fi
  # The repo's own `language` is read from the current folder.
  lang="$(cd "${root:-.}" 2>/dev/null && hook_language "$payload")"
  prio="$(push_priority "$kind")"
  id="$(bridge_session)"
  {
    printf 'url = "https://ntfy.sh/%s"\n' "$topic"
    printf 'header = "Title: workflow-dev"\n'
    [[ -n "$prio" ]] && printf 'header = "Priority: %s"\n' "$prio"
    [[ -n "$id" ]] && printf 'header = "Click: https://claude.ai/code/%s"\n' "$id"
    printf 'data = "%s"\n' "$(push_text "$lang" "$kind" "$repo" "$story")"
  } | curl -q -fsS -m 5 -o /dev/null -K - >/dev/null 2>&1
}

# Detached like the player: the hook returns at once, and a slow or failed
# request changes nothing the human sees.
push_detached() { # push_detached <kind> <cwd> <payload>
  ( send_push "$@" </dev/null >/dev/null 2>&1 & ) 2>/dev/null
}

do_phone() { # do_phone <on|off|reset|get|test> [topic]
  case "$1" in
    get) phone_state ;;
    test)
      if ! read_topic >/dev/null; then
        printf 'no-topic\n'
      elif send_push test "$PWD" ''; then
        printf 'sent\n'
      else
        printf 'failed\n'
      fi
      ;;
    off) config_env_set "$(user_config)" phone off && printf 'saved\n' || printf 'unavailable\n' ;;
    on|reset) phone_on "$1" "${2:-}" ;;
  esac
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
# session's arm (so the same event cannot sound again at the next Stop), play,
# and push to the phone. The sound and the push each follow their own answer,
# so a human can have either one alone; the dedupe covers both, so one event
# is one sound and one push.
play_event() { # play_event <session> <source: stop|ask|notify> <sound kind> <cwd> [payload]
  local session="$1" kind="$2" sound="$3" dir last last_time last_kind now sound_on=0 push_on=0
  dir="$(store_dir)"
  rm -f "$dir/armed-$session" 2>/dev/null
  alert_enabled || return 0
  workflow_root "$4" >/dev/null || return 0
  sound_answer_on && sound_on=1
  # The phone's answer, not yet the kind: a question that does not push (need)
  # still records the event, so the permission prompt it raises is merged into
  # it instead of pushing on its own.
  [[ "$(phone_state)" == on ]] && push_on=1
  (( sound_on || push_on )) || return 0
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
  (( sound_on )) && play_now "$sound"
  (( push_on )) && push_kind "$sound" && push_detached "$sound" "$4" "${5:-}"
  return 0
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
  local session="${CLAUDE_CODE_SESSION_ID:-}"
  valid_session "$session" || return 0
  store_ready || return 0
  sweep_store
  printf '%s\n' "$(alert_kind "${1:-}")" | marker_write "$(store_dir)/armed-$session" 2>/dev/null
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
  local payload session dir claimed sound
  any_armed || return 0
  read_payload
  session="$(hook_session "$payload")" || return 0
  dir="$(store_dir)"
  [[ -f "$dir/armed-$session" ]] || return 0
  [[ -z "$(marker_chain_reason "$dir")" ]] || return 0
  claimed="$dir/.claimed-$session-$$"
  mv "$dir/armed-$session" "$claimed" 2>/dev/null || return 0
  # An arm written before kinds existed holds `armed`, which reads as `need`;
  # one written by an older version also holds a story id on its second line,
  # which nothing reads any more.
  sound="$(alert_kind "$(head -n 1 "$claimed" 2>/dev/null)")"
  rm -f "$claimed"
  play_event "$session" stop "$sound" "$(payload_field "$payload" cwd)" "$payload"
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
  play_event "$session" ask "$sound" "$(payload_field "$payload" cwd)" "$payload"
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
  play_event "$session" notify permission "$(payload_field "$payload" cwd)" "$payload"
}

case "${1:-}:$#" in
  play:1|play:2|arm:1|arm:2|--stop:1|--ask:1|--notify:1|--prompt:1|get:1) ;;
  set:2) [[ "$2" == on || "$2" == off ]] || usage ;;
  phone:2) case "$2" in on|off|reset|get|test) ;; *) usage ;; esac ;;
  phone:3) [[ "$2" == on && "$3" == - ]] || usage ;;
  *) usage ;;
esac
# Past the usage check nothing is worth showing: a hook's stray stderr (a tool
# missing on some host) would only reach the human as noise.
exec 2>/dev/null
case "$1" in
  play) alert_enabled && alerts_gate "$PWD" && play_now "${2:-need}" ;;
  arm) do_arm "${2:-}" ;;
  --stop) do_stop ;;
  --ask) do_ask ;;
  --notify) do_notify ;;
  --prompt) do_prompt ;;
  get) read_answer ;;
  set) do_set "$2" ;;
  phone) do_phone "$2" "${3:-}" ;;
  *) usage ;;
esac
exit 0
