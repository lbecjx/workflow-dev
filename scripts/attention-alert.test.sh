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
for tool in dirname tr sleep cat mv rm mkdir mktemp chmod find date basename sed grep head awk ls seq wc; do
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

# Every run starts from a clean, attended, non-CI environment, whatever the
# environment running the tests looks like (CI sets CI=true).
run() { # run <player dir> <os> [VAR=value ...] -- args
  local players="$1" os="$2"
  shift 2
  local envs=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do envs+=("$1"); shift; done
  shift
  env -i HOME="$TMP/home" PATH="$players:$TMP/os:$SYS${EXTRA_PATH:-}" FAKE_UNAME="$os" TMPDIR="$TMP/t" \
    _WD_ATTENTION_TTY="$TTY" ${envs[@]+"${envs[@]}"} /bin/bash "$SCRIPT" "$@"
}

reset() { : > "$LOG"; rm -f "$TTY"; }
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

# --- 2. off, CI and non-interactive stay silent ---------------------------------
for v in off OFF Off 0 false FALSE no No; do
  expect_silent "WORKFLOW_DEV_ATTENTION=$v is off" "$TMP/mac" Darwin "WORKFLOW_DEV_ATTENTION=$v" -- play
done
expect_play "WORKFLOW_DEV_ATTENTION=on plays" afplay "$TMP/mac" Darwin WORKFLOW_DEV_ATTENTION=on -- play
expect_silent "off also silences the bell" "$TMP/none" Linux WORKFLOW_DEV_ATTENTION=off -- play
expect_silent "CI=true is silent" "$TMP/mac" Darwin CI=true -- play
expect_silent "CI=1 is silent" "$TMP/mac" Darwin CI=1 -- play
expect_play "CI=false plays" afplay "$TMP/mac" Darwin CI=false -- play
expect_play "CI=0 plays" afplay "$TMP/mac" Darwin CI=0 -- play
expect_silent "a non-interactive session (ATTENDED=0) is silent" "$TMP/mac" Darwin CLAUDE_CODE_SESSION_ATTENDED=0 -- play
expect_play "an interactive session (ATTENDED=1) plays" afplay "$TMP/mac" Darwin CLAUDE_CODE_SESSION_ATTENDED=1 -- play

# --- 3. a custom sound, only when it is a readable regular file --------------
mkdir -p "$TMP/snd dir"
printf 'x' > "$TMP/snd dir/my sound.wav"
printf 'x' > "$TMP/-dash.wav"
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
reset; (cd "$TMP" && env -i HOME="$TMP/home" PATH="$TMP/mac:$TMP/os:$SYS" FAKE_UNAME=Darwin WORKFLOW_DEV_ATTENTION_SOUND=-dash.wav /bin/bash "$SCRIPT" play >/dev/null)
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
mkdir -p "$TMP/proj/.workflow-dev/context" "$TMP/plain" "$TMP/my proj/.workflow-dev/context" "$TMP/q\"x/.workflow-dev/context"
PROJ="$TMP/proj"
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
  check "$tag off: an armed Stop is silent" 0
  [[ ! -e "$STORE/armed-$SID" ]] && ok "$tag off: the arm is still consumed" || no "$tag off: the arm is still consumed"
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
hook_suite "[no jq]"
if JQ="$(command -v jq)"; then
  mkdir -p "$TMP/jq" "$TMP/t"
  ln -s "$JQ" "$TMP/jq/jq"
  EXTRA_PATH=":$TMP/jq" hook_suite "[jq]"
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
for kind in need away permission commit pr done passed fail story; do
  grep -q "| \`$kind\` |" "$DOC" && ok "the reference documents kind $kind" || no "the reference documents kind $kind"
done
for pair in "skills/plan/SKILL.md:need" "skills/validate/SKILL.md:passed" "skills/validate/SKILL.md:fail" "skills/implement/SKILL.md:done" "skills/manual-qa/SKILL.md:done" "skills/summarize-changes/SKILL.md:commit" "skills/summarize-changes/SKILL.md:pr" "skills/save/SKILL.md:story" "references/autonomous-mode.md:story"; do
  grep -q "kind.*\`${pair##*:}\`\|\`${pair##*:}\`" "$ROOT/${pair%%:*}" && ok "${pair%%:*} arms ${pair##*:}" || no "${pair%%:*} arms ${pair##*:}"
done
grep -q 'First story on a machine' "$ROOT/skills/init/SKILL.md" && grep -q 'attention-alert.sh device' "$ROOT/skills/init/SKILL.md" \
  && ok "init asks where and how loud on a machine's first story" || no "init first-story question"
for want in 'attention-alert.sh suggest' 'set-device' 'set-volume' 'Low (25%)' 'Medium (50%)' 'High (75%)' 'Full (100%)' 'Default output'; do
  grep -qF "$want" "$DOC" && ok "the reference carries '$want'" || no "the reference carries '$want'"
done
if grep -rn 'attention-alert.sh play' "$ROOT/skills" "$ROOT/references" >/dev/null; then no "no skill tells the agent to play directly"; else ok "no skill tells the agent to play directly"; fi

# --- 8. every kind has a short bundled WAV -----------------------------------
# Byte rate (offset 28) and data size (offset 40) of the canonical 44-byte header.
le32() { od -An -tu4 -j "$2" -N 4 "$1" | tr -d ' '; }
for kind in need away permission commit pr done passed fail saved story; do
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

# --- 9. each event plays its own sound ---------------------------------------
reset; run "$TMP/mac" Darwin -- play done >/dev/null
[[ "$(played)" == *"/assets/attention-done.wav" ]] && ok "play done plays the done sound" || no "play done (got: $(cat "$LOG"))"
reset; run "$TMP/mac" Darwin -- play bogus >/dev/null
[[ "$(played)" == *"/assets/attention-need.wav" ]] && ok "an unknown kind falls back to need" || no "unknown kind (got: $(cat "$LOG"))"
reset; run "$TMP/mac" Darwin "WORKFLOW_DEV_ATTENTION_SOUND=$TMP/snd dir/my sound.wav" -- play story >/dev/null
[[ "$(played)" == "afplay $TMP/snd dir/my sound.wav" ]] && ok "a custom sound replaces every kind" || no "custom sound for story (got: $(cat "$LOG"))"
mkdir -p "$TMP/t" "$PROJ"
for pair in "need:need" "commit:commit" "pr:pr" "done:done" "passed:passed" "fail:fail" "story:story" ":need" "nonsense:need"; do
  armk="${pair%%:*}"; want="${pair##*:}"
  new_sid; reset
  run "$TMP/mac" Darwin "CLAUDE_CODE_SESSION_ID=$SID" -- arm ${armk:+"$armk"}
  hook --stop "$(payload "$SID" "$PROJ")"
  [[ "$(played)" == *"/assets/attention-$want.wav" ]] && ok "arm '${armk}' then Stop plays $want" || no "arm '${armk}' then Stop (got: $(cat "$LOG"))"
done
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
reset; env -i HOME="$TMP/home" PATH="$TMP/mac:$TMP/os:$SYS" FAKE_UNAME=Darwin /bin/bash "$TMP/plug/scripts/attention-alert.sh" play story >/dev/null
[[ "$(played)" == *"/plug/assets/attention-need.wav" ]] && ok "a kind whose file is missing plays need" || no "missing kind file (got: $(cat "$LOG"))"
# --- 10. where the sounds play: one choice per machine ------------------------
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
out="$(run "$TMP/mac" Darwin -- device)"
[[ "$out" == unset ]] && ok "a fresh machine has no device choice (unset)" || no "fresh device (got: $out)"
out="$(run "$TMP/mac" Darwin -- set-device default)"
[[ "$out" == saved && "$(run "$TMP/mac" Darwin -- device)" == default ]] && ok "set-device default is saved and read back" || no "set-device default (got: $out)"
rm -rf "$H"
out="$(run "$TMP/mac" Darwin -- set-device "MacBook Pro Speakers")"
[[ "$out" == saved-default-output ]] && ok "a named output without swiftc says it will use the default output" || no "no-swiftc set-device (got: $out)"
[[ "$(run "$TMP/mac" Darwin -- device)" == "MacBook Pro Speakers" ]] && ok "the named output is still saved" || no "named output saved"
# `find -perm`, not `stat`: BSD `stat -f` and GNU `stat -f` mean different things.
[[ -n "$(find "$H/.workflow-dev" -maxdepth 0 -perm 700)" ]] && ok "the machine folder is private (700)" || no "machine folder mode"
reset; run "$TMP/mac" Darwin -- play done >/dev/null
[[ "$(played)" == "afplay "*"/assets/attention-done.wav" ]] && ok "with no helper the default output plays" || no "no helper fallback (got: $(cat "$LOG"))"
fake_helper
out="$(run "$TMP/mac" Darwin -- set-device "MacBook Pro Speakers")"
[[ "$out" == saved ]] && ok "with the helper built, a named output is saved" || no "set-device with helper (got: $out)"
reset; run "$TMP/mac" Darwin -- play done >/dev/null
[[ "$(played)" == "helper MacBook Pro Speakers "*"/assets/attention-done.wav" ]] && ok "the chosen output plays through the helper" || no "helper play (got: $(cat "$LOG"))"
[[ "$(run "$TMP/mac" Darwin -- suggest)" == "MacBook Pro Speakers" ]] && ok "suggest names the built-in output" || no "suggest (got: $(run "$TMP/mac" Darwin -- suggest))"
[[ "$(run "$TMP/mac" Darwin -- devices | wc -l | tr -d ' ')" == 2 ]] && ok "devices lists every output" || no "devices"
run "$TMP/mac" Darwin -- set-device Gone >/dev/null
reset; run "$TMP/mac" Darwin -- play done >/dev/null
[[ "$(played)" == "afplay "*"/assets/attention-done.wav" ]] && ok "an unplugged output falls back to the default output" || no "unplugged fallback (got: $(cat "$LOG"))"
reset; run "$TMP/mac" Darwin "WORKFLOW_DEV_ATTENTION_DEVICE=default" -- play done >/dev/null
[[ "$(played)" == "afplay "* ]] && ok "WORKFLOW_DEV_ATTENTION_DEVICE overrides the machine file" || no "env override (got: $(cat "$LOG"))"
run "$TMP/mac" Darwin -- set-device 'Bob "Big" Speaker\x' >/dev/null
[[ "$(run "$TMP/mac" Darwin -- device)" == 'Bob "Big" Speaker\x' ]] && ok "a name with quotes and a backslash round-trips" || no "quoted name (got: $(run "$TMP/mac" Darwin -- device))"
run "$TMP/mac" Darwin -- set-volume 75 >/dev/null
run "$TMP/mac" Darwin -- set-device "Speakers" >/dev/null
for bad in "$(printf 'two\nlines')" "$(printf 'a\tb')"; do
  out="$(run "$TMP/mac" Darwin -- set-device "$bad")"
  [[ "$out" == invalid && "$(run "$TMP/mac" Darwin -- device)" == Speakers && "$(run "$TMP/mac" Darwin -- volume)" == 75 ]] \
    && ok "a name with a control character is refused, the file intact" || no "control char name (out=$out)"
done
out="$(run "$TMP/mac" Darwin -- set-device 2>&1)"; rc=$?
[[ $rc -eq 2 ]] && ok "set-device with no name is a usage error" || no "set-device no arg (rc=$rc)"
out="$(run "$TMP/mac" Darwin -- set-device '' 2>&1)"; rc=$?
[[ $rc -eq 2 ]] && ok "set-device with an empty name is a usage error" || no "set-device empty (rc=$rc)"
# Linux: the players take the output name directly.
fake "$TMP/pulsedev" paplay 'for a in "$@"; do [[ "$a" == --device=Gone ]] && exit 1; done'
fake "$TMP/alsadev" aplay 'for a in "$@"; do [[ "$a" == Gone ]] && exit 1; done'
run "$TMP/pulsedev" Linux -- set-device alsa_output.pci-0000.analog-stereo >/dev/null
reset; run "$TMP/pulsedev" Linux -- play done >/dev/null
[[ "$(played)" == "paplay --device=alsa_output.pci-0000.analog-stereo "*"/attention-done.wav" ]] && ok "Linux paplay gets --device" || no "paplay device (got: $(cat "$LOG"))"
reset; run "$TMP/alsadev" Linux -- play done >/dev/null
[[ "$(played)" == "aplay -D alsa_output.pci-0000.analog-stereo "*"/attention-done.wav" ]] && ok "Linux aplay gets -D" || no "aplay device (got: $(cat "$LOG"))"
run "$TMP/pulsedev" Linux -- set-device Gone >/dev/null
reset; run "$TMP/pulsedev" Linux -- play done >/dev/null; sleep 0.3
[[ "$(tail -1 "$LOG")" == "paplay "*"/attention-done.wav" && "$(tail -1 "$LOG")" != *--device* ]] && ok "Linux falls back to the default output when the device fails" || no "paplay fallback (got: $(cat "$LOG"))"
rm -rf "$H"

# --- 11. volume ----------------------------------------------------------------
reset; run "$TMP/mac" Darwin WORKFLOW_DEV_ATTENTION_VOLUME=40 -- play done >/dev/null
[[ "$(played)" == "afplay -v 0.40 "*"/attention-done.wav" ]] && ok "volume 40 gives afplay -v 0.40" || no "afplay volume (got: $(cat "$LOG"))"
reset; run "$TMP/mac" Darwin WORKFLOW_DEV_ATTENTION_VOLUME=5 -- play done >/dev/null
[[ "$(played)" == "afplay -v 0.05 "* ]] && ok "volume 5 gives afplay -v 0.05" || no "afplay volume 5 (got: $(cat "$LOG"))"
for bad in 100 "" 101 -3 abc 4.5 0050x; do
  reset; run "$TMP/mac" Darwin "WORKFLOW_DEV_ATTENTION_VOLUME=$bad" -- play done >/dev/null
  [[ "$(played)" == "afplay /"* ]] && ok "volume '$bad' plays at the output's own level" || no "volume '$bad' (got: $(cat "$LOG"))"
done
reset; run "$TMP/mac" Darwin WORKFLOW_DEV_ATTENTION_VOLUME=0 -- play done >/dev/null
[[ "$(played)" == "afplay -v 0.00 "* ]] && ok "volume 0 is honoured (muted on purpose)" || no "volume 0 (got: $(cat "$LOG"))"
reset; run "$TMP/pulse" Linux WORKFLOW_DEV_ATTENTION_VOLUME=50 -- play done >/dev/null
[[ "$(played)" == "paplay --volume=32768 "* ]] && ok "volume 50 gives paplay --volume=32768" || no "paplay volume (got: $(cat "$LOG"))"
rm -rf "$H"
[[ "$(run "$TMP/mac" Darwin -- volume)" == unset ]] && ok "a fresh machine has no volume (unset)" || no "fresh volume"
for v in 25 50 75 100; do
  [[ "$(run "$TMP/mac" Darwin -- set-volume "$v")" == saved && "$(run "$TMP/mac" Darwin -- volume)" == "$v" ]] && ok "set-volume $v is saved and read back" || no "set-volume $v"
done
run "$TMP/mac" Darwin -- set-volume 25 >/dev/null
reset; run "$TMP/mac" Darwin -- play done >/dev/null
[[ "$(played)" == "afplay -v 0.25 "* ]] && ok "the saved volume is used" || no "saved volume used (got: $(cat "$LOG"))"
reset; run "$TMP/mac" Darwin WORKFLOW_DEV_ATTENTION_VOLUME=75 -- play done >/dev/null
[[ "$(played)" == "afplay -v 0.75 "* ]] && ok "WORKFLOW_DEV_ATTENTION_VOLUME overrides the saved volume" || no "volume env override (got: $(cat "$LOG"))"
for bad in 101 abc -1 ""; do
  out="$(run "$TMP/mac" Darwin -- set-volume "$bad" 2>/dev/null)"; rc=$?
  if [[ "$bad" == "" ]]; then [[ $rc -eq 2 ]]; else [[ "$out" == invalid && "$(run "$TMP/mac" Darwin -- volume)" == 25 ]]; fi \
    && ok "set-volume '$bad' is refused and changes nothing" || no "set-volume '$bad' (rc=$rc out=$out)"
done
run "$TMP/mac" Darwin -- set-device default >/dev/null
[[ "$(run "$TMP/mac" Darwin -- volume)" == 25 ]] && ok "set-device keeps the saved volume" || no "set-device keeps volume"
run "$TMP/mac" Darwin -- set-volume 50 >/dev/null
[[ "$(run "$TMP/mac" Darwin -- device)" == default ]] && ok "set-volume keeps the saved device" || no "set-volume keeps device"
rm -rf "$H"
fake_helper
run "$TMP/mac" Darwin -- set-device "MacBook Pro Speakers" >/dev/null
reset; run "$TMP/mac" Darwin WORKFLOW_DEV_ATTENTION_VOLUME=30 -- play done >/dev/null
[[ "$(played)" == "helper MacBook Pro Speakers "*"/attention-done.wav 0.30" ]] && ok "the helper gets the gain" || no "helper volume (got: $(cat "$LOG"))"
rm -rf "$H"

# --- 12. the real macOS helper compiles and behaves (no sound played) ---------
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
