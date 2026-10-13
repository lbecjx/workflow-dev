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
#   - the bundled sound is a short WAV;
#   - one yes/no per machine (~/.workflow-dev/config.json) decides whether
#     anything sounds, every sound plays on the default output, and no write
#     ever stores an output.
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

# The alerts sound only when this machine said yes, so every run happens in a
# workflow-dev project with a yes in the sandbox HOME, and finds jq. The no-jq
# hook variant gives the answer through the seam instead.
PROJ="$TMP/proj"
mkdir -p "$PROJ/.workflow-dev/context" "$TMP/jq"
UCFG="$TMP/home/.workflow-dev/config.json"
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

seed_answer() { # seed_answer on|off|<raw config text>
  mkdir -p "${UCFG%/*}"
  case "$1" in
    on) printf '{"notifications": true}\n' ;;
    off) printf '{"notifications": false}\n' ;;
    *) printf '%s' "$1" ;;
  esac > "$UCFG"
}
reset() { : > "$LOG"; rm -f "$TTY"; seed_answer on; }
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

# --- 3. WORKFLOW_DEV_ATTENTION_SOUND is not read ----------------------------------
mkdir -p "$TMP/snd dir"
printf 'x' > "$TMP/snd dir/my sound.wav"
reset; run "$TMP/mac" Darwin "WORKFLOW_DEV_ATTENTION_SOUND=$TMP/snd dir/my sound.wav" -- play >/dev/null
[[ "$(played)" == *"/assets/attention-need.wav" ]] && ok "a custom sound in the environment is ignored: the bundled one plays" || no "custom sound ignored (got: $(cat "$LOG"))"

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
EXTRA_PATH="" GATE_ENV="_WD_ATTENTION_ON=on" hook_suite "[no jq]"
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
for gone in 'First story on this machine' 'attention-alert\.sh device($|[^s])' 'set-volume' 'set-device' 'Alerts for this story' 'set-pref' 'attention-alert\.sh activate' 'attention-alert\.sh offer' 'attention-alert\.sh prune' 'Choose source' 'attention-play' 'storyId' 'Which source'; do
  grep -qE "$gone" "$ROOT/skills/init/SKILL.md" "$DOC" "$ROOT/README.md" "$ROOT/hooks/README.md" "$ROOT/references/autonomous-mode.md" && no "docs no longer mention '$gone'" || ok "docs no longer mention '$gone'"
done
for want in 'Alerts on this machine' 'attention-alert.sh get' 'attention-alert.sh set on' 'attention-alert.sh set off' 'attention-alert.sh play start' 'Turn the notifications on?' 'Yes (Recommended)' 'Never' 'Some processes take' 'speakers' '`unset`' 'Agent (inferred)'; do
  grep -qF -- "$want" "$DOC" && ok "the reference carries '$want'" || no "the reference carries '$want'"
done
grep -qF 'Alerts on this machine' "$ROOT/skills/init/SKILL.md" && ok "init asks the alerts question" || no "init alerts question"
grep -qF 'Alerts on this machine' "$ROOT/references/autonomous-mode.md" && ok "the autonomous checkpoint carries the alerts question" || no "autonomous alerts question"
# The alerts question waits for the answer, so an autonomous run says first it has not started.
grep -qF '## Before the run starts' "$ROOT/references/autonomous-mode.md" && ok "autonomous mode says the run has not started before its setup questions" || no "autonomous 'Before the run starts' section"
grep -qF 'Before the run starts' "$DOC" && ok "the alerts reference points to 'Before the run starts'" || no "alerts reference points to 'Before the run starts'"
grep -qF 'never blocks' "$ROOT/references/autonomous-mode.md" "$DOC" && no "docs no longer claim the alerts question never blocks" || ok "docs no longer claim the alerts question never blocks"
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
[[ "$(played)" == *"/assets/attention-story.wav" ]] && ok "a custom sound does not replace any kind" || no "custom sound for story (got: $(cat "$LOG"))"
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
# --- 10. every sound plays on the default output -----------------------------
H="$TMP/home"
for kind in need away permission commit pr done passed fail saved story start; do
  reset; run "$TMP/mac" Darwin -- play "$kind" >/dev/null
  [[ "$(played)" == "afplay $(cd -P "$HERE/.." && pwd -P)/assets/attention-$kind.wav" ]] && ok "'$kind' plays on the default output (afplay, no output named)" || no "'$kind' default output (got: $(cat "$LOG"))"
done
reset; run "$TMP/pulse" Linux -- play done >/dev/null
[[ "$(played)" == "paplay /"*"/attention-done.wav" ]] && ok "Linux paplay gets no --device" || no "paplay default (got: $(cat "$LOG"))"
reset; run "$TMP/alsa" Linux -- play done >/dev/null
[[ "$(played)" == "aplay /"*"/attention-done.wav" ]] && ok "Linux aplay gets no -D" || no "aplay default (got: $(cat "$LOG"))"
# A helper compiled by an older version is never called.
mkdir -p "$H/.workflow-dev/bin"
printf '#!/bin/bash\nprintf "helper %%s\\n" "$*" >> "%s"\n' "$LOG" > "$H/.workflow-dev/bin/attention-play"
chmod +x "$H/.workflow-dev/bin/attention-play"
reset; run "$TMP/mac" Darwin -- play done >/dev/null
[[ "$(played)" == "afplay "* && "$(cat "$LOG")" != *helper* ]] && ok "an old output helper is never called" || no "old helper (got: $(cat "$LOG"))"
rm -rf "$H/.workflow-dev/bin"
# An old repo entry that named an output plays on the default output too.
printf '{"notifications":[{"storyId":"T-1","device":"MacBook Pro Speakers"}]}\n' > "$PROJ/.workflow-dev/config.json"
reset; run "$TMP/mac" Darwin -- play done >/dev/null
[[ "$(played)" == "afplay /"*"/attention-done.wav" ]] && ok "an old repo entry naming an output plays on the default output" || no "old entry output (got: $(cat "$LOG"))"
rm -f "$PROJ/.workflow-dev/config.json"
# A retired machine file is never read: not its device, not its volume.
printf '{"device": "MacBook Pro Speakers", "volume": "25"}\n' > "$H/.workflow-dev/attention.json"
reset; run "$TMP/mac" Darwin -- play done >/dev/null
[[ "$(played)" == "afplay /"*"/assets/attention-done.wav" ]] && ok "attention.json is no longer read (no device, no -v)" || no "attention.json ignored (got: $(cat "$LOG"))"
rm -f "$H/.workflow-dev/attention.json"
reset; run "$TMP/mac" Darwin WORKFLOW_DEV_ATTENTION_VOLUME=40 WORKFLOW_DEV_ATTENTION_DEVICE=Headset -- play done >/dev/null
[[ "$(played)" == "afplay /"*"/assets/attention-done.wav" ]] && ok "WORKFLOW_DEV_ATTENTION_VOLUME and _DEVICE are ignored" || no "env ignored (got: $(cat "$LOG"))"
for gone in set-device set-volume device volume devices suggest set-pref pref activate deactivate entries active offer prune; do
  run "$TMP/mac" Darwin -- "$gone" >/dev/null 2>&1; rc=$?
  run "$TMP/mac" Darwin -- "$gone" x >/dev/null 2>&1; rc2=$?
  [[ $rc -eq 2 && $rc2 -eq 2 ]] && ok "'$gone' is no longer a command (usage error)" || no "'$gone' retired (rc=$rc/$rc2)"
done
for bad in "play start Speakers" "play done X" "set yes" "set" "set on off" "get x" "set ON"; do
  run "$TMP/mac" Darwin -- $bad >/dev/null 2>&1; rc=$?
  [[ $rc -eq 2 ]] && ok "'$bad' is a usage error" || no "'$bad' usage (rc=$rc)"
done

# --- 12. one answer per machine: get and set ---------------------------------
HAVE_JQ=1; command -v jq >/dev/null 2>&1 || HAVE_JQ=0
inp() { run "$TMP/mac" Darwin "$@"; }
# Every key path in the user config that names an output.
device_paths() { jq -r '[paths | map(tostring) | join(".")] | map(select(test("device"; "i"))) | .[]' "$UCFG" 2>/dev/null; }
if [[ $HAVE_JQ -eq 1 ]]; then
  rm -rf "$H"
  [[ "$(inp -- get)" == unset && ! -e "$UCFG" ]] && ok "no config reads as unset, and reading writes nothing" || no "fresh get"
  [[ "$(inp -- set on)" == saved && "$(inp -- get)" == on ]] && ok "set on is saved and read back" || no "set on"
  jq -e '.notifications == true' "$UCFG" >/dev/null && ok "the answer lives at notifications, a JSON boolean" || no "answer shape ($(cat "$UCFG"))"
  [[ -n "$(find "$H/.workflow-dev" -maxdepth 0 -perm 700)" ]] && ok "the user folder is private (700)" || no "user folder mode"
  [[ "$(inp -- set off)" == saved && "$(inp -- get)" == off ]] && jq -e '.notifications == false' "$UCFG" >/dev/null && ok "set off is saved and read back" || no "set off"
  printf '{"keep":"me","language":"es","userPref":{"notifications":{"device":"Headset"}}}\n' > "$UCFG"
  [[ "$(inp -- get)" == unset ]] && ok "an old saved output (userPref) is no answer" || no "userPref read (got: $(inp -- get))"
  inp -- set on >/dev/null
  jq -e '.keep == "me" and .language == "es" and .userPref.notifications.device == "Headset" and .notifications == true' "$UCFG" >/dev/null && ok "set keeps every other key, an old userPref too" || no "set keeps keys ($(cat "$UCFG"))"
  for raw in '{"notifications":"true"}' '{"notifications":1}' '{"notifications":null}' '{"notifications":{}}' '{"notifications":[{"storyId":"T-1","device":"x"}]}' '{}' '' '   '; do
    printf '%s' "$raw" > "$UCFG"
    [[ "$(inp -- get)" == unset ]] && ok "notifications as '$raw' reads as unset" || no "non-boolean '$raw' (got: $(inp -- get))"
    [[ "$(inp -- set on)" == saved && "$(inp -- get)" == on ]] && ok "set on replaces '$raw' with a yes" || no "set over '$raw' ($(cat "$UCFG"))"
  done
  for raw in 'not json' '[1,2]' '{"a":1}{"b":2}' '"str"'; do
    printf '%s' "$raw" > "$UCFG"
    [[ "$(inp -- get)" == unset && "$(inp -- set on)" == unavailable && "$(cat "$UCFG")" == "$raw" ]] && ok "a config of '$raw' reads as unset and is left untouched" || no "bad config '$raw' ($(cat "$UCFG"))"
  done
  rm -f "$UCFG"; inp -- set on >/dev/null; inp -- set off >/dev/null; inp -- set on >/dev/null
  [[ -z "$(device_paths)" ]] && ok "no write stores an output" || no "a device was written: $(device_paths)"
  # An old repo-level list is neither an answer nor touched.
  rm -rf "$H"
  printf '{"gitignored":true,"notifications":[{"storyId":"T-1","device":"Spk"}]}\n' > "$PROJ/.workflow-dev/config.json"
  cp "$PROJ/.workflow-dev/config.json" "$TMP/repo-before.json"
  [[ "$(inp -- get)" == unset ]] && ok "an old per-story list in the repo is no answer" || no "repo list read"
  inp -- set on >/dev/null
  cmp -s "$PROJ/.workflow-dev/config.json" "$TMP/repo-before.json" && ok "set writes nothing to the repo's config" || no "repo config changed ($(cat "$PROJ/.workflow-dev/config.json"))"
  rm -f "$PROJ/.workflow-dev/config.json" "$TMP/repo-before.json"
  # The answer holds outside any workflow-dev project too: it is the machine's.
  mkdir -p "$TMP/nowf"
  [[ "$(RUN_CWD="$TMP/nowf" run "$TMP/mac" Darwin -- get)" == on ]] && ok "get reads the machine's answer from any folder" || no "get outside a project"
else
  printf '  skip get/set storage (no jq on this machine)\n'
fi
# With neither jq nor perl nothing can be written, and nothing is read.
nojq="$TMP/nojq"; mkdir -p "$nojq"
for tool in dirname tr sleep cat mv rm mkdir mktemp chmod find date basename sed grep head awk ls seq wc git rmdir cp readlink; do
  real="$(command -v "$tool")" && ln -sf "$real" "$nojq/$tool"
done
printf '#!/bin/bash\necho Darwin\n' > "$nojq/uname"; chmod +x "$nojq/uname"
nj() { ( cd "$PROJ" && env -i HOME="$TMP/home" PATH="$TMP/mac:$nojq" /bin/bash "$SCRIPT" "$@" ); }
rm -rf "$H"
[[ "$(nj set on)" == unavailable && ! -e "$UCFG" ]] && ok "without jq or perl, set is unavailable and writes nothing" || no "no engine set"
seed_answer on
[[ "$(nj get)" == unset ]] && ok "without jq or perl, nothing is read (unset)" || no "no engine get"
: > "$LOG"; nj play done >/dev/null
silent && ok "without jq or perl, nothing sounds" || no "no engine play (got: $(cat "$LOG"))"
rm -rf "$H"

# --- 12b. the gate: one yes for every story, every repo ----------------------
GP="$TMP/gateproj"
rm -rf "$GP"; mkdir -p "$GP/.workflow-dev/context"
( cd "$GP" && git init -q && git checkout -q -b wd-0068-x && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m i ) >/dev/null 2>&1
gp() { RUN_CWD="$GP" run "$TMP/mac" Darwin "$@"; }
gphook() { # gphook <flag> <extra json> [VAR=value ...]
  local flag="$1" extra="$2"; shift 2
  printf '%s' "$(payload "g-$N" "$GP" "$extra")" | RUN_CWD="$GP" run "$TMP/mac" Darwin ${@+"$@"} -- "$flag"
}
gstop() { # gstop <kind> [VAR=value ...]: arm then Stop, one session
  local kind="$1"; shift
  N=$((N + 1)); RUN_CWD="$GP" run "$TMP/mac" Darwin "CLAUDE_CODE_SESSION_ID=g-$N" -- arm "$kind" >/dev/null
  printf '%s' "$(payload "g-$N" "$GP")" | RUN_CWD="$GP" run "$TMP/mac" Darwin ${@+"$@"} -- --stop >/dev/null
}
for kind in need permission commit pr done passed fail saved story away start; do
  reset; gp -- play "$kind" >/dev/null
  [[ "$(played)" == *"/attention-$kind.wav" ]] && ok "yes: '$kind' sounds" || no "yes '$kind' (got: $(cat "$LOG"))"
done
for answer in off unset; do
  for kind in need permission commit pr done passed fail saved story away start; do
    reset; if [[ $answer == off ]]; then seed_answer off; else rm -f "$UCFG"; fi
    gp -- play "$kind" >/dev/null
    silent && ok "$answer: '$kind' is silent" || no "$answer '$kind' (got: $(cat "$LOG"))"
  done
  reset; if [[ $answer == off ]]; then seed_answer off; else rm -f "$UCFG"; fi
  N=$((N + 1)); gphook --ask '' >/dev/null
  N=$((N + 1)); gphook --notify ',"notification_type":"permission_prompt"' >/dev/null
  if [[ $answer == off ]]; then seed_answer off; else rm -f "$UCFG"; fi
  gstop done
  silent && ok "$answer: a question, a permission prompt and an armed Stop are silent" || no "$answer hooks (got: $(cat "$LOG"))"
done
# An old per-story list in the repo is not an answer, and is never touched.
printf '{"notifications":[{"storyId":"WD-0068","device":"Spk"}]}\n' > "$GP/.workflow-dev/config.json"
cp "$GP/.workflow-dev/config.json" "$TMP/gp-before.json"
reset; rm -f "$UCFG"; gp -- play done >/dev/null
silent && ok "an old repo list with no machine answer is silent" || no "old list sounded (got: $(cat "$LOG"))"
reset; gp -- play done >/dev/null
[[ "$(played)" == "afplay "*"/attention-done.wav" ]] && ok "an old repo list and a yes: it sounds" || no "old list + yes (got: $(cat "$LOG"))"
reset; gstop story; played >/dev/null; gp -- set on >/dev/null
cmp -s "$GP/.workflow-dev/config.json" "$TMP/gp-before.json" && ok "the repo's config stays byte-identical through play, Stop and set" || no "repo config changed"
rm -f "$GP/.workflow-dev/config.json" "$TMP/gp-before.json"
mkdir -p "$TMP/nowf2"; reset; RUN_CWD="$TMP/nowf2" run "$TMP/mac" Darwin -- play done >/dev/null
silent && ok "a yes outside any workflow-dev project: silent" || no "no project (got: $(cat "$LOG"))"
N=$((N + 1)); reset; printf '%s' "$(payload "g-$N" "$TMP/nowf2")" | RUN_CWD="$TMP/nowf2" run "$TMP/mac" Darwin -- --ask >/dev/null
silent && ok "a yes and a question outside any project: silent" || no "ask no project (got: $(cat "$LOG"))"
for v in "CI=true" "CLAUDE_CODE_SESSION_ATTENDED=0"; do
  reset; gp "$v" -- play done >/dev/null
  silent && ok "a yes does not override $v" || no "yes vs $v"
done
reset; gp WORKFLOW_DEV_ATTENTION=off -- play done >/dev/null
[[ "$(played)" == "afplay "* ]] && ok "a yes and WORKFLOW_DEV_ATTENTION=off in the environment: it sounds" || no "yes vs off (got: $(cat "$LOG"))"
# A checkout between the arm and the Stop changes nothing: no branch is read.
N=$((N + 1)); SIDG="g-$N"; reset
RUN_CWD="$GP" run "$TMP/mac" Darwin "CLAUDE_CODE_SESSION_ID=$SIDG" -- arm story >/dev/null
( cd "$GP" && git checkout -q -b main-after )
printf '%s' "$(payload "$SIDG" "$GP")" | RUN_CWD="$GP" run "$TMP/mac" Darwin -- --stop >/dev/null
[[ "$(played)" == *"/attention-story.wav" ]] && ok "the fanfare sounds after a checkout to another branch" || no "fanfare after checkout (got: $(cat "$LOG"))"
# A finished story turns nothing off.
printf '### Implementation Status: Done\n' > "$GP/.workflow-dev/context/WD-0068.md"
printf '{"gitignored":true}\n' > "$GP/.workflow-dev/config.json"
cp "$GP/.workflow-dev/config.json" "$TMP/gp-before.json"
reset; cp "$UCFG" "$TMP/u-before.json"
N=$((N + 1)); SIDG="g-$N"
RUN_CWD="$GP" run "$TMP/mac" Darwin "CLAUDE_CODE_SESSION_ID=$SIDG" -- arm story >/dev/null
[[ "$(wc -l < "$TMP/t/workflow-dev-validate/attention/armed-$SIDG" | tr -d ' ')" == 1 ]] && ok "the arm holds the kind alone" || no "arm lines ($(cat "$TMP/t/workflow-dev-validate/attention/armed-$SIDG"))"
printf '%s' "$(payload "$SIDG" "$GP")" | RUN_CWD="$GP" run "$TMP/mac" Darwin -- --stop >/dev/null
[[ "$(played)" == *"/attention-story.wav" ]] && ok "the fanfare of a Done story sounds" || no "Done fanfare (got: $(cat "$LOG"))"
[[ "$(gp -- get)" == on ]] && cmp -s "$UCFG" "$TMP/u-before.json" && cmp -s "$GP/.workflow-dev/config.json" "$TMP/gp-before.json" && ok "after a Done story's fanfare the answer is still yes and no config changed" || no "Done changed a config"
: > "$LOG"; gstop done
[[ "$(played)" == *"/attention-done.wav" ]] && ok "the next hand-back after a Done story still sounds" || no "after Done (got: $(cat "$LOG"))"
# An arm left by an older version (kind, then a story id) still plays its kind.
N=$((N + 1)); SIDG="g-$N"; reset
mkdir -p "$TMP/t/workflow-dev-validate/attention"; chmod 700 "$TMP/t/workflow-dev-validate" "$TMP/t/workflow-dev-validate/attention"
printf 'passed\nWD-0068\n' > "$TMP/t/workflow-dev-validate/attention/armed-$SIDG"
printf '%s' "$(payload "$SIDG" "$GP")" | RUN_CWD="$GP" run "$TMP/mac" Darwin -- --stop >/dev/null
[[ "$(played)" == *"/attention-passed.wav" ]] && ok "an older two-line arm plays its kind" || no "old arm (got: $(cat "$LOG"))"
rm -rf "$GP" "$TMP/gp-before.json" "$TMP/u-before.json"

# --- 12c. the one write: symlink, mode, empty file, directory, concurrency ----
if [[ $HAVE_JQ -eq 1 ]]; then
  rm -rf "$H"
  mkdir -p "$TMP/dot"; printf '{"x":1}\n' > "$TMP/dot/user.json"; chmod 644 "$TMP/dot/user.json"
  mkdir -p "$H/.workflow-dev"; ln -s "$TMP/dot/user.json" "$UCFG"
  inp -- set on >/dev/null
  [[ -L "$UCFG" ]] && jq -e '.x == 1 and .notifications == true' "$TMP/dot/user.json" >/dev/null && ok "a symlinked config is edited where it points, the link kept" || no "symlinked config"
  [[ -n "$(find "$TMP/dot/user.json" -perm 644)" ]] && ok "a write keeps the file's mode" || no "mode kept"
  rm -rf "$H" "$TMP/dot"
  # A chain of more than ten links is refused, so the real target is never left behind.
  mkdir -p "$TMP/dot" "$H/.workflow-dev"; printf '{"notifications":true}\n' > "$TMP/dot/real.json"
  prev="$TMP/dot/real.json"; for i in $(seq 1 11); do ln -s "$prev" "$TMP/dot/l$i"; prev="$TMP/dot/l$i"; done; ln -s "$prev" "$UCFG"
  [[ "$(inp -- set off)" == unavailable && -L "$TMP/dot/l1" ]] && jq -e '.notifications == true' "$TMP/dot/real.json" >/dev/null && ok "a chain of more than ten links is refused, every link kept" || no "long link chain"
  [[ "$(inp -- get)" == unset ]] && ok "...and reads as unset, never an 'on' that set cannot change" || no "long chain get (got: $(inp -- get))"
  rm -f "$UCFG"; ln -s "$TMP/dot/l9" "$UCFG"
  [[ "$(inp -- get)" == on && "$(inp -- set off)" == saved && "$(inp -- get)" == off ]] && jq -e '.notifications == false' "$TMP/dot/real.json" >/dev/null && ok "a chain of ten links is read and edited at its target" || no "ten-link chain"
  rm -rf "$H" "$TMP/dot"
  # A NUL byte reads the same for get and set: no answer, never an 'on' that set cannot change.
  mkdir -p "$H/.workflow-dev"; printf '{"notifications":true}\0junk' > "$UCFG"
  [[ "$(inp -- get)" == unset ]] && ok "a config with a NUL and trailing junk reads as unset (silent)" || no "NUL junk get (got: $(inp -- get))"
  printf '{"notifications":true}\0{"notifications":false}' > "$UCFG"
  [[ "$(inp -- get)" == unset ]] && ok "two documents split by a NUL read as unset" || no "NUL two docs (got: $(inp -- get))"
  printf '{"notifications":true}\0' > "$UCFG"
  [[ "$(inp -- get)" == on ]] && ok "a trailing NUL alone still reads" || no "trailing NUL (got: $(inp -- get))"
  rm -rf "$H"
  mkdir -p "$H/.workflow-dev"; mkdir "$UCFG"
  [[ "$(inp -- set on)" == unavailable && "$(inp -- get)" == unset ]] && ok "a directory at the config path is unavailable, not saved" || no "dir at config path"
  rmdir "$UCFG"
  printf '{"keep":true}\n' > "$UCFG"
  for i in 1 2 3 4 5 6 7 8 9 10; do inp -- set "$([[ $((i % 2)) == 0 ]] && echo on || echo off)" >/dev/null & done; wait
  jq -e '.keep == true and (.notifications | type) == "boolean"' "$UCFG" >/dev/null && ok "ten parallel writes leave one valid answer and keep other keys" || no "parallel writes ($(cat "$UCFG"))"
  [[ ! -d "$H/.workflow-dev/.config.json.lock" ]] && ok "the write lock is released" || no "lock left behind"
  # A large pretty-printed config is written in linear time.
  { printf '{\n  "notifications": false,\n  "pad": [\n'; for i in $(seq 1 3000); do printf '    "a b c d e f",\n'; done; printf '    "end"\n  ]\n}\n'; } > "$UCFG"
  start=$SECONDS; out="$(inp -- set on)"; took=$((SECONDS - start))
  [[ "$out" == saved && $took -le 3 && "$(inp -- get)" == on ]] && jq -e '.pad | length == 3001' "$UCFG" >/dev/null && ok "a 100 KB indented config is written in seconds, every key kept (${took}s)" || no "large config (out=$out took=${took}s)"
  mkdir "$H/.workflow-dev/.config.json.lock"; touch -t 200001010000 "$H/.workflow-dev/.config.json.lock"
  [[ "$(inp -- set on)" == saved ]] && ok "a stale lock (a dead writer's) is cleared" || no "stale lock"
  chmod 555 "$H/.workflow-dev"
  start=$SECONDS; out="$(inp -- set off)"; took=$((SECONDS - start))
  chmod 755 "$H/.workflow-dev"
  [[ "$out" == unavailable && $took -le 1 ]] && ok "a read-only folder fails at once, without waiting for the lock" || no "read-only folder (out=$out took=${took}s)"
  touch "$H/.workflow-dev/.config.json.lock"
  start=$SECONDS; out="$(inp -- set off)"; took=$((SECONDS - start))
  rm -f "$H/.workflow-dev/.config.json.lock"
  [[ "$out" == unavailable && $took -le 1 ]] && ok "a file at the lock's path fails at once" || no "file at lock path (out=$out took=${took}s)"
  rm -rf "$H"
fi

# --- 12d. the perl engine: the same answer with perl and no jq ----------------
if command -v perl >/dev/null 2>&1 && perl -MJSON::PP -e1 >/dev/null 2>&1; then
  mkdir -p "$TMP/perlbin"; ln -sf "$(command -v perl)" "$TMP/perlbin/perl"
  rp() { EXTRA_PATH=":$TMP/perlbin" run "$TMP/mac" Darwin "$@"; }
  rm -rf "$H"
  [[ "$(rp -- get)" == unset ]] && ok "[perl] no config reads as unset" || no "[perl] fresh get"
  [[ "$(rp -- set on)" == saved && "$(rp -- get)" == on && "$(rp -- set off)" == saved && "$(rp -- get)" == off ]] && ok "[perl] set on and off are saved and read back" || no "[perl] round trip"
  grep -q '"notifications" *: *false' "$UCFG" && ok "[perl] the answer is a JSON boolean" || no "[perl] shape ($(cat "$UCFG"))"
  printf '{"keep": "me", "big": 12345678901234567890, "userPref": {"notifications": {"device": "Spk"}}}\n' > "$UCFG"
  [[ "$(rp -- get)" == unset ]] && ok "[perl] an old saved output is no answer" || no "[perl] userPref"
  rp -- set on >/dev/null
  grep -q '"keep" *: *"me"' "$UCFG" && grep -q 12345678901234567890 "$UCFG" && grep -q '"device" *: *"Spk"' "$UCFG" && ok "[perl] set keeps every other key (a big integer too)" || no "[perl] keeps keys ($(cat "$UCFG"))"
  for raw in '{"notifications":"true"}' '{"notifications":1}' '{"notifications":null}' '{"notifications":[{"storyId":"T-1","device":"x"}]}'; do
    printf '%s' "$raw" > "$UCFG"
    [[ "$(rp -- get)" == unset ]] && ok "[perl] notifications as '$raw' reads as unset" || no "[perl] '$raw' (got: $(rp -- get))"
  done
  for raw in 'not json' '[1,2]'; do
    printf '%s' "$raw" > "$UCFG"
    [[ "$(rp -- set on)" == unavailable && "$(cat "$UCFG")" == "$raw" ]] && ok "[perl] a config of '$raw' is left untouched" || no "[perl] bad '$raw'"
  done
  printf '\xef\xbb\xbf{"notifications": true}' > "$UCFG"
  [[ "$(rp -- get)" == on ]] && ok "[perl] a BOM at the start is read past" || no "[perl] BOM"
  printf '{"notifications":true}\0junk' > "$UCFG"
  [[ "$(rp -- get)" == unset && "$(rp -- set off)" == unavailable ]] && ok "[perl] a NUL and trailing junk read as unset" || no "[perl] NUL junk"
  printf '{"notifications":true}\0' > "$UCFG"
  [[ "$(rp -- get)" == on && "$(rp -- set off)" == saved && "$(rp -- get)" == off ]] && ok "[perl] a trailing NUL alone reads and writes like jq" || no "[perl] trailing NUL (got: $(rp -- get))"
  rm -rf "$H"
else
  printf '  skip perl engine (no perl with JSON::PP on this machine)\n'
fi

# --- 12e. the two engines read and write alike -------------------------------
if command -v perl >/dev/null 2>&1 && perl -MJSON::PP -e1 >/dev/null 2>&1 && [[ -x "$TMP/jq/jq" ]]; then
  mkdir -p "$TMP/perlbin"; ln -sf "$(command -v perl)" "$TMP/perlbin/perl"
  agree() { # agree <name> <config text> <command...>: both engines, same answer, same file
    local name="$1" cfg="$2" a b fa fb; shift 2
    mkdir -p "${UCFG%/*}"
    printf '%s' "$cfg" > "$UCFG"; a="$(run "$TMP/mac" Darwin -- "$@")"; fa="$(jq -cS . "$UCFG" 2>/dev/null)"
    printf '%s' "$cfg" > "$UCFG"; b="$(EXTRA_PATH=":$TMP/perlbin" run "$TMP/mac" Darwin -- "$@")"; fb="$(jq -cS . "$UCFG" 2>/dev/null)"
    [[ "$a" == "$b" && "$fa" == "$fb" ]] && ok "jq and perl agree: $name" || no "engines differ: $name (jq='$a' perl='$b' / jq-file='$fa' perl-file='$fb')"
  }
  for cfg in '{"notifications":true}' '{"notifications":false}' '{"notifications":"true"}' '{"notifications":0}' '{"notifications":null}' \
             '{"notifications":[{"storyId":"T-1","device":"d"}]}' '{"userPref":{"notifications":{"device":"d"}}}' '{}' \
             '{"notifications":true}{"notifications":false}' $'\xef\xbb\xbf{"notifications":true}' '[true]'; do
    agree "get on '$cfg'" "$cfg" get
    agree "set on over '$cfg'" "$cfg" set on
  done
  rm -rf "$H"
fi

out="$(run "$TMP/mac" Darwin -- arm done extra 2>/dev/null)"; rc=$?
[[ $rc -eq 2 ]] && ok "three arguments are a usage error" || no "three arguments (rc=$rc)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
