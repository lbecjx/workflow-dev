#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Tests for attention-alert.sh (WD-0052). No real sound is ever played: every
# run gets a PATH made only of test doubles (fake `uname`, `afplay`, `paplay`,
# `aplay`, which log their arguments) and links to the few system tools the
# script needs, so the real /usr/bin/afplay is unreachable — on a developer's
# Mac and on the macOS CI runner alike.
#
# What it pins:
#   - the player follows the OS (afplay on Darwin; paplay, else aplay, on
#     Linux) and falls back to a bell on the tty when there is none;
#   - off (every spelling), CI and a non-interactive session stay silent;
#   - a custom sound is used only when it is a readable regular file;
#   - a slow player never holds the caller; nothing printed, always exit 0;
#   - the bundled sound is a short WAV.
#
#   bash scripts/attention-alert.test.sh

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/attention-alert.sh"
ASSETS="$HERE/../assets"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok() { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }

# --- the sandbox PATH ---------------------------------------------------------
SYS="$TMP/sys"
mkdir -p "$SYS"
for tool in dirname tr sleep cat mv rm mkdir mktemp chmod find date basename sed grep head awk ls seq wc git rmdir cp readlink; do
  real="$(command -v "$tool")" && ln -s "$real" "$SYS/$tool"
done
LOG="$TMP/played.log"
TTY="$TMP/tty"

fake() { # fake <dir> <name> [extra shell line]
  mkdir -p "$1"
  printf '#!/bin/bash\n%s\nprintf "%%s %%s\\n" "%s" "$*" >> "%s"\n' "${3:-}" "$2" "$LOG" > "$1/$2"
  chmod +x "$1/$2"
}
mkdir -p "$TMP/os"
printf '#!/bin/bash\necho "${FAKE_UNAME:-Darwin}"\n' > "$TMP/os/uname"
chmod +x "$TMP/os/uname"
fake "$TMP/mac" afplay
fake "$TMP/pulse" paplay
fake "$TMP/pulse" aplay
fake "$TMP/alsa" aplay
mkdir -p "$TMP/none"
# The slow player logs nothing: its line would land in whichever case runs 5 s
# later and be counted as that case's play.
mkdir -p "$TMP/slow"
printf '#!/bin/bash\nsleep 5\n' > "$TMP/slow/afplay"
chmod +x "$TMP/slow/afplay"

# The alerts sound only for a story that turned them on, so every run happens in
# a project whose config has one entry (on the default output), and finds jq.
# The no-jq hook variant names the entry through the seam instead.
PROJ="$TMP/proj"
mkdir -p "$PROJ/.workflow-dev/context" "$TMP/jq"
printf '{"notifications":[{"storyId":"T-1","device":"default"}]}\n' > "$PROJ/.workflow-dev/config.json"
JQ_REAL="$(command -v jq)" && ln -s "$JQ_REAL" "$TMP/jq/jq"
EXTRA_PATH=":$TMP/jq"
GATE_ENV=""

# Every run starts from a clean, attended, non-CI environment, whatever the
# environment running the tests looks like (CI sets CI=true).
run() { # run <player dir> <os> [VAR=value ...] -- args
  local players="$1" os="$2"
  shift 2
  local envs=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do envs+=("$1"); shift; done
  shift
  ( cd "${RUN_CWD:-$PROJ}" && env -i HOME="$TMP/home" PATH="$players:$TMP/os:$SYS${EXTRA_PATH:-}" FAKE_UNAME="$os" TMPDIR="$TMP/t" \
    _WD_ATTENTION_TTY="$TTY" ${GATE_ENV:+"$GATE_ENV"} ${envs[@]+"${envs[@]}"} /bin/bash "$SCRIPT" "$@" )
}

seed_entry() { printf '{"notifications":[{"storyId":"T-1","device":"default"}]}\n' > "${1:-$PROJ}/.workflow-dev/config.json"; }
reset() { : > "$LOG"; rm -f "$TTY"; seed_entry; }
wait_log() { local _; for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [[ -s "$LOG" ]] && return 0; sleep 0.05; done; return 1; }
played() { wait_log && cat "$LOG"; }
silent() { sleep 0.3; [[ ! -s "$LOG" && ! -e "$TTY" ]]; }
rang() { [[ -f "$TTY" ]] && [[ "$(od -An -c "$TTY" | tr -d ' ')" == '\a' ]]; }

expect_play() { # expect_play <name> <expected player word> -- run args...
  local name="$1" want="$2" out rc got
  shift 2
  reset
  out="$(run "$@")"; rc=$?
  got="$(played | head -1)"
  if [[ $rc -eq 0 && -z "$out" && "$got" == "$want "* ]]; then ok "$name"; else no "$name (rc=$rc out='$out' played='$got')"; fi
}
expect_bell() {
  local name="$1" out rc
  shift
  reset
  out="$(run "$@")"; rc=$?
  sleep 0.2
  if [[ $rc -eq 0 && -z "$out" && ! -s "$LOG" ]] && rang; then ok "$name"; else no "$name (rc=$rc out='$out')"; fi
}
expect_silent() {
  local name="$1" out rc
  shift
  reset
  out="$(run "$@")"; rc=$?
  if [[ $rc -eq 0 && -z "$out" ]] && silent; then ok "$name"; else no "$name (rc=$rc out='$out' log='$(cat "$LOG")')"; fi
}

# --- 1. the player follows the OS ----------------------------------------------
expect_play "Darwin plays with afplay" afplay "$TMP/mac" Darwin -- play
reset; run "$TMP/mac" Darwin -- play >/dev/null
[[ "$(played)" == "afplay $(cd -P "$HERE/.." && pwd -P)/assets/attention-need.wav" ]] && ok "play with no kind plays the need sound" || no "the bundled sound is the default (got: $(cat "$LOG"))"
expect_play "Linux prefers paplay" paplay "$TMP/pulse" Linux -- play
expect_play "Linux falls back to aplay" aplay "$TMP/alsa" Linux -- play
expect_bell "Linux with no player rings the bell" "$TMP/none" Linux -- play
expect_bell "Darwin without afplay rings the bell" "$TMP/pulse" Darwin -- play
expect_bell "an unknown OS rings the bell" "$TMP/mac" FreeBSD -- play

# --- 2. CI and non-interactive stay silent; WORKFLOW_DEV_ATTENTION is not read ---
for v in off OFF Off 0 false FALSE no No on; do
  expect_play "WORKFLOW_DEV_ATTENTION=$v no longer changes anything" afplay "$TMP/mac" Darwin "WORKFLOW_DEV_ATTENTION=$v" -- play
done
expect_bell "WORKFLOW_DEV_ATTENTION=off does not silence the bell" "$TMP/none" Linux WORKFLOW_DEV_ATTENTION=off -- play
expect_silent "CI=true is silent" "$TMP/mac" Darwin CI=true -- play
expect_silent "CI=1 is silent" "$TMP/mac" Darwin CI=1 -- play
expect_play "CI=false plays" afplay "$TMP/mac" Darwin CI=false -- play
expect_play "CI=0 plays" afplay "$TMP/mac" Darwin CI=0 -- play
expect_silent "a non-interactive session (ATTENDED=0) is silent" "$TMP/mac" Darwin CLAUDE_CODE_SESSION_ATTENDED=0 -- play
expect_play "an interactive session (ATTENDED=1) plays" afplay "$TMP/mac" Darwin CLAUDE_CODE_SESSION_ATTENDED=1 -- play

# --- 3. a custom sound, only when it is a readable regular file --------------
mkdir -p "$TMP/snd dir"
printf 'x' > "$TMP/snd dir/my sound.wav"
printf 'x' > "$TMP/proj/-dash.wav"
reset; run "$TMP/mac" Darwin "WORKFLOW_DEV_ATTENTION_SOUND=$TMP/snd dir/my sound.wav" -- play >/dev/null
[[ "$(played)" == "afplay $TMP/snd dir/my sound.wav" ]] && ok "a custom sound with spaces is played as one argument" || no "custom sound with spaces (got: $(cat "$LOG"))"
for bad in "$TMP/missing.wav" "$TMP/snd dir" ""; do
  reset; run "$TMP/mac" Darwin "WORKFLOW_DEV_ATTENTION_SOUND=$bad" -- play >/dev/null
  [[ "$(played)" == *"/assets/attention-need.wav" ]] && ok "custom sound '${bad##*/}' falls back to the bundled one" || no "custom sound '${bad##*/}' falls back (got: $(cat "$LOG"))"
done
if [[ "$(id -u)" != "0" ]]; then
  printf 'x' > "$TMP/locked.wav"; chmod 000 "$TMP/locked.wav"
  reset; run "$TMP/mac" Darwin "WORKFLOW_DEV_ATTENTION_SOUND=$TMP/locked.wav" -- play >/dev/null
  [[ "$(played)" == *"/assets/attention-need.wav" ]] && ok "an unreadable custom sound falls back" || no "an unreadable custom sound falls back (got: $(cat "$LOG"))"
fi
reset; (cd "$PROJ" && env -i HOME="$TMP/home" PATH="$TMP/mac:$TMP/os:$SYS:$TMP/jq" FAKE_UNAME=Darwin WORKFLOW_DEV_ATTENTION_SOUND=-dash.wav /bin/bash "$SCRIPT" play >/dev/null)
[[ "$(played)" == "afplay ./-dash.wav" ]] && ok "a path starting with - is passed as ./-…" || no "a leading-dash path (got: $(cat "$LOG"))"

# --- 4. never in the way ------------------------------------------------------
reset
start=$(date +%s)
out="$(run "$TMP/slow" Darwin -- play)"; rc=$?
elapsed=$(( $(date +%s) - start ))
[[ $rc -eq 0 && -z "$out" && $elapsed -lt 2 ]] && ok "a slow player does not hold the caller (${elapsed}s)" || no "a slow player held the caller (${elapsed}s, rc=$rc)"
reset
out="$(env -i HOME="$TMP/home" PATH="$TMP/none:$TMP/os:$SYS" FAKE_UNAME=Linux _WD_ATTENTION_TTY="$TMP/no/such/dir/tty" /bin/bash "$SCRIPT" play 2>&1)"; rc=$?
[[ $rc -eq 0 && -z "$out" ]] && ok "an unwritable tty is ignored, exit 0, no output" || no "an unwritable tty (rc=$rc out='$out')"
out="$(run "$TMP/mac" Darwin -- 2>/dev/null)"; rc=$?
[[ $rc -eq 2 ]] && ok "no argument is a usage error (exit 2)" || no "no argument is a usage error (rc=$rc)"
out="$(run "$TMP/mac" Darwin -- bogus 2>/dev/null)"; rc=$?
[[ $rc -eq 2 ]] && ok "an unknown subcommand is a usage error (exit 2)" || no "an unknown subcommand (rc=$rc)"

# --- 5. hooks: only armed Stops, plugin questions and permission prompts ------
mkdir -p "$TMP/plain" "$TMP/my proj/.workflow-dev/context" "$TMP/q\"x/.workflow-dev/context"
seed_entry "$TMP/my proj"; seed_entry "$TMP/q\"x"
N=0
new_sid() { N=$((N + 1)); SID="sess-$N"; }
payload() { # payload <session> <cwd json-escaped> [extra json]
  printf '{"session_id":"%s","cwd":"%s","hook_event_name":"x"%s}' "$1" "$2" "${3:-}"
}
hook() { # hook <flag> <payload> [VAR=value ...]
  local flag="$1" body="$2"
  shift 2
  printf '%s' "$body" | run "$TMP/mac" Darwin ${@+"$@"} -- "$flag"
}
arm_sid() { run "$TMP/mac" Darwin "CLAUDE_CODE_SESSION_ID=$1" -- arm; }
# The player is detached, so its log line can land after the hook returns —
# under load, well after. Wait for the expected count, then a little longer to
# catch an extra play, so a late line never leaks into the next case.
plays() { # plays [want]
  local want="${1:-0}" _ n
  for _ in $(seq 1 40); do
    n="$(wc -l < "$LOG" | tr -d ' ')"
    (( n >= want )) && break
    sleep 0.05
  done
  sleep 0.5
  wc -l < "$LOG" | tr -d ' '
}
check() { # check <name> <want plays>
  local got
  got="$(plays "$2")"
  [[ "$got" == "$2" ]] && ok "$1" || no "$1 (played $got, want $2: $(tr "\n" "|" < "$LOG"))"
}

hook_suite() {
  local tag="$1"
  STORE="$TMP/t/workflow-dev-validate/attention"

  new_sid; reset
  out="$(hook --stop "$(payload "$SID" "$PROJ")")"; rc=$?
  [[ $rc -eq 0 && -z "$out" ]] && check "$tag a plain Stop is silent (AC 1)" 0 || no "$tag a plain Stop (rc=$rc out='$out')"

  new_sid; reset
  arm_sid "$SID"; hook --stop "$(payload "$SID" "$PROJ")"
  check "$tag arm then Stop plays once" 1
  hook --stop "$(payload "$SID" "$PROJ")"
  check "$tag the next Stop is silent (AC 4)" 1
  [[ ! -e "$STORE/armed-$SID" ]] && ok "$tag the arm is consumed" || no "$tag the arm is consumed"

  new_sid; reset
  arm_sid "$SID"; arm_sid "$SID"; hook --stop "$(payload "$SID" "$PROJ")"; hook --stop "$(payload "$SID" "$PROJ")"
  check "$tag arming twice still plays once" 1

  new_sid; reset
  arm_sid "$SID"; hook --stop "$(payload "$SID" "$PROJ" ',"stop_hook_active":true')"
  check "$tag a Stop in the plain dir also plays when armed (the arm is the signal)" 1

  new_sid; reset
  arm_sid "other-$SID"; hook --stop "$(payload "$SID" "$PROJ")"
  check "$tag another session's arm does not sound here" 0

  new_sid; reset
  hook --ask "$(payload "$SID" "$PROJ")"
  check "$tag AskUserQuestion in a workflow-dev project plays" 1
  new_sid; reset
  hook --ask "$(payload "$SID" "$TMP/plain")"
  check "$tag AskUserQuestion outside a workflow-dev project is silent" 0
  new_sid; reset
  hook --ask "$(payload "$SID" "$TMP/my proj")"
  check "$tag a cwd with spaces is read" 1
  new_sid; reset
  hook --ask "$(payload "$SID" "$TMP/q\\\"x")"
  check "$tag a cwd with an escaped quote is read" 1

  new_sid; reset
  arm_sid "$SID"; hook --ask "$(payload "$SID" "$PROJ")"; hook --stop "$(payload "$SID" "$PROJ")"
  check "$tag an ask and the Stop of the same turn sound once" 1

  new_sid; reset
  hook --notify "$(payload "$SID" "$PROJ" ',"notification_type":"permission_prompt"')"
  check "$tag permission_prompt plays" 1
  new_sid; reset
  hook --notify "$(payload "$SID" "$PROJ" ',"notification_type":"idle_prompt"')"
  check "$tag idle_prompt is silent" 0
  new_sid; reset
  hook --notify "$(payload "$SID" "$PROJ")"
  check "$tag a notification with no type field trusts the matcher" 1
  new_sid; reset
  hook --notify "$(payload "$SID" "$TMP/plain" ',"notification_type":"permission_prompt"')"
  check "$tag permission_prompt outside a workflow-dev project is silent" 0

  new_sid; reset
  hook --ask "$(payload "$SID" "$PROJ")"; hook --notify "$(payload "$SID" "$PROJ" ',"notification_type":"permission_prompt"')"
  check "$tag an ask and a permission prompt back to back sound once" 1

  new_sid; reset
  hook --ask "$(payload "$SID" "$PROJ")"; hook --ask "$(payload "$SID" "$PROJ")"
  check "$tag two questions in a row are two events" 2
  new_sid; reset
  hook --notify "$(payload "$SID" "$PROJ" ',"notification_type":"permission_prompt"')"; hook --ask "$(payload "$SID" "$PROJ")"
  check "$tag a question right after a permission prompt is a new event" 2
  new_sid; reset
  mkdir -p "$STORE"; date +%s > "$STORE/last-$SID"
  hook --ask "$(payload "$SID" "$PROJ")"
  check "$tag a last-play record with no kind merges with nothing" 1
  new_sid; reset
  out="$(printf '%s' "$(payload "$SID" "$PROJ")" | env -i PATH=/nonexistent TMPDIR="$TMP/t-empty" /bin/bash "$SCRIPT" --stop 2>&1)"; rc=$?
  out2="$(printf '%s' "$(payload "$SID" "$PROJ")" | env -i PATH=/nonexistent TMPDIR="$TMP/t-empty" /bin/bash "$SCRIPT" --prompt 2>&1)"; rc2=$?
  [[ $rc -eq 0 && $rc2 -eq 0 && -z "$out$out2" ]] && ok "$tag Stop and prompt with nothing armed need no external command" || no "$tag fast path (rc=$rc/$rc2 out='$out$out2')"
  new_sid; reset
  hook --notify "$(payload "$SID" "$PROJ" ',"notification_type":"permission_prompt"')"
  arm_sid "$SID"; hook --stop "$(payload "$SID" "$PROJ")"
  check "$tag a hand-back right after an approved permission prompt still sounds" 2

  new_sid; reset
  arm_sid "$SID"; hook --prompt "$(payload "$SID" "$PROJ")"; hook --stop "$(payload "$SID" "$PROJ")"
  check "$tag a new prompt clears an arm left by an interrupted turn" 0
  [[ ! -e "$STORE/armed-$SID" ]] && ok "$tag --prompt removes the arm" || no "$tag --prompt removes the arm"
  out="$(hook --prompt '')"; rc=$?
  [[ $rc -eq 0 && -z "$out" ]] && ok "$tag --prompt with an empty payload is silent, exit 0" || no "$tag --prompt empty payload (rc=$rc)"

  mkdir -p "$PROJ/pkg/sub"
  new_sid; reset
  hook --ask "$(payload "$SID" "$PROJ/pkg/sub")"
  check "$tag a question from a subfolder of the project plays" 1

  new_sid; reset
  touch -t 202001010000 "$STORE/last-old-1"; printf 'x' > "$STORE/armed-old-2"; touch -t 202001010000 "$STORE/armed-old-2"
  arm_sid "$SID"
  [[ ! -e "$STORE/last-old-1" && ! -e "$STORE/armed-old-2" && -e "$STORE/armed-$SID" ]] && ok "$tag arm sweeps day-old files and keeps its own" || no "$tag arm sweeps day-old files ($(ls "$STORE"))"
  rm -f "$STORE/armed-$SID"

  new_sid; reset
  arm_sid "$SID"; hook --stop "$(payload "$SID" "$PROJ")" WORKFLOW_DEV_ATTENTION=off
  check "$tag WORKFLOW_DEV_ATTENTION=off is not read: an armed Stop plays" 1
  [[ ! -e "$STORE/armed-$SID" ]] && ok "$tag WORKFLOW_DEV_ATTENTION=off: the arm is consumed" || no "$tag WORKFLOW_DEV_ATTENTION=off: the arm is consumed"
  new_sid; reset
  arm_sid "$SID"; hook --stop "$(payload "$SID" "$PROJ")" CLAUDE_CODE_SESSION_ATTENDED=0
  check "$tag non-interactive: an armed Stop is silent" 0

  for bad in '' 'not json' '{}' '{"session_id":"../../etc","cwd":"x"}' '{"session_id":"a/b","cwd":"x"}' '{"session_id":"a b","cwd":"x"}' '[1,2]'; do
    reset
    out="$(hook --ask "$bad")"; rc=$?
    out2="$(hook --stop "$bad")"; rc2=$?
    if [[ $rc -eq 0 && $rc2 -eq 0 && -z "$out$out2" ]] && [[ "$(plays)" == 0 ]]; then ok "$tag payload '$bad' is silent, exit 0"; else no "$tag payload '$bad' (rc=$rc/$rc2 out='$out$out2')"; fi
  done
  [[ ! -e "$TMP/t/workflow-dev-validate/etc" && ! -e "$TMP/etc" && -z "$(ls "$STORE" 2>/dev/null | grep -v -E '^(armed|last)-(other-)?sess-[0-9]+$')" ]] && ok "$tag no stray file outside the store's own names" || no "$tag stray files: $(ls -a "$STORE")"

  reset
  out="$(run "$TMP/mac" Darwin -- arm)"; rc=$?
  [[ $rc -eq 0 && -z "$out" ]] && ok "$tag arm with no session id is a no-op" || no "$tag arm with no session id (rc=$rc)"
  reset
  run "$TMP/mac" Darwin "CLAUDE_CODE_SESSION_ID=../x" -- arm
  [[ ! -e "$TMP/t/workflow-dev-validate/x" ]] && ok "$tag arm refuses a session id with a path" || no "$tag arm refuses a session id with a path"

  new_sid; reset
  arm_sid "$SID"
  chmod 777 "$STORE"
  hook --stop "$(payload "$SID" "$PROJ")"
  check "$tag an untrusted store is silent" 0
  hook --ask "$(payload "$SID" "$PROJ")"
  check "$tag an untrusted store silences questions too" 0
  chmod 700 "$STORE"

  rm -rf "$TMP/t"
}

mkdir -p "$TMP/t"
EXTRA_PATH="" GATE_ENV="_WD_ATTENTION_ACTIVE=SEAM-1"$'\t'"default" hook_suite "[no jq]"
if [[ -x "$TMP/jq/jq" ]]; then
  mkdir -p "$TMP/t"
  hook_suite "[jq]"
else
  printf '  skip jq variant (no jq on this machine)\n'
fi

# --- 6. registration --------------------------------------------------------
HOOKS="$HERE/../hooks/hooks.json"
grep -q '"Stop"' "$HOOKS" && grep -q 'attention-alert.sh --stop' "$HOOKS" && ok "Stop is registered to --stop" || no "Stop is registered to --stop"
grep -A6 '"matcher": "permission_prompt"' "$HOOKS" | grep -q 'attention-alert.sh --notify' && ok "Notification:permission_prompt is registered to --notify" || no "Notification:permission_prompt is registered"
grep -A6 '"matcher": "AskUserQuestion"' "$HOOKS" | grep -q 'attention-alert.sh --ask' && ok "PreToolUse:AskUserQuestion is registered to --ask" || no "PreToolUse:AskUserQuestion is registered"
grep -q 'idle_prompt' "$HOOKS" && no "idle_prompt is never registered" || ok "idle_prompt is never registered"
grep -A14 '"UserPromptSubmit"' "$HOOKS" | grep -q 'attention-alert.sh --prompt' && ok "UserPromptSubmit is registered to --prompt" || no "UserPromptSubmit is registered to --prompt"

# --- 7. the skills arm where they hand back, and only there ------------------
ROOT="$HERE/.."
DOC="$ROOT/references/attention-alert.md"
grep -q '"\$PLUGIN_ROOT"/scripts/attention-alert.sh arm <kind>' "$DOC" && ok "the reference carries the arm command" || no "the reference carries the arm command"
grep -qF 'PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd -P "<this skill'"'"'s directory>/../.." && pwd -P)}"' "$DOC" && ok "the reference resolves PLUGIN_ROOT the standard way" || no "the reference resolves PLUGIN_ROOT the standard way"
for anchor in skills/plan/SKILL.md skills/validate/SKILL.md skills/implement/SKILL.md skills/manual-qa/SKILL.md skills/summarize-changes/SKILL.md skills/save/SKILL.md references/autonomous-mode.md; do
  grep -q 'attention-alert.md' "$ROOT/$anchor" && ok "$anchor points at the arm rule" || no "$anchor points at the arm rule"
done
[[ "$(grep -c 'attention-alert.md' "$ROOT/skills/validate/SKILL.md")" -ge 2 ]] && ok "validate arms at the depth question and at its end" || no "validate arms at the depth question and at its end"
for kind in need away permission commit pr done passed fail saved story; do
  grep -q "| \`$kind\` |" "$DOC" && ok "the reference documents kind $kind" || no "the reference documents kind $kind"
done
for pair in "skills/plan/SKILL.md:need" "skills/validate/SKILL.md:passed" "skills/validate/SKILL.md:fail" "skills/implement/SKILL.md:done" "skills/manual-qa/SKILL.md:done" "skills/summarize-changes/SKILL.md:commit" "skills/summarize-changes/SKILL.md:pr" "skills/save/SKILL.md:story" "skills/save/SKILL.md:saved" "references/autonomous-mode.md:story"; do
  grep -q "kind.*\`${pair##*:}\`\|\`${pair##*:}\`" "$ROOT/${pair%%:*}" && ok "${pair%%:*} arms ${pair##*:}" || no "${pair%%:*} arms ${pair##*:}"
done
for gone in 'First story on this machine' 'attention-alert\.sh device($|[^s])' 'set-volume' 'set-device'; do
  grep -qE "$gone" "$ROOT/skills/init/SKILL.md" "$DOC" "$ROOT/README.md" && no "docs no longer mention '$gone'" || ok "docs no longer mention '$gone'"
done
for want in 'Alerts for this story' 'attention-alert.sh prune' 'attention-alert.sh offer' 'Activate alerts for this story?' 'Yes (Recommended)' 'Never' 'never save a `No`' '(Suggested)' 'Choose source' '(Recommended)' 'Choose your speakers' "With low volume or on mute" 'It will only sound in your' 'Some processes take' 'set-pref' 'attention-alert.sh activate' 'attention-alert.sh play start' 'Agent (inferred)'; do
  grep -qF -- "$want" "$DOC" && ok "the reference carries '$want'" || no "the reference carries '$want'"
done
grep -qF 'Alerts for this story' "$ROOT/skills/init/SKILL.md" && ok "init asks the alerts question" || no "init alerts question"
grep -qF 'Alerts for this story' "$ROOT/references/autonomous-mode.md" && ok "the autonomous checkpoint carries the alerts question" || no "autonomous alerts question"
# `play start` is the one direct play a skill may ask for; every other kind is armed.
if grep -rn 'attention-alert.sh play' "$ROOT/skills" "$ROOT/references" | grep -v 'play start' >/dev/null; then no "no skill tells the agent to play directly (except start)"; else ok "no skill tells the agent to play directly (except start)"; fi

# --- 8. every kind has a short bundled WAV -----------------------------------
# Byte rate (offset 28) and data size (offset 40) of the canonical 44-byte header.
le32() { od -An -tu4 -j "$2" -N 4 "$1" | tr -d ' '; }
for kind in need away permission commit pr done passed fail saved story start; do
  f="$ASSETS/attention-$kind.wav"
  hdr="$(head -c 12 "$f" 2>/dev/null | od -An -c | tr -d ' \n')"
  rate="$(le32 "$f" 28)"; size="$(le32 "$f" 40)"
  # One-line alerts stay under 3 s; the two-part away call and the story fanfare
  # plus its line, under 5 s.
  limit=3000; [[ "$kind" == story || "$kind" == away ]] && limit=5000
  if [[ "$hdr" == RIFF*WAVE && -n "$rate" && "$rate" -gt 0 && $(( size * 1000 / rate )) -lt $limit ]]; then
    ok "attention-$kind.wav is a WAV under $(( limit / 1000 )) s ($(( size * 1000 / rate )) ms)"
  else
    no "attention-$kind.wav is a WAV under $(( limit / 1000 )) s (hdr=$hdr rate=$rate size=$size)"
  fi
done

reset; run "$TMP/mac" Darwin -- play start >/dev/null
[[ "$(played)" == *"/assets/attention-start.wav" ]] && ok "play start plays the start sound (not need)" || no "play start (got: $(cat "$LOG"))"
reset; run "$TMP/mac" Darwin "CLAUDE_CODE_SESSION_ID=start-1" -- arm start >/dev/null
[[ "$(head -n 1 "$TMP/t/workflow-dev-validate/attention/armed-start-1" 2>/dev/null)" == start ]] && ok "arm keeps the start kind (it is a known kind)" || no "arm start (got: $(cat "$TMP/t/workflow-dev-validate/attention/armed-start-1" 2>/dev/null))"

# --- 9. each event plays its own sound ---------------------------------------
reset; run "$TMP/mac" Darwin -- play done >/dev/null
[[ "$(played)" == *"/assets/attention-done.wav" ]] && ok "play done plays the done sound" || no "play done (got: $(cat "$LOG"))"
reset; run "$TMP/mac" Darwin -- play bogus >/dev/null
[[ "$(played)" == *"/assets/attention-need.wav" ]] && ok "an unknown kind falls back to need" || no "unknown kind (got: $(cat "$LOG"))"
reset; run "$TMP/mac" Darwin "WORKFLOW_DEV_ATTENTION_SOUND=$TMP/snd dir/my sound.wav" -- play story >/dev/null
[[ "$(played)" == "afplay $TMP/snd dir/my sound.wav" ]] && ok "a custom sound replaces every kind" || no "custom sound for story (got: $(cat "$LOG"))"
mkdir -p "$TMP/t" "$PROJ"
for pair in "need:need" "commit:commit" "pr:pr" "done:done" "passed:passed" "fail:fail" "saved:saved" "story:story" ":need" "nonsense:need"; do
  armk="${pair%%:*}"; want="${pair##*:}"
  new_sid; reset
  run "$TMP/mac" Darwin "CLAUDE_CODE_SESSION_ID=$SID" -- arm ${armk:+"$armk"}
  hook --stop "$(payload "$SID" "$PROJ")"
  [[ "$(played)" == *"/assets/attention-$want.wav" ]] && ok "arm '${armk}' then Stop plays $want" || no "arm '${armk}' then Stop (got: $(cat "$LOG"))"
done
# One arm file per session: the last arm wins, so a turn that arms two kinds
# plays one sound, never both (WD-0067).
for pair in "saved story:story" "story saved:saved"; do
  first="${pair%% *}"; rest="${pair#* }"; second="${rest%%:*}"; want="${rest##*:}"
  new_sid; reset
  run "$TMP/mac" Darwin "CLAUDE_CODE_SESSION_ID=$SID" -- arm "$first"
  run "$TMP/mac" Darwin "CLAUDE_CODE_SESSION_ID=$SID" -- arm "$second"
  hook --stop "$(payload "$SID" "$PROJ")"
  [[ "$(played)" == *"/assets/attention-$want.wav" && "$(wc -l < "$LOG" | tr -d ' ')" == 1 ]] \
    && ok "arm $first then $second plays only $want" || no "arm $first then $second (got: $(cat "$LOG"))"
done
reset; run "$TMP/mac" Darwin -- play saved >/dev/null
[[ "$(played)" == *"/assets/attention-saved.wav" ]] && ok "play saved plays the saved sound" || no "play saved (got: $(cat "$LOG"))"
new_sid; reset
mkdir -p "$TMP/t/workflow-dev-validate/attention"; chmod 700 "$TMP/t/workflow-dev-validate" "$TMP/t/workflow-dev-validate/attention"
printf 'armed\n' > "$TMP/t/workflow-dev-validate/attention/armed-$SID"
hook --stop "$(payload "$SID" "$PROJ")"
[[ "$(played)" == *"/assets/attention-need.wav" ]] && ok "an arm from before kinds existed plays need" || no "legacy arm (got: $(cat "$LOG"))"
new_sid; reset
hook --ask "$(payload "$SID" "$PROJ")"
[[ "$(played)" == *"/assets/attention-need.wav" ]] && ok "a question plays need" || no "ask sound (got: $(cat "$LOG"))"
new_sid; reset
hook --notify "$(payload "$SID" "$PROJ" ',"notification_type":"permission_prompt"')"
[[ "$(played)" == *"/assets/attention-permission.wav" ]] && ok "a permission prompt plays permission" || no "notify sound (got: $(cat "$LOG"))"
printf '#!/bin/bash\necho "running 4242"\n' > "$TMP/awake-running"
printf '#!/bin/bash\necho "not-running"\n' > "$TMP/awake-idle"
printf '#!/bin/bash\nexit 3\n' > "$TMP/awake-broken"
chmod +x "$TMP/awake-running" "$TMP/awake-idle" "$TMP/awake-broken"
new_sid; reset
hook --ask "$(payload "$SID" "$PROJ")" "_WD_KEEP_AWAKE=$TMP/awake-running"
[[ "$(played)" == *"/assets/attention-away.wav" ]] && ok "a question mid autonomous run plays away" || no "autonomous ask (got: $(cat "$LOG"))"
new_sid; reset
hook --ask "$(payload "$SID" "$PROJ")" "_WD_KEEP_AWAKE=$TMP/awake-idle"
[[ "$(played)" == *"/assets/attention-need.wav" ]] && ok "a question with no autonomous run plays need" || no "idle ask (got: $(cat "$LOG"))"
new_sid; reset
hook --ask "$(payload "$SID" "$PROJ")" "_WD_KEEP_AWAKE=$TMP/awake-broken"
[[ "$(played)" == *"/assets/attention-need.wav" ]] && ok "a broken keep-awake check falls back to need" || no "broken keep-awake (got: $(cat "$LOG"))"
new_sid; reset
hook --notify "$(payload "$SID" "$PROJ" ',"notification_type":"permission_prompt"')" "_WD_KEEP_AWAKE=$TMP/awake-running"
[[ "$(played)" == *"/assets/attention-permission.wav" ]] && ok "a permission prompt mid autonomous run still plays permission" || no "autonomous notify (got: $(cat "$LOG"))"
mkdir -p "$TMP/plug/scripts" "$TMP/plug/assets"
cp "$SCRIPT" "$HERE/marker-dir.sh" "$TMP/plug/scripts/"
cp "$ASSETS/attention-need.wav" "$TMP/plug/assets/"
reset; ( cd "$PROJ" && env -i HOME="$TMP/home" PATH="$TMP/mac:$TMP/os:$SYS:$TMP/jq" FAKE_UNAME=Darwin /bin/bash "$TMP/plug/scripts/attention-alert.sh" play story ) >/dev/null
[[ "$(played)" == *"/plug/assets/attention-need.wav" ]] && ok "a kind whose file is missing plays need" || no "missing kind file (got: $(cat "$LOG"))"
# --- 10. where the sounds play: the output comes from the environment ---------
H="$TMP/home"
HELPER="$H/.workflow-dev/bin/attention-play"
fake_helper() { # a stand-in for the compiled macOS helper: lists two outputs,
  # "plays" by logging, and fails for an output named Gone (unplugged)
  mkdir -p "${HELPER%/*}"
  cat > "$HELPER" <<EOF
#!/bin/bash
if [[ "\$1" == --list ]]; then
  printf 'usb\tdefault\tHeadset\nbuiltin\t-\tMacBook Pro Speakers\n'
  exit 0
fi
[[ "\$1" == Gone ]] && exit 1
printf 'helper %s\n' "\$*" >> "$LOG"
EOF
  chmod +x "$HELPER"
  touch "$HELPER"
}
rm -rf "$H"
reset; run "$TMP/mac" Darwin "WORKFLOW_DEV_ATTENTION_DEVICE=MacBook Pro Speakers" -- play done >/dev/null
[[ "$(played)" == "afplay "*"/assets/attention-done.wav" ]] && ok "with no helper the default output plays" || no "no helper fallback (got: $(cat "$LOG"))"
fake_helper
reset; run "$TMP/mac" Darwin "WORKFLOW_DEV_ATTENTION_DEVICE=MacBook Pro Speakers" -- play done >/dev/null
[[ "$(played)" == "helper MacBook Pro Speakers "*"/assets/attention-done.wav" ]] && ok "the chosen output plays through the helper" || no "helper play (got: $(cat "$LOG"))"
[[ "$(run "$TMP/mac" Darwin -- suggest)" == "MacBook Pro Speakers" ]] && ok "suggest names the built-in output" || no "suggest (got: $(run "$TMP/mac" Darwin -- suggest))"
[[ "$(run "$TMP/mac" Darwin -- devices | wc -l | tr -d ' ')" == 2 ]] && ok "devices lists every output" || no "devices"
reset; run "$TMP/mac" Darwin "WORKFLOW_DEV_ATTENTION_DEVICE=Gone" -- play done >/dev/null
[[ "$(played)" == "afplay "*"/assets/attention-done.wav" ]] && ok "an unplugged output falls back to the default output" || no "unplugged fallback (got: $(cat "$LOG"))"
reset; run "$TMP/mac" Darwin "WORKFLOW_DEV_ATTENTION_DEVICE=default" -- play done >/dev/null
[[ "$(played)" == "afplay "* ]] && ok "WORKFLOW_DEV_ATTENTION_DEVICE=default plays on the default output" || no "env default (got: $(cat "$LOG"))"
reset; run "$TMP/mac" Darwin -- play done >/dev/null
[[ "$(played)" == "afplay "* ]] && ok "with no device chosen the default output plays" || no "no device (got: $(cat "$LOG"))"
# A retired machine file is never read: not its device, not its volume.
mkdir -p "$H/.workflow-dev"
printf '{"device": "MacBook Pro Speakers", "volume": "25"}\n' > "$H/.workflow-dev/attention.json"
reset; run "$TMP/mac" Darwin -- play done >/dev/null
[[ "$(played)" == "afplay /"*"/assets/attention-done.wav" ]] && ok "attention.json is no longer read (no device, no -v)" || no "attention.json ignored (got: $(cat "$LOG"))"
for gone in set-device set-volume device volume; do
  run "$TMP/mac" Darwin -- "$gone" x >/dev/null 2>&1; rc=$?
  [[ $rc -eq 2 ]] && ok "'$gone' is no longer a command (usage error)" || no "'$gone' retired (rc=$rc)"
done
reset; run "$TMP/mac" Darwin WORKFLOW_DEV_ATTENTION_VOLUME=40 -- play done >/dev/null
[[ "$(played)" == "afplay /"* ]] && ok "WORKFLOW_DEV_ATTENTION_VOLUME is ignored (no -v)" || no "volume env ignored (got: $(cat "$LOG"))"
# Linux: the players take the output name directly.
fake "$TMP/pulsedev" paplay 'for a in "$@"; do [[ "$a" == --device=Gone ]] && exit 1; done'
fake "$TMP/alsadev" aplay 'for a in "$@"; do [[ "$a" == Gone ]] && exit 1; done'
reset; run "$TMP/pulsedev" Linux WORKFLOW_DEV_ATTENTION_DEVICE=alsa_output.pci-0000.analog-stereo -- play done >/dev/null
[[ "$(played)" == "paplay --device=alsa_output.pci-0000.analog-stereo "*"/attention-done.wav" ]] && ok "Linux paplay gets --device" || no "paplay device (got: $(cat "$LOG"))"
reset; run "$TMP/alsadev" Linux WORKFLOW_DEV_ATTENTION_DEVICE=alsa_output.pci-0000.analog-stereo -- play done >/dev/null
[[ "$(played)" == "aplay -D alsa_output.pci-0000.analog-stereo "*"/attention-done.wav" ]] && ok "Linux aplay gets -D" || no "aplay device (got: $(cat "$LOG"))"
reset; run "$TMP/pulsedev" Linux WORKFLOW_DEV_ATTENTION_DEVICE=Gone -- play done >/dev/null; sleep 0.3
[[ "$(tail -1 "$LOG")" == "paplay "*"/attention-done.wav" && "$(tail -1 "$LOG")" != *--device* ]] && ok "Linux falls back to the default output when the device fails" || no "paplay fallback (got: $(cat "$LOG"))"
rm -rf "$H"

# --- 12. alerts per story: the saved choice and the repo's entries -------------
HAVE_JQ=1; command -v jq >/dev/null 2>&1 || HAVE_JQ=0
SP="$TMP/storyproj"
rm -rf "$SP" "$TMP/home"; mkdir -p "$SP/.workflow-dev/context" "$SP/sub/dir"
( cd "$SP" && git init -q && git checkout -q -b wd-0068-alertas-por-story && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init ) >/dev/null 2>&1
inp() { RUN_CWD="${INP_DIR:-$SP}" run "$TMP/mac" Darwin "$@"; }
if [[ $HAVE_JQ -eq 1 ]]; then
  [[ "$(inp -- pref)" == unset ]] && ok "no saved choice reads as unset" || no "fresh pref"
  [[ "$(inp -- set-pref "MacBook Pro Speakers")" == saved && "$(inp -- pref)" == "MacBook Pro Speakers" ]] && ok "set-pref is saved and read back" || no "set-pref"
  jq -e '.userPref.notifications.device == "MacBook Pro Speakers"' "$TMP/home/.workflow-dev/config.json" >/dev/null && ok "the choice lives at userPref.notifications.device" || no "pref shape"
  [[ -n "$(find "$TMP/home/.workflow-dev" -maxdepth 0 -perm 700)" ]] && ok "the user folder is private (700)" || no "user folder mode"
  printf '{"userPref": {"other": 1}, "keep": "me"}\n' > "$TMP/home/.workflow-dev/config.json"
  inp -- set-pref "Headset" >/dev/null
  jq -e '.keep == "me" and .userPref.other == 1 and .userPref.notifications.device == "Headset"' "$TMP/home/.workflow-dev/config.json" >/dev/null && ok "set-pref keeps every other key" || no "set-pref keeps keys"
  inp -- set-pref 'Bob "Big" Speaker\x' >/dev/null
  [[ "$(inp -- pref)" == 'Bob "Big" Speaker\x' ]] && ok "a name with quotes and a backslash round-trips" || no "quoted name"
  for bad in "$(printf 'two\nlines')" "$(printf 'a\tb')"; do
    [[ "$(inp -- set-pref "$bad")" == invalid ]] && ok "a name with a control character is refused" || no "control char name"
  done
  printf 'not json' > "$TMP/home/.workflow-dev/config.json"
  [[ "$(inp -- set-pref x)" == unavailable && "$(cat "$TMP/home/.workflow-dev/config.json")" == "not json" ]] && ok "an unreadable config is left untouched (unavailable)" || no "corrupt user config"
  printf '[1,2]' > "$TMP/home/.workflow-dev/config.json"
  [[ "$(inp -- set-pref x)" == unavailable && "$(cat "$TMP/home/.workflow-dev/config.json")" == "[1,2]" ]] && ok "a config whose root is not an object is left untouched" || no "array root user config"
  rm -f "$TMP/home/.workflow-dev/config.json"

  [[ -z "$(inp -- entries)" && -z "$(inp -- active)" ]] && ok "a repo with no config has no entries" || no "no entries"
  printf '{"gitignored": true, "language": "es"}\n' > "$SP/.workflow-dev/config.json"
  [[ "$(inp -- activate WD-0068 "MacBook Pro Speakers")" == saved ]] && ok "activate saves an entry" || no "activate"
  jq -e '.gitignored == true and .language == "es" and .notifications == [{"storyId":"WD-0068","device":"MacBook Pro Speakers"}]' "$SP/.workflow-dev/config.json" >/dev/null && ok "activate keeps every other key" || no "activate keeps keys"
  [[ "$(inp -- active)" == $'WD-0068\tMacBook Pro Speakers' ]] && ok "the only entry is the active one" || no "only entry (got: $(inp -- active))"
  inp -- activate wd-0068 Headset >/dev/null
  [[ "$(inp -- entries | wc -l | tr -d ' ')" == 1 && "$(inp -- active)" == $'wd-0068\tHeadset' ]] && ok "activating the same story again replaces its entry (any case)" || no "replace entry"
  inp -- activate WD-0070 Other >/dev/null
  [[ "$(inp -- active)" == $'wd-0068\tHeadset' ]] && ok "with two entries, the one named in the branch is active" || no "branch match (got: $(inp -- active))"
  ( cd "$SP" && git checkout -q -b wd-0070-otra-cosa )
  [[ "$(inp -- active)" == $'WD-0070\tOther' ]] && ok "switching branch switches the active story" || no "branch switch (got: $(inp -- active))"
  ( cd "$SP" && git checkout -q -b main-work )
  [[ -z "$(inp -- active)" ]] && ok "two entries and no branch match: none is active" || no "no match (got: $(inp -- active))"
  ( cd "$SP" && git checkout -q -b wd-006-short )
  inp -- activate WD-006 Short >/dev/null
  ( cd "$SP" && git checkout -q wd-0068-alertas-por-story )
  [[ "$(inp -- active)" == $'wd-0068\tHeadset' ]] && ok "an id inside a longer one does not match (WD-006 vs WD-0068)" || no "id boundary (got: $(inp -- active))"
  INP_DIR="$SP/sub/dir"
  [[ "$(inp -- active)" == $'wd-0068\tHeadset' ]] && ok "the entry is found from a subdirectory" || no "subdir lookup"
  INP_DIR=
  [[ "$(inp -- deactivate wd-0068)" == removed && "$(inp -- entries | grep -c 'wd-0068')" == 0 ]] && ok "deactivate drops the entry (any case)" || no "deactivate"
  jq -e '.gitignored == true and .language == "es"' "$SP/.workflow-dev/config.json" >/dev/null && ok "deactivate keeps every other key" || no "deactivate keeps keys"
  [[ "$(inp -- deactivate WD-9999)" == removed ]] && ok "deactivating a story with no entry is harmless" || no "deactivate none"
  for bad in 'a b' 'x;y' '../x' ''; do
    out="$(inp -- activate "$bad" Dev 2>&1)"; rc=$?
    if [[ -z "$bad" ]]; then [[ $rc -eq 2 ]]; else [[ "$out" == invalid ]]; fi && ok "activate refuses story id '$bad'" || no "bad story id '$bad' (rc=$rc out=$out)"
  done
  [[ "$(inp -- activate WD-1 "$(printf 'a\tb')")" == invalid ]] && ok "activate refuses a device with a control character" || no "bad device"
  printf '{"notifications": "oops"}' > "$SP/.workflow-dev/config.json"
  [[ "$(inp -- activate WD-1 Dev)" == unavailable && "$(cat "$SP/.workflow-dev/config.json")" == '{"notifications": "oops"}' ]] && ok "a notifications key that is not a list is left untouched" || no "bad notifications"
  [[ -z "$(inp -- entries)" && -z "$(inp -- active)" ]] && ok "a notifications key that is not a list has no entries" || no "bad notifications read"
  printf 'not json' > "$SP/.workflow-dev/config.json"
  [[ "$(inp -- activate WD-1 Dev)" == unavailable && "$(cat "$SP/.workflow-dev/config.json")" == 'not json' ]] && ok "an unreadable repo config is left untouched" || no "corrupt repo config"
  [[ -z "$(inp -- entries)" ]] && ok "an unreadable repo config has no entries" || no "corrupt read"
  printf '{"notifications":[{"storyId":"A"},{"storyId":1,"device":"x"},"s",{"storyId":"B","device":"Dev"}]}' > "$SP/.workflow-dev/config.json"
  [[ "$(inp -- entries)" == $'B\tDev' ]] && ok "entries skips malformed items" || no "malformed items (got: $(inp -- entries))"
  rm -f "$SP/.workflow-dev/config.json"
  OUT="$TMP/nowf"; mkdir -p "$OUT"
  [[ "$(RUN_CWD="$OUT" run "$TMP/mac" Darwin -- activate WD-1 Dev)" == unavailable ]] && ok "activate outside a workflow-dev project is unavailable" || no "activate outside project"
  for need in "activate WD-1" "set-pref"; do
    run "$TMP/mac" Darwin -- $need >/dev/null 2>&1; rc=$?
    [[ $rc -eq 2 ]] && ok "'$need' with a missing argument is a usage error" || no "usage '$need' (rc=$rc)"
  done
else
  printf '  skip alerts-per-story storage (no jq on this machine)\n'
fi
# Without jq nothing can be written, and nothing is read.
nojq="$TMP/nojq"; mkdir -p "$nojq"
for tool in dirname tr sleep cat mv rm mkdir mktemp chmod find date basename sed grep head awk ls seq wc git rmdir cp readlink; do
  real="$(command -v "$tool")" && ln -sf "$real" "$nojq/$tool"
done
printf '#!/bin/bash\necho Darwin\n' > "$nojq/uname"; chmod +x "$nojq/uname"
nj() { ( cd "$SP" && env -i HOME="$TMP/home" PATH="$TMP/mac:$nojq" /bin/bash "$SCRIPT" "$@" ); }
rm -rf "$TMP/home"
[[ "$(nj set-pref Dev)" == unavailable && ! -e "$TMP/home/.workflow-dev/config.json" ]] && ok "without jq, set-pref is unavailable and writes nothing" || no "no jq set-pref"
[[ "$(nj activate WD-1 Dev)" == unavailable && ! -e "$SP/.workflow-dev/config.json" ]] && ok "without jq, activate is unavailable and writes nothing" || no "no jq activate"
printf '{"notifications":[{"storyId":"WD-1","device":"Dev"}]}' > "$SP/.workflow-dev/config.json"
[[ -z "$(nj entries)" && -z "$(nj active)" && "$(nj pref)" == unset ]] && ok "without jq, nothing is read" || no "no jq read"
rm -rf "$SP/.workflow-dev/config.json" "$TMP/home"

# --- 12b. the gate: sound only for a story that turned the alerts on ---------
GP="$TMP/gateproj"
rm -rf "$GP"; mkdir -p "$GP/.workflow-dev/context"
( cd "$GP" && git init -q && git checkout -q -b wd-0068-x && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m i ) >/dev/null 2>&1
gp() { RUN_CWD="$GP" run "$TMP/mac" Darwin "$@"; }
gphook() { # gphook <flag> <extra json> [VAR=value ...]
  local flag="$1" extra="$2"; shift 2
  printf '%s' "$(payload "g-$N" "$GP" "$extra")" | RUN_CWD="$GP" run "$TMP/mac" Darwin ${@+"$@"} -- "$flag"
}
printf '{"notifications":[{"storyId":"WD-0068","device":"default"}]}\n' > "$GP/.workflow-dev/config.json"
reset; gp -- play done >/dev/null
[[ "$(played)" == "afplay "*"/attention-done.wav" ]] && ok "a story with an entry sounds" || no "entry sounds (got: $(cat "$LOG"))"
for kind in need permission commit pr done passed fail saved story away start; do
  reset; printf '{"language":"es"}\n' > "$GP/.workflow-dev/config.json"; gp -- play "$kind" >/dev/null
  silent && ok "no entry: '$kind' is silent" || no "no entry '$kind' (got: $(cat "$LOG"))"
done
printf '{"notifications":[{"storyId":"WD-0068","device":"default"}]}\n' > "$GP/.workflow-dev/config.json"
printf '{"notifications":[{"storyId":"WD-0050","device":"default"},{"storyId":"WD-0051","device":"default"}]}\n' > "$GP/.workflow-dev/config.json"
reset; gp -- play done >/dev/null
silent && ok "several entries and none named by the branch: silent" || no "ambiguous entries (got: $(cat "$LOG"))"
printf '{"notifications":[{"storyId":"WD-0068","device":"default"},{"storyId":"WD-0050","device":"default"}]}\n' > "$GP/.workflow-dev/config.json"
reset; gp -- play done >/dev/null
[[ "$(played)" == "afplay "* ]] && ok "another story of the same repo has its own entry: the branch's story sounds" || no "own entry (got: $(cat "$LOG"))"
mkdir -p "$TMP/nowf2"; reset; RUN_CWD="$TMP/nowf2" run "$TMP/mac" Darwin -- play done >/dev/null
silent && ok "outside any workflow-dev project: silent" || no "no project (got: $(cat "$LOG"))"
printf '{"notifications":[{"storyId":"WD-0068","device":"default"}]}\n' > "$GP/.workflow-dev/config.json"
for v in "CI=true" "CLAUDE_CODE_SESSION_ATTENDED=0"; do
  reset; gp "$v" -- play done >/dev/null
  silent && ok "an entry does not override $v" || no "entry vs $v"
done
reset; gp WORKFLOW_DEV_ATTENTION=off -- play done >/dev/null
[[ "$(played)" == "afplay "* ]] && ok "an entry and WORKFLOW_DEV_ATTENTION=off in the environment: it sounds" || no "entry vs off (got: $(cat "$LOG"))"
# the entry's output is used, the environment's wins, and a missing one falls back
fake_helper
printf '{"notifications":[{"storyId":"WD-0068","device":"MacBook Pro Speakers"}]}\n' > "$GP/.workflow-dev/config.json"
reset; gp -- play done >/dev/null
[[ "$(played)" == "helper MacBook Pro Speakers "*"/attention-done.wav" ]] && ok "the entry's output plays through the helper" || no "entry device (got: $(cat "$LOG"))"
reset; gp WORKFLOW_DEV_ATTENTION_DEVICE=default -- play done >/dev/null
[[ "$(played)" == "afplay "* ]] && ok "WORKFLOW_DEV_ATTENTION_DEVICE wins over the entry's output" || no "env over entry (got: $(cat "$LOG"))"
printf '{"notifications":[{"storyId":"WD-0068","device":"Gone"}]}\n' > "$GP/.workflow-dev/config.json"
reset; gp -- play done >/dev/null
[[ "$(played)" == "afplay "* ]] && ok "an entry whose output is unplugged falls back to the default output" || no "entry gone (got: $(cat "$LOG"))"
rm -rf "$H"
# hooks gate too, through the payload's cwd
printf '{"notifications":[{"storyId":"WD-0068","device":"default"}]}\n' > "$GP/.workflow-dev/config.json"
N=$((N + 1)); reset; gphook --ask '' >/dev/null
[[ "$(played)" == *"/attention-need.wav" ]] && ok "a question sounds when the cwd's story has an entry" || no "ask with entry (got: $(cat "$LOG"))"
printf '{"language":"es"}\n' > "$GP/.workflow-dev/config.json"
N=$((N + 1)); reset; gphook --ask '' >/dev/null
silent && ok "a question is silent when the cwd's story has no entry" || no "ask without entry"
N=$((N + 1)); reset; gphook --notify ',"notification_type":"permission_prompt"' >/dev/null
silent && ok "a permission prompt is silent when the cwd's story has no entry" || no "notify without entry"
N=$((N + 1)); SIDG="g-$N"; reset; RUN_CWD="$GP" run "$TMP/mac" Darwin "CLAUDE_CODE_SESSION_ID=$SIDG" -- arm done >/dev/null
printf '%s' "$(payload "$SIDG" "$GP")" | RUN_CWD="$GP" run "$TMP/mac" Darwin -- --stop >/dev/null
silent && ok "an armed Stop is silent when the story has no entry" || no "stop without entry"
# the fanfare ends the story's alerts, but only once its context says Done
printf '### Implementation Status: Done\n' > "$GP/.workflow-dev/context/WD-0068.md"
printf '{"gitignored":true,"notifications":[{"storyId":"WD-0068","device":"default"},{"storyId":"WD-0050","device":"default"}]}\n' > "$GP/.workflow-dev/config.json"
N=$((N + 1)); SIDG="g-$N"; reset; printf '{"gitignored":true,"notifications":[{"storyId":"WD-0068","device":"default"},{"storyId":"WD-0050","device":"default"}]}\n' > "$GP/.workflow-dev/config.json"
RUN_CWD="$GP" run "$TMP/mac" Darwin "CLAUDE_CODE_SESSION_ID=$SIDG" -- arm story >/dev/null
printf '%s' "$(payload "$SIDG" "$GP")" | RUN_CWD="$GP" run "$TMP/mac" Darwin -- --stop >/dev/null
[[ "$(played)" == *"/attention-story.wav" ]] && ok "the story fanfare sounds" || no "story fanfare (got: $(cat "$LOG"))"
jq -e '.gitignored == true and .notifications == [{"storyId":"WD-0050","device":"default"}]' "$GP/.workflow-dev/config.json" >/dev/null && ok "after the fanfare the story's entry is gone and the rest is kept" || no "entry removed after story ($(cat "$GP/.workflow-dev/config.json"))"
# a fanfare for a story whose context is still In Progress keeps the entry
printf '### Implementation Status: In Progress\n' > "$GP/.workflow-dev/context/WD-0068.md"
N=$((N + 1)); SIDG="g-$N"; reset; printf '{"notifications":[{"storyId":"WD-0068","device":"default"}]}\n' > "$GP/.workflow-dev/config.json"
RUN_CWD="$GP" run "$TMP/mac" Darwin "CLAUDE_CODE_SESSION_ID=$SIDG" -- arm story >/dev/null
printf '%s' "$(payload "$SIDG" "$GP")" | RUN_CWD="$GP" run "$TMP/mac" Darwin -- --stop >/dev/null
played >/dev/null; jq -e '.notifications | length == 1' "$GP/.workflow-dev/config.json" >/dev/null && ok "the entry stays while the story's context is not Done" || no "entry kept while In Progress"
N=$((N + 1)); SIDG="g-$N"; reset; printf '{"notifications":[{"storyId":"WD-0068","device":"default"}]}\n' > "$GP/.workflow-dev/config.json"
RUN_CWD="$GP" run "$TMP/mac" Darwin "CLAUDE_CODE_SESSION_ID=$SIDG" -- arm done >/dev/null
printf '%s' "$(payload "$SIDG" "$GP")" | RUN_CWD="$GP" run "$TMP/mac" Darwin -- --stop >/dev/null
played >/dev/null; jq -e '.notifications | length == 1' "$GP/.workflow-dev/config.json" >/dev/null && ok "any other kind keeps the entry" || no "other kinds keep the entry"
rm -rf "$GP" "$TMP/home"

# --- 12c. what init offers, and pruning stale entries --------------------------
OP="$TMP/offerproj"
rm -rf "$OP" "$TMP/home"; mkdir -p "$OP/.workflow-dev/context"
op() { RUN_CWD="$OP" run "$TMP/mac" Darwin "$@"; }
printf '{"language":"es"}\n' > "$OP/.workflow-dev/config.json"
out="$(op -- offer)"
[[ "$out" == "default-only" || "$(printf '%s\n' "$out" | tail -1)" == "default-only" ]] && ok "offer: a Mac with no helper can only use the default output" || no "offer default-only (got: $out)"
[[ "$(printf '%s\n' "$out" | head -1)" == first ]] && ok "offer: nothing saved is 'first'" || no "offer first (got: $out)"
fake_helper
out="$(op -- offer)"
[[ "$(printf '%s\n' "$out" | sed -n 1p)" == first ]] && ok "offer: with outputs and no saved choice it is 'first'" || no "offer first (got: $out)"
[[ "$(printf '%s\n' "$out" | sed -n 2p)" == $'recommended\t-\tMacBook Pro Speakers' ]] && ok "offer: the built-in speakers come first and recommended" || no "offer speakers first (got: $out)"
[[ "$(printf '%s\n' "$out" | sed -n 3p)" == $'-\tdefault\tHeadset' ]] && ok "offer: the other outputs follow, the default one marked" || no "offer rest (got: $out)"
[[ "$out" != *nospeaker* ]] && ok "offer: speakers found, no 'nospeaker'" || no "offer nospeaker wrongly"
op -- set-pref "MacBook Pro Speakers" >/dev/null
[[ "$(op -- offer | head -1)" == $'suggest\tMacBook Pro Speakers' ]] && ok "offer: a saved output that is still there is suggested" || no "offer suggest (got: $(op -- offer | head -1))"
op -- set-pref "Gone" >/dev/null
[[ "$(op -- offer | head -1)" == list ]] && ok "offer: a saved output that is gone gives the full list" || no "offer list (got: $(op -- offer | head -1))"
# no speaker: only a headset and a display
cat > "$HELPER" <<EOF
#!/bin/bash
if [[ "\$1" == --list ]]; then
  printf 'usb\tdefault\tHeadset\ndisplay\t-\tDELL Monitor\nbuiltin\t-\tExternal Headphones\n'
  exit 0
fi
printf 'helper %s\n' "\$*" >> "$LOG"
EOF
chmod +x "$HELPER"; touch "$HELPER"
out="$(op -- offer)"
[[ "$out" == *nospeaker* && "$out" != *recommended* ]] && ok "offer: no speakers means 'nospeaker' and no recommended output (a headset jack is not a speaker)" || no "offer nospeaker (got: $out)"
[[ "$(op -- suggest)" == "" ]] && ok "suggest names no output when only a headset jack is built in" || no "suggest headset"
rm -rf "$TMP/home"
[[ "$(op -- offer | head -1)" == first ]] && ok "offer: 'first' again once the saved choice is gone" || no "offer first again"

# prune keeps only the stories still In Progress
printf '### Implementation Status: In Progress\n' > "$OP/.workflow-dev/context/WD-0001.md"
printf '### Implementation Status: Done\n' > "$OP/.workflow-dev/context/WD-0002.md"
printf '{"language":"es","notifications":[{"storyId":"WD-0001","device":"d"},{"storyId":"WD-0002","device":"d"},{"storyId":"WD-0003","device":"d"}]}\n' > "$OP/.workflow-dev/config.json"
out="$(op -- prune)"
[[ "$out" == $'pruned WD-0002\npruned WD-0003' ]] && ok "prune drops finished stories and stories with no context file" || no "prune (got: $out)"
jq -e '.language == "es" and .notifications == [{"storyId":"WD-0001","device":"d"}]' "$OP/.workflow-dev/config.json" >/dev/null && ok "prune keeps the in-progress entry and every other key" || no "prune result ($(cat "$OP/.workflow-dev/config.json"))"
[[ -z "$(op -- prune)" ]] && ok "prune with nothing stale prints nothing" || no "prune idempotent"
rm -rf "$OP" "$TMP/home" "$H"

# --- 12d. review fixes: saved default, malformed rows, hostile ids, fanfare when off ---
FP="$TMP/fixproj"
rm -rf "$FP" "$TMP/home"; mkdir -p "$FP/.workflow-dev/context"
( cd "$FP" && git init -q && git symbolic-ref HEAD refs/heads/feature/wd-0068-x )
fp() { RUN_CWD="$FP" run "$TMP/mac" Darwin "$@"; }
fake_helper
fp -- set-pref default >/dev/null
[[ "$(fp -- offer | head -1)" == $'suggest\tdefault' ]] && ok "offer: a saved 'default' is always still available (suggested)" || no "offer saved default (got: $(fp -- offer | head -1))"
printf '{"notifications":[{"storyId":"x|","device":"inj"},{"storyId":"WD-0068","device":"real"}]}' > "$FP/.workflow-dev/config.json"
[[ "$(fp -- active)" == $'WD-0068\treal' && "$(fp -- entries)" == $'WD-0068\treal' ]] && ok "an id that is not valid is skipped on read (no regex injection)" || no "hostile id (got: $(fp -- active))"
printf '{"notifications":[{"device":"no id"},"junk",{"storyId":"WD-0068","device":"real"}]}' > "$FP/.workflow-dev/config.json"
[[ "$(fp -- activate WD-0069 spk)" == saved ]] && ok "a malformed row does not block activate" || no "malformed row blocks activate"
[[ "$(fp -- deactivate WD-0068)" == removed && "$(fp -- entries)" == $'WD-0069\tspk' ]] && ok "a malformed row does not block deactivate" || no "malformed row blocks deactivate (got: $(fp -- entries))"
printf '{"notifications":[{"storyId":"WD-0068","device":"Bob \\\\ Speaker"}]}' > "$FP/.workflow-dev/config.json"
[[ "$(fp -- entries)" == $'WD-0068\tBob \\ Speaker' ]] && ok "a backslash in an output name comes back as written" || no "backslash device (got: $(fp -- entries))"
# the fanfare ends the story's alerts even when the sound is switched off
printf '### Implementation Status: Done\n' > "$FP/.workflow-dev/context/WD-0068.md"
printf '{"notifications":[{"storyId":"WD-0068","device":"default"}]}\n' > "$FP/.workflow-dev/config.json"
N=$((N + 1)); SIDF="f-$N"; reset
RUN_CWD="$FP" run "$TMP/mac" Darwin "CLAUDE_CODE_SESSION_ID=$SIDF" -- arm story >/dev/null
printf '%s' "$(payload "$SIDF" "$FP")" | RUN_CWD="$FP" run "$TMP/mac" Darwin WORKFLOW_DEV_ATTENTION=off -- --stop >/dev/null
sleep 0.2; [[ -z "$(fp -- entries)" ]] && ok "the story entry goes after the fanfare, WORKFLOW_DEV_ATTENTION=off in the environment or not" || no "entry kept (got: $(fp -- entries))"
rm -rf "$FP" "$TMP/home" "$H"

# --- 12e. adversarial-review fixes ---------------------------------------------
XP="$TMP/xproj"
rm -rf "$XP" "$TMP/home"; mkdir -p "$XP/.workflow-dev/context"
( cd "$XP" && git init -q && git symbolic-ref HEAD refs/heads/wd-0070-new )
xp() { RUN_CWD="$XP" run "$TMP/mac" Darwin "$@"; }
fake_helper
printf '{"notifications":[{"storyId":"WD-0068","device":"Spk"}]}\n' > "$XP/.workflow-dev/config.json"
[[ -z "$(xp -- active)" ]] && ok "a lone entry does not stand in for a branch that names another story (wd-0070 vs WD-0068)" || no "lone entry, other story (got: $(xp -- active))"
reset; xp -- play done >/dev/null; silent && ok "...and that story stays silent" || no "other story sounded"
( cd "$XP" && git symbolic-ref HEAD refs/heads/main )
[[ "$(xp -- active)" == $'WD-0068\tSpk' ]] && ok "a lone entry still serves a branch that names no story (main)" || no "lone entry on main (got: $(xp -- active))"
( cd "$XP" && git symbolic-ref HEAD refs/heads/fix-123 )
[[ "$(xp -- active)" == $'WD-0068\tSpk' ]] && ok "a lone entry serves a branch with another tracker's id (fix-123)" || no "lone entry, other tracker (got: $(xp -- active))"
printf '{"notifications":[{"storyId":"WD-0068","device":"A"},{"storyId":"WD-0070","device":"B"}]}\n' > "$XP/.workflow-dev/config.json"
( cd "$XP" && git symbolic-ref HEAD refs/heads/wd-0070-fix-wd-0068 )
[[ "$(xp -- active)" == $'WD-0070\tB' ]] && ok "a branch naming two stories belongs to the one it names first" || no "two ids in a branch (got: $(xp -- active))"
# play start right after activate, whatever the branch
( cd "$XP" && git symbolic-ref HEAD refs/heads/main )
printf '{"notifications":[{"storyId":"WD-0068","device":"A"},{"storyId":"WD-0070","device":"B"}]}\n' > "$XP/.workflow-dev/config.json"
reset; xp -- play start >/dev/null; silent && ok "play start with no output still goes through the gate" || no "play start gate"
reset; xp -- play start "MacBook Pro Speakers" >/dev/null
[[ "$(played)" == "helper MacBook Pro Speakers "*"/attention-start.wav" ]] && ok "play start <output> sounds right after activating, on that output, whatever the branch" || no "play start output (got: $(cat "$LOG"))"
reset; xp WORKFLOW_DEV_ATTENTION=off -- play start "MacBook Pro Speakers" >/dev/null
[[ "$(played)" == "helper MacBook Pro Speakers "*"/attention-start.wav" ]] && ok "play start <output> sounds with WORKFLOW_DEV_ATTENTION=off in the environment" || no "play start off (got: $(cat "$LOG"))"
reset; xp CI=true -- play start "MacBook Pro Speakers" >/dev/null; silent && ok "play start <output> still obeys CI" || no "play start CI"
run "$TMP/mac" Darwin -- play done X >/dev/null 2>&1; [[ $? -eq 2 ]] && ok "an output argument is only for play start (usage error)" || no "play done X usage"
# writes: symlink, mode, empty file, directory, concurrency
mkdir -p "$TMP/dot"; printf '{"x":1}\n' > "$TMP/dot/user.json"; chmod 644 "$TMP/dot/user.json"
mkdir -p "$TMP/home/.workflow-dev"; ln -s "$TMP/dot/user.json" "$TMP/home/.workflow-dev/config.json"
xp -- set-pref Spk >/dev/null
[[ -L "$TMP/home/.workflow-dev/config.json" ]] && jq -e '.x == 1 and .userPref.notifications.device == "Spk"' "$TMP/dot/user.json" >/dev/null && ok "a symlinked config is edited where it points, the link kept" || no "symlinked config"
[[ -n "$(find "$TMP/dot/user.json" -perm 644)" ]] && ok "a write keeps the file's mode" || no "mode kept"
rm -rf "$TMP/home" "$TMP/dot"
: > "$XP/.workflow-dev/config.json"
[[ "$(xp -- activate WD-1 Spk)" == saved && "$(xp -- entries)" == $'WD-1\tSpk' ]] && ok "an empty config file is treated like a missing one" || no "empty config"
rm -f "$XP/.workflow-dev/config.json"; mkdir "$XP/.workflow-dev/config.json"
[[ "$(xp -- activate WD-1 Spk)" == unavailable ]] && ok "a directory at the config path is unavailable, not saved" || no "dir at config path"
rmdir "$XP/.workflow-dev/config.json"
printf '{"keep":true}\n' > "$XP/.workflow-dev/config.json"
for i in 1 2 3 4 5 6 7 8 9 10; do xp -- activate "WD-$i" Spk >/dev/null & done; wait
[[ "$(xp -- entries | wc -l | tr -d ' ')" == 10 ]] && jq -e '.keep == true' "$XP/.workflow-dev/config.json" >/dev/null && ok "ten parallel activations lose none and keep other keys" || no "parallel writes (got: $(xp -- entries | wc -l))"
[[ ! -d "$XP/.workflow-dev/.config.json.lock" ]] && ok "the write lock is released" || no "lock left behind"
mkdir "$XP/.workflow-dev/.config.json.lock"; touch -t 200001010000 "$XP/.workflow-dev/.config.json.lock"
[[ "$(xp -- activate WD-99 Spk)" == saved ]] && ok "a stale lock (a dead writer's) is cleared" || no "stale lock"
# a short id inside a longer one, a read-only folder, a file at the lock path, two documents
printf '{"notifications":[]}\n' > "$XP/.workflow-dev/config.json"
xp -- activate PROJ-1 one >/dev/null; xp -- activate PROJ-12 twelve >/dev/null
( cd "$XP" && git symbolic-ref HEAD refs/heads/proj-12-follows-proj-1 )
[[ "$(xp -- active)" == $'PROJ-12\ttwelve' ]] && ok "PROJ-1 does not claim the start of PROJ-12 in a branch naming both" || no "prefix ids (got: $(xp -- active))"
( cd "$XP" && git symbolic-ref HEAD refs/heads/main )
chmod 555 "$XP/.workflow-dev"
start=$SECONDS; out="$(xp -- activate WD-5 Spk)"; took=$((SECONDS - start))
chmod 755 "$XP/.workflow-dev"
[[ "$out" == unavailable && $took -le 1 ]] && ok "a read-only folder fails at once, without waiting for the lock" || no "read-only folder (out=$out took=${took}s)"
touch "$XP/.workflow-dev/.config.json.lock"
start=$SECONDS; out="$(xp -- activate WD-5 Spk)"; took=$((SECONDS - start))
rm -f "$XP/.workflow-dev/.config.json.lock"
[[ "$out" == unavailable && $took -le 1 ]] && ok "a file at the lock's path fails at once" || no "file at lock path (out=$out took=${took}s)"
printf '{"a":1}{"b":2}' > "$XP/.workflow-dev/config.json"
[[ "$(xp -- activate WD-6 Spk)" == unavailable && "$(cat "$XP/.workflow-dev/config.json")" == '{"a":1}{"b":2}' ]] && ok "a config holding two documents is left untouched" || no "two documents"
# the fanfare sounds even when the branch no longer names the story by the Stop
printf '### Implementation Status: Done\n' > "$XP/.workflow-dev/context/WD-0068.md"
printf '{"notifications":[{"storyId":"WD-0068","device":"default"},{"storyId":"WD-0070","device":"default"}]}\n' > "$XP/.workflow-dev/config.json"
( cd "$XP" && git symbolic-ref HEAD refs/heads/wd-0068-x )
N=$((N + 1)); SIDX="x-$N"; reset
RUN_CWD="$XP" run "$TMP/mac" Darwin "CLAUDE_CODE_SESSION_ID=$SIDX" -- arm story >/dev/null
( cd "$XP" && git symbolic-ref HEAD refs/heads/main )
[[ -z "$(xp -- active)" ]] && ok "(setup) on main with two entries no story is active" || no "setup main"
printf '%s' "$(payload "$SIDX" "$XP")" | RUN_CWD="$XP" run "$TMP/mac" Darwin -- --stop >/dev/null
[[ "$(played)" == *"/attention-story.wav" ]] && ok "the fanfare sounds although the branch no longer names the story" || no "fanfare on main (got: $(cat "$LOG"))"
[[ "$(xp -- entries)" == $'WD-0070\tdefault' ]] && ok "...and removes that story's entry, not the other one's" || no "entry after fanfare on main (got: $(xp -- entries))"
# an armed turn on a story that declined alerts stays silent
printf '{"language":"es"}\n' > "$XP/.workflow-dev/config.json"
N=$((N + 1)); SIDX="x-$N"; reset
RUN_CWD="$XP" run "$TMP/mac" Darwin "CLAUDE_CODE_SESSION_ID=$SIDX" -- arm story >/dev/null
printf '%s' "$(payload "$SIDX" "$XP")" | RUN_CWD="$XP" run "$TMP/mac" Darwin -- --stop >/dev/null
silent && ok "a story with no entry gets no fanfare (it declined the alerts)" || no "fanfare without entry"
# prune finds the context file whatever its case
printf '### Implementation Status: In Progress\n' > "$XP/.workflow-dev/context/WD-0068.md"
printf '{"notifications":[{"storyId":"wd-0068","device":"Spk"}]}\n' > "$XP/.workflow-dev/config.json"
[[ -z "$(xp -- prune)" ]] && ok "prune keeps an entry whose id differs in case from its context file" || no "prune case"
rm -rf "$XP" "$TMP/home" "$H"

# --- 12f. the perl engine: the same storage with perl and no jq ----------------
if command -v perl >/dev/null 2>&1 && perl -MJSON::PP -e1 >/dev/null 2>&1; then
  mkdir -p "$TMP/perlbin"; ln -sf "$(command -v perl)" "$TMP/perlbin/perl"
  RP="$TMP/perlproj"
  rm -rf "$RP" "$TMP/home"; mkdir -p "$RP/.workflow-dev/context"
  ( cd "$RP" && git init -q && git symbolic-ref HEAD refs/heads/wd-0068-x )
  rp() { EXTRA_PATH=":$TMP/perlbin" RUN_CWD="$RP" run "$TMP/mac" Darwin "$@"; }
  [[ "$(rp -- pref)" == unset ]] && ok "[perl] no saved choice reads as unset" || no "[perl] fresh pref"
  [[ "$(rp -- set-pref "MacBook Pro Speakers")" == saved && "$(rp -- pref)" == "MacBook Pro Speakers" ]] && ok "[perl] set-pref is saved and read back" || no "[perl] set-pref"
  printf '{"userPref": {"other": 1}, "keep": "me", "big": 12345678901234567890}\n' > "$TMP/home/.workflow-dev/config.json"
  rp -- set-pref "Café ☕ Speaker" >/dev/null
  [[ "$(rp -- pref)" == "Café ☕ Speaker" ]] && ok "[perl] a UTF-8 output name round-trips" || no "[perl] utf8 (got: $(rp -- pref))"
  jq -e '.keep == "me" and .userPref.other == 1 and .big == 12345678901234567890' "$TMP/home/.workflow-dev/config.json" >/dev/null 2>&1 \
    && ok "[perl] set-pref keeps every other key (a big integer too)" \
    || { grep -q '"keep" *: *"me"' "$TMP/home/.workflow-dev/config.json" && grep -q 12345678901234567890 "$TMP/home/.workflow-dev/config.json" && ok "[perl] set-pref keeps every other key (a big integer too)" || no "[perl] keeps keys ($(cat "$TMP/home/.workflow-dev/config.json"))"; }
  printf 'not json' > "$TMP/home/.workflow-dev/config.json"
  [[ "$(rp -- set-pref x)" == unavailable && "$(cat "$TMP/home/.workflow-dev/config.json")" == "not json" ]] && ok "[perl] an unreadable config is left untouched" || no "[perl] corrupt user config"
  printf '[1,2]' > "$TMP/home/.workflow-dev/config.json"
  [[ "$(rp -- set-pref x)" == unavailable && "$(cat "$TMP/home/.workflow-dev/config.json")" == "[1,2]" ]] && ok "[perl] a root that is not an object is left untouched" || no "[perl] array root"
  rm -rf "$TMP/home"
  printf '{"gitignored": true, "language": "es"}\n' > "$RP/.workflow-dev/config.json"
  [[ "$(rp -- activate WD-0068 Spk)" == saved ]] && ok "[perl] activate saves an entry" || no "[perl] activate"
  [[ "$(rp -- active)" == $'WD-0068\tSpk' ]] && ok "[perl] the only entry is the active one" || no "[perl] active (got: $(rp -- active))"
  rp -- activate wd-0068 Headset >/dev/null
  [[ "$(rp -- entries | wc -l | tr -d ' ')" == 1 && "$(rp -- entries)" == $'wd-0068\tHeadset' ]] && ok "[perl] activating the same story again replaces its entry (any case)" || no "[perl] replace"
  grep -q '"gitignored" *: *true' "$RP/.workflow-dev/config.json" && grep -q '"language" *: *"es"' "$RP/.workflow-dev/config.json" && ok "[perl] activate keeps every other key" || no "[perl] activate keeps keys"
  printf '{"notifications":[{"device":"no id"},"junk",{"storyId":"WD-0068","device":"real"}]}' > "$RP/.workflow-dev/config.json"
  [[ "$(rp -- activate WD-0069 spk)" == saved && "$(rp -- deactivate WD-0068)" == removed && "$(rp -- entries)" == $'WD-0069\tspk' ]] && ok "[perl] a malformed row blocks neither activate nor deactivate" || no "[perl] malformed rows (got: $(rp -- entries))"
  printf '{"a":1}{"b":2}' > "$RP/.workflow-dev/config.json"
  [[ "$(rp -- activate WD-6 Spk)" == unavailable && "$(cat "$RP/.workflow-dev/config.json")" == '{"a":1}{"b":2}' ]] && ok "[perl] a config holding two documents is left untouched" || no "[perl] two documents"
  printf '{"notifications": "oops"}' > "$RP/.workflow-dev/config.json"
  [[ "$(rp -- activate WD-1 Dev)" == unavailable && "$(cat "$RP/.workflow-dev/config.json")" == '{"notifications": "oops"}' ]] && ok "[perl] a notifications key that is not a list is left untouched" || no "[perl] bad notifications"
  printf '{"notifications":[{"storyId":"x|","device":"inj"},{"storyId":"WD-0068","device":"real"}]}' > "$RP/.workflow-dev/config.json"
  [[ "$(rp -- active)" == $'WD-0068\treal' ]] && ok "[perl] an id that is not valid is skipped on read" || no "[perl] hostile id"
  printf '{"notifications":[{"storyId":"WD-0068","device":"Bob \\\\ Speaker"}]}' > "$RP/.workflow-dev/config.json"
  [[ "$(rp -- entries)" == $'WD-0068\tBob \\ Speaker' ]] && ok "[perl] a backslash in an output name comes back as written" || no "[perl] backslash"
  rm -f "$RP/.workflow-dev/config.json"
  [[ "$(rp -- deactivate WD-1)" == removed ]] && ok "[perl] deactivating with no config is harmless" || no "[perl] deactivate none"
  rp -- activate WD-1 Spk >/dev/null
  [[ "$(rp -- deactivate WD-1)" == removed && -z "$(rp -- entries)" ]] && ok "[perl] deactivate drops the entry" || no "[perl] deactivate"
  rm -rf "$RP" "$TMP/home"
else
  printf '  skip perl engine (no perl with JSON::PP on this machine)\n'
fi

# --- 12g. second adversarial round -------------------------------------------
QP="$TMP/qproj"
mkdir -p "$TMP/perlbin"; command -v perl >/dev/null 2>&1 && ln -sf "$(command -v perl)" "$TMP/perlbin/perl"
rm -rf "$QP" "$TMP/home"; mkdir -p "$QP/.workflow-dev/context"
( cd "$QP" && git init -q && git symbolic-ref HEAD refs/heads/wd-0068-x )
qj() { RUN_CWD="$QP" run "$TMP/mac" Darwin "$@"; }                       # jq
qpl() { EXTRA_PATH=":$TMP/perlbin" RUN_CWD="$QP" run "$TMP/mac" Darwin "$@"; }  # perl, no jq
fake_helper
# B1: an arm for a story that no longer has an entry is silent and deletes nothing
printf '{"notifications":[{"storyId":"WD-0068","device":"A"},{"storyId":"WD-0070","device":"B"}]}\n' > "$QP/.workflow-dev/config.json"
printf '### Implementation Status: Done\n' > "$QP/.workflow-dev/context/WD-0070.md"
N=$((N + 1)); SIDQ="q-$N"; reset
RUN_CWD="$QP" run "$TMP/mac" Darwin "CLAUDE_CODE_SESSION_ID=$SIDQ" -- arm story >/dev/null
qj -- deactivate WD-0068 >/dev/null
( cd "$QP" && git symbolic-ref HEAD refs/heads/main )
printf '%s' "$(payload "$SIDQ" "$QP")" | RUN_CWD="$QP" run "$TMP/mac" Darwin -- --stop >/dev/null
silent && ok "an arm for a story with no entry is silent (no fallback to another story)" || no "B1 sounded (got: $(cat "$LOG"))"
[[ "$(qj -- entries)" == $'WD-0070\tB' ]] && ok "...and deletes no other story's entry" || no "B1 deleted (got: $(qj -- entries))"
( cd "$QP" && git symbolic-ref HEAD refs/heads/wd-0068-x )
# C1/C2: only a real status heading counts
for case in 'fence|### Implementation Status: In Progress\n```\n### Implementation Status: Done\n```\n|keep' \
            'suffix|### Implementation Status: Done-ish\n|keep' \
            'prose|The story is ### Implementation Status: Done soon\n|keep' \
            'plain|### Implementation Status: Done\n|go' \
            'crlf|### Implementation Status: Done\r\n|go' \
            'bom|\xef\xbb\xbf### Implementation Status: Done\n|go' \
            'trailing|### Implementation Status: Done   \n|go'; do
  name="${case%%|*}"; rest="${case#*|}"; body="${rest%|*}"; want="${rest##*|}"
  printf "$body" > "$QP/.workflow-dev/context/WD-0068.md"
  printf '{"notifications":[{"storyId":"WD-0068","device":"default"}]}\n' > "$QP/.workflow-dev/config.json"
  N=$((N + 1)); SIDQ="q-$N"; reset
  RUN_CWD="$QP" run "$TMP/mac" Darwin "CLAUDE_CODE_SESSION_ID=$SIDQ" -- arm story >/dev/null
  printf '%s' "$(payload "$SIDQ" "$QP")" | RUN_CWD="$QP" run "$TMP/mac" Darwin -- --stop >/dev/null
  played >/dev/null; left="$(qj -- entries | wc -l | tr -d ' ')"
  if [[ "$want" == keep ]]; then [[ "$left" == 1 ]] && ok "a status of '$name' does not end the story's alerts" || no "status '$name' ended the alerts"
  else [[ "$left" == 0 ]] && ok "a status of '$name' ends the story's alerts" || no "status '$name' kept the alerts"; fi
done
# D1: the same story written another way is still the lone entry's
printf '{"notifications":[{"storyId":"WD-0068","device":"A"}]}\n' > "$QP/.workflow-dev/config.json"
for br in wd_0068-alerts wd0068 WD.0068 feature/wd-68 wd-0068b; do
  ( cd "$QP" && git symbolic-ref HEAD "refs/heads/$br" )
  [[ "$(qj -- active)" == $'WD-0068\tA' ]] && ok "branch '$br' is the lone entry's own story" || no "branch '$br' (got: $(qj -- active))"
done
for br in wd_0070 wd.0070 wd0070 wd-0070 wd-0068-and-wd-0070; do
  ( cd "$QP" && git symbolic-ref HEAD "refs/heads/$br" )
  [[ "$(qj -- active)" == $'WD-0068\tA' && "$br" == wd-0068-and-wd-0070 || -z "$(qj -- active)" && "$br" != wd-0068-and-wd-0070 ]] && ok "branch '$br' is judged against the lone entry" || no "branch '$br' (got: $(qj -- active))"
done
( cd "$QP" && git symbolic-ref HEAD refs/heads/wd-0068-x )
# A1-A3, A6: the two engines read and write alike
if command -v perl >/dev/null 2>&1 && perl -MJSON::PP -e1 >/dev/null 2>&1 && [[ -x "$TMP/jq/jq" ]]; then
  agree() { # agree <name> <config text> <command...>: both engines, same answer, same file
    local name="$1" cfg="$2" a b fa fb; shift 2
    printf '%s' "$cfg" > "$QP/.workflow-dev/config.json"; a="$(qj -- "$@")"; fa="$(jq -cS . "$QP/.workflow-dev/config.json" 2>/dev/null)"
    printf '%s' "$cfg" > "$QP/.workflow-dev/config.json"; b="$(qpl -- "$@")"; fb="$(jq -cS . "$QP/.workflow-dev/config.json" 2>/dev/null)"
    [[ "$a" == "$b" && "$fa" == "$fb" ]] && ok "jq and perl agree: $name" || no "engines differ: $name (jq='$a' perl='$b' / jq-file='$fa' perl-file='$fb')"
  }
  agree "numbers are not ids or devices" '{"notifications":[{"storyId":68,"device":"a"},{"storyId":"WD-2","device":5}]}' entries
  agree "numbers are not a saved output" '{"userPref":{"notifications":{"device":5}}}' pref
  agree "two glued documents read as nothing" '{"notifications":[{"storyId":"WD-1","device":"a"}]}{"notifications":[{"storyId":"WD-2","device":"b"}]}' entries
  agree "notifications false: activate" '{"notifications":false}' activate WD-1 Spk
  agree "notifications null: activate" '{"notifications":null}' activate WD-1 Spk
  agree "notifications null: deactivate" '{"notifications":null}' deactivate WD-1
  agree "notifications false: deactivate" '{"notifications":false}' deactivate WD-1
  agree "notifications an object: activate" '{"notifications":{"x":{"storyId":"WD-9","device":"d"}}}' activate WD-1 Spk
  agree "notifications an object: deactivate" '{"notifications":{"x":{"storyId":"WD-9","device":"d"}}}' deactivate WD-9
  agree "non-ASCII ids fold alike" '{"notifications":[{"storyId":"WD-K","device":"d"}]}' deactivate wd-k
  agree "a BOM at the start of the config" $'\xef\xbb\xbf{"notifications":[{"storyId":"WD-1","device":"d"}]}' entries
fi
rm -rf "$QP" "$TMP/home" "$H"

# --- 13. the real macOS helper compiles and behaves (no sound played) ---------
if [[ "$(uname -s)" == Darwin ]] && command -v swiftc >/dev/null 2>&1; then
  if swiftc -O -o "$TMP/attention-play" "$HERE/attention-play.swift" >/dev/null 2>&1; then
    ok "attention-play.swift compiles"
    "$TMP/attention-play" --list >/dev/null; rc=$?
    [[ $rc -eq 0 ]] && ok "the helper lists outputs (exit 0)" || no "helper --list (rc=$rc)"
    "$TMP/attention-play" "no such output $$" "$ASSETS/attention-need.wav"; rc=$?
    [[ $rc -eq 1 ]] && ok "the helper exits 1 for an output that is not connected" || no "helper unknown output (rc=$rc)"
    "$TMP/attention-play" 2>/dev/null; rc=$?
    [[ $rc -eq 2 ]] && ok "the helper exits 2 on bad usage" || no "helper usage (rc=$rc)"
  else
    no "attention-play.swift compiles"
  fi
else
  printf '  skip real helper (not macOS, or no swiftc)\n'
fi

out="$(run "$TMP/mac" Darwin -- arm done extra 2>/dev/null)"; rc=$?
[[ $rc -eq 2 ]] && ok "three arguments are a usage error" || no "three arguments (rc=$rc)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
