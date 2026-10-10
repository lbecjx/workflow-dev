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
# Nine sounds, one per meaning (assets/attention-<kind>.wav):
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
#   story       fanfare + "Congrats! Story complete."
#
#   attention-alert.sh play [kind]   play one now (default need; also a preview)
#   attention-alert.sh arm [kind]    a skill says "the turn I am ending hands
#                                    control to the human" — the next Stop plays
#                                    that kind (default need)
#   attention-alert.sh --stop        Stop hook: plays only when this session is armed
#   attention-alert.sh --ask         PreToolUse:AskUserQuestion hook (need; away mid autonomous run)
#   attention-alert.sh --notify      Notification:permission_prompt hook (permission)
#   attention-alert.sh --prompt      UserPromptSubmit hook: drops a stale arm
#   attention-alert.sh devices | suggest | device | set-device <name|default>
#                      | volume | set-volume <0-100>
#                                    the per-machine output and volume (below)
#
# An unknown kind falls back to `need`: a typo in a skill must still call the
# human, never go silent. When to arm, and with which kind, is the skills' rule,
# owned by references/attention-alert.md; this file only owns the mechanics.
#
# ## Configuration — one place: Claude Code's settings.json `env`
#
#   WORKFLOW_DEV_ATTENTION=off          off (also 0, false, no; any case)
#   WORKFLOW_DEV_ATTENTION_SOUND=/path  play this one file for every event
#
# Env vars, not `.workflow-dev/config.json`: that file is per project and often
# gitignored, while a sound is a per-user preference, and the settings `env`
# block reaches every hook process Claude Code starts.
#
# It is also silent, whatever the settings, in CI (`CI` set to anything but
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
  printf 'usage: %s play [kind] | arm [kind] | --stop | --ask | --notify | --prompt | devices | suggest | device | set-device <name|default> | volume | set-volume <0-100>\n' "${0##*/}" >&2
  exit 2
}

# `need` for anything that is not one of the nine kinds (see the header).
alert_kind() {
  case "${1:-}" in
    need|away|permission|commit|pr|done|passed|fail|story) printf '%s' "$1" ;;
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
  case "$(lower "${WORKFLOW_DEV_ATTENTION:-}")" in
    off|0|false|no) return 1 ;;
  esac
  case "$(lower "${CI:-}")" in
    ''|false|0) ;;
    *) return 1 ;;
  esac
  [[ "${CLAUDE_CODE_SESSION_ATTENDED:-1}" != "0" ]]
}

# The file to play for a kind: the user's, when it is a readable regular file,
# else the bundled one for that kind. A bad custom path falls back instead of
# going silent, so a typo in settings never costs the human the alert. A path
# starting with `-` gets a `./` so no player reads it as an option.
sound_file() {
  local custom="${WORKFLOW_DEV_ATTENTION_SOUND:-}"
  if [[ -n "$custom" && -f "$custom" && -r "$custom" ]]; then
    [[ "$custom" == -* ]] && custom="./$custom"
    printf '%s' "$custom"
  else
    local bundled
    bundled="$PLUGIN_ROOT/assets/attention-$(alert_kind "$1").wav"
    # A kind whose file is missing still calls the human, with the general line.
    [[ -f "$bundled" ]] || bundled="$PLUGIN_ROOT/assets/attention-need.wav"
    printf '%s' "$bundled"
  fi
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

# The alert volume as a percentage of the output's own volume:
# WORKFLOW_DEV_ATTENTION_VOLUME, 0–100. Unset or not a whole number in range →
# 100, so a typo never mutes the alert.
valid_volume() {
  [[ "$1" =~ ^[0-9]{1,3}$ ]] && (( 10#$1 <= 100 ))
}

volume_percent() {
  local v="${WORKFLOW_DEV_ATTENTION_VOLUME:-}"
  [[ -n "$v" ]] || v="$(machine_field volume)"
  if valid_volume "$v"; then
    printf '%d' "$((10#$v))"
  else
    printf '100'
  fi
}

# Player options for that volume. afplay and the macOS helper take a gain where
# 1 is the file's own level; paplay takes 0–65536. aplay has no volume option,
# so it always plays at the output's level.
volume_args() { # volume_args <player name> <percent>
  local p="$2" gain
  (( p == 100 )) && return 0
  gain="$((p / 100)).$(printf '%02d' $((p % 100)))"
  case "$1" in
    afplay) printf '%s\n' -v "$gain" ;;
    helper) printf '%s\n' "$gain" ;;
    paplay) printf '%s\n' "--volume=$((p * 65536 / 100))" ;;
  esac
}

play_now() { # play_now <kind>
  alert_enabled || return 0
  local player sound device helper pct name a
  local -a pvol=() hvol=()
  player="$(pick_player)"
  sound="$(sound_file "$1")"
  if [[ -z "$player" || ! -f "$sound" ]]; then
    ring_bell
    return 0
  fi
  device="$(chosen_device)"
  helper="$(helper_bin)"
  pct="$(volume_percent)"
  name="${player##*/}"
  while IFS= read -r a; do [[ -n "$a" ]] && pvol+=("$a"); done < <(volume_args "$name" "$pct")
  while IFS= read -r a; do [[ -n "$a" ]] && hvol+=("$a"); done < <(volume_args helper "$pct")
  # A chosen output is tried first; when it fails (unplugged, renamed, no
  # helper), the default output plays instead, so the human is never left
  # without the alert.
  if [[ -n "$device" && "$device" != default ]]; then
    case "$name" in
      afplay)
        if [[ -x "$helper" ]]; then
          ( { "$helper" "$device" "$sound" ${hvol[@]+"${hvol[@]}"} || "$player" ${pvol[@]+"${pvol[@]}"} "$sound"; } </dev/null >/dev/null 2>&1 & ) 2>/dev/null
          return 0
        fi
        ;;
      paplay)
        ( { "$player" --device="$device" ${pvol[@]+"${pvol[@]}"} "$sound" || "$player" ${pvol[@]+"${pvol[@]}"} "$sound"; } </dev/null >/dev/null 2>&1 & ) 2>/dev/null
        return 0
        ;;
      aplay)
        ( { "$player" -D "$device" "$sound" || "$player" "$sound"; } </dev/null >/dev/null 2>&1 & ) 2>/dev/null
        return 0
        ;;
    esac
  fi
  ( "$player" ${pvol[@]+"${pvol[@]}"} "$sound" </dev/null >/dev/null 2>&1 & ) 2>/dev/null
  return 0
}

# ## Where the sounds play — one choice per machine
#
# `afplay` and friends play on the system's default output, which is often a
# headset the human takes off when they walk away. So the first story on a
# machine asks once where the alerts should play (skills/init, "Phase 7"), and
# the answer — and how loud — is kept per machine, for every repo:
#
#   ~/.workflow-dev/attention.json   {"device": "<output name>"|"default", "volume": "25"|"50"|"75"|"100"}
#   WORKFLOW_DEV_ATTENTION_DEVICE    overrides the device (settings `env`)
#   WORKFLOW_DEV_ATTENTION_VOLUME    overrides the volume, 0–100 (settings `env`)
#
# The volume is a share of the output's own level, so the alert can be softer
# than music on the same speakers; aplay cannot scale, so on ALSA alone it plays
# at the output's level.
#
# On macOS a chosen output needs scripts/attention-play.swift, compiled once with
# `swiftc` into ~/.workflow-dev/bin/ when the human picks it — never in a hook.
# Without `swiftc` the choice is kept and the default output plays. On Linux,
# `paplay --device` / `aplay -D` take the output name directly.

machine_dir() {
  printf '%s/.workflow-dev' "${HOME:-}"
}

helper_bin() {
  printf '%s/bin/attention-play' "$(machine_dir)"
}

# The saved choice: the env var, else the machine file; empty when neither.
chosen_device() {
  if [[ -n "${WORKFLOW_DEV_ATTENTION_DEVICE:-}" ]]; then
    printf '%s' "$WORKFLOW_DEV_ATTENTION_DEVICE"
    return 0
  fi
  machine_field device
}

# One string field of the machine file, or nothing.
machine_field() {
  local file
  file="$(machine_dir)/attention.json"
  [[ -f "$file" ]] || return 0
  payload_field "$(cat "$file" 2>/dev/null)" "$1"
}

# Rewrite the machine file with both fields, keeping the one not being changed.
# Both are stored as JSON strings so the same reader serves them.
write_machine_config() { # write_machine_config <device> <volume>
  local dir tmp dev vol
  dir="$(machine_dir)"
  ( umask 077 && mkdir -p "$dir" ) || return 1
  dev="$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  vol="$2"
  tmp="$(mktemp "$dir/.attention.json.XXXXXX")" || return 1
  if [[ -n "$vol" ]]; then
    printf '{"device": "%s", "volume": "%s"}\n' "$dev" "$vol" > "$tmp"
  else
    printf '{"device": "%s"}\n' "$dev" > "$tmp"
  fi && mv "$tmp" "$dir/attention.json" || { rm -f "$tmp"; return 1; }
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

# The output to suggest as "speakers": the first built-in one, or nothing.
do_suggest() {
  do_devices | while IFS=$'\t' read -r transport _ name; do
    [[ "$transport" == builtin ]] && { printf '%s\n' "$name"; break; }
  done
}

# The saved choice for this machine: the device name, `default`, or `unset`.
do_device() {
  local device
  device="$(chosen_device)"
  printf '%s\n' "${device:-unset}"
}

# Save the choice for this machine. Prints `saved`, or `saved-default-output`
# when a named output was saved but this Mac cannot route to it (no `swiftc`):
# the alerts then play on the default output.
do_set_device() {
  local device="$1"
  # A newline or tab would break the JSON file and lose both saved fields; no
  # real output name has one (`devices` lists them tab- and line-separated).
  [[ "$device" == *[[:cntrl:]]* ]] && { printf 'invalid\n'; return 0; }
  write_machine_config "$device" "$(machine_field volume)" || return 0
  if [[ "$device" != default && "$(uname -s 2>/dev/null)" == Darwin ]] && ! build_helper; then
    printf 'saved-default-output\n'
  else
    printf 'saved\n'
  fi
}

# Save the alert volume for this machine (0–100). Prints `saved`, or `invalid`
# for anything else, which changes nothing.
do_set_volume() {
  local vol="$1"
  valid_volume "$vol" || { printf 'invalid\n'; return 0; }
  write_machine_config "$(machine_field device)" "$((10#$vol))" || return 0
  printf 'saved\n'
}

# The saved volume for this machine, or `unset`.
do_volume() {
  local v
  v="$(machine_field volume)"
  printf '%s\n' "${v:-unset}"
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
play_event() { # play_event <session> <source: stop|ask|notify> <sound kind>
  local session="$1" kind="$2" sound="$3" dir last last_time last_kind now
  dir="$(store_dir)"
  rm -f "$dir/armed-$session" 2>/dev/null
  alert_enabled || return 0
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
  local dir="$1"
  [[ -n "$dir" ]] || dir="$PWD"
  while :; do
    [[ -d "$dir/.workflow-dev/context" ]] && return 0
    [[ "$dir" == / || "$dir" == . || -z "$dir" ]] && return 1
    dir="$(dirname "$dir")"
  done
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
  # An arm written before kinds existed holds `armed`, which reads as `need`.
  sound="$(alert_kind "$(head -n 1 "$claimed" 2>/dev/null)")"
  rm -f "$claimed"
  play_event "$session" stop "$sound"
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
  play_event "$session" ask "$sound"
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
  play_event "$session" notify permission
}

case "${1:-}:$#" in
  play:1|play:2|arm:1|arm:2|--stop:1|--ask:1|--notify:1|--prompt:1) ;;
  devices:1|suggest:1|device:1|set-device:2|volume:1|set-volume:2) ;;
  *) usage ;;
esac
[[ ( "$1" == set-device || "$1" == set-volume ) && -z "${2:-}" ]] && usage
# Past the usage check nothing is worth showing: a hook's stray stderr (a tool
# missing on some host) would only reach the human as noise.
exec 2>/dev/null
case "$1" in
  play) play_now "${2:-need}" ;;
  arm) do_arm "${2:-}" ;;
  --stop) do_stop ;;
  --ask) do_ask ;;
  --notify) do_notify ;;
  --prompt) do_prompt ;;
  devices) do_devices ;;
  suggest) do_suggest ;;
  device) do_device ;;
  set-device) do_set_device "$2" ;;
  volume) do_volume ;;
  set-volume) do_set_volume "$2" ;;
  *) usage ;;
esac
exit 0
