#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Tests for autonomous-keep-awake.sh (WD-0055). The real caffeinate is never
# run: a test double first in PATH records its arguments and, like the real
# one under `-w`, lives exactly as long as the PID it watches. The "session" is
# a throwaway `sleep`, and every marker lives under a throwaway TMPDIR.
#
# What it pins:
#   - start launches one caffeinate with exactly `-i -w <session>` (never -d/-u),
#     saves its PID, and a second start launches nothing;
#   - stop ends only our own process, and a dead, garbage or foreign PID is
#     `not-running`, never an error and never a kill;
#   - outside macOS, or with no caffeinate, nothing runs and nothing is written;
#   - with no session to watch it skips; when the session ends, caffeinate ends.
#
#   bash scripts/autonomous-keep-awake.test.sh

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/autonomous-keep-awake.sh"

TMP="$(mktemp -d)"
PIDS=()
cleanup() {
  local p
  for p in "${PIDS[@]:-}"; do
    [[ -n "$p" ]] || continue
    pkill -P "$p" 2>/dev/null
    kill "$p" 2>/dev/null
    wait "$p" 2>/dev/null
  done
  rm -rf "$TMP"
}
trap cleanup EXIT

pass=0
fail=0
ok() { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }

export TMPDIR="$TMP/tmpdir"
mkdir -p "$TMPDIR" "$TMP/bin"
ARGV_LOG="$TMP/argv.log"
: > "$ARGV_LOG"

cat > "$TMP/bin/caffeinate" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$ARGV_LOG"
while kill -0 "\$3" 2>/dev/null; do sleep 0.2; done
EOF
cat > "$TMP/bin/uname" <<'EOF'
#!/bin/bash
if [[ -n "${FAKE_UNAME:-}" ]]; then echo "$FAKE_UNAME"; else /usr/bin/uname "$@"; fi
EOF
chmod +x "$TMP/bin/caffeinate" "$TMP/bin/uname"
export PATH="$TMP/bin:$PATH"
export FAKE_UNAME="Darwin"
unset CLAUDE_PID

MARKERS="$TMPDIR/workflow-dev-validate/keep-awake"

sleep 300 & SESSION=$!; PIDS+=("$SESSION")

run() { bash "$SCRIPT" "$@"; }

# --- 1. start launches one caffeinate with exactly -i -w <session> ----------
out="$(run start --watch "$SESSION")"; rc=$?
CAF="${out#started }"
[[ $rc -eq 0 && "$out" =~ ^started\ [0-9]+$ ]] && ok "start prints started <pid>" || no "start prints started <pid> (got: rc=$rc '$out')"
PIDS+=("$CAF")
[[ "$(cat "$MARKERS/$SESSION.pid" 2>/dev/null)" == "$CAF" ]] && ok "start saves the PID in the session marker" || no "start saves the PID in the session marker"
for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -s "$ARGV_LOG" ]] && break; sleep 0.1; done
[[ "$(cat "$ARGV_LOG")" == "-i -w $SESSION" ]] && ok "caffeinate gets exactly -i -w <session>" || no "caffeinate gets exactly -i -w <session> (got: $(cat "$ARGV_LOG"))"
if grep -Eq -- '(^| )-[a-z]*[du]' "$ARGV_LOG"; then no "no -d and no -u in the launched command"; else ok "no -d and no -u in the launched command"; fi
kill -0 "$CAF" 2>/dev/null && ok "caffeinate outlives the start call" || no "caffeinate outlives the start call"

# --- 2. a second start launches nothing --------------------------------------
out="$(run start --watch "$SESSION")"
[[ "$out" == "running $CAF" ]] && ok "second start answers running <same pid>" || no "second start answers running <same pid> (got: '$out')"
[[ "$(wc -l < "$ARGV_LOG" | tr -d ' ')" == "1" ]] && ok "only one caffeinate was ever launched" || no "only one caffeinate was ever launched"
[[ "$(run status --watch "$SESSION")" == "running $CAF" ]] && ok "status reports running <pid>" || no "status reports running <pid>"

# --- 3. stop ends it ---------------------------------------------------------
out="$(run stop --watch "$SESSION")"
[[ "$out" == "stopped $CAF" ]] && ok "stop prints stopped <pid>" || no "stop prints stopped <pid> (got: '$out')"
sleep 0.3
kill -0 "$CAF" 2>/dev/null && no "our caffeinate is ended" || ok "our caffeinate is ended"
[[ ! -e "$MARKERS/$SESSION.pid" ]] && ok "stop removes the marker" || no "stop removes the marker"

# --- 4. stop again is not an error -------------------------------------------
out="$(run stop --watch "$SESSION")"; rc=$?
[[ $rc -eq 0 && "$out" == "not-running" ]] && ok "stop with nothing running: not-running, exit 0" || no "stop with nothing running (got: rc=$rc '$out')"
[[ "$(run status --watch "$SESSION")" == "not-running" ]] && ok "status reports not-running" || no "status reports not-running"

# --- 5. a marker pointing at a dead PID --------------------------------------
sleep 0 & DEAD=$!; wait "$DEAD" 2>/dev/null
mkdir -p "$MARKERS"; chmod 700 "$TMPDIR/workflow-dev-validate" "$MARKERS"
printf '%s\n' "$DEAD" > "$MARKERS/$SESSION.pid"
out="$(run stop --watch "$SESSION")"; rc=$?
[[ $rc -eq 0 && "$out" == "not-running" ]] && ok "dead PID: not-running, exit 0" || no "dead PID (got: rc=$rc '$out')"
[[ ! -e "$MARKERS/$SESSION.pid" ]] && ok "dead PID: stale marker removed" || no "dead PID: stale marker removed"

# --- 6. a marker with garbage ------------------------------------------------
printf 'not a pid; rm -rf /\n' > "$MARKERS/$SESSION.pid"
out="$(run stop --watch "$SESSION")"; rc=$?
[[ $rc -eq 0 && "$out" == "not-running" ]] && ok "garbage marker: not-running, exit 0" || no "garbage marker (got: rc=$rc '$out')"
printf 'junk' > "$MARKERS/$SESSION.pid"
out="$(run start --watch "$SESSION")"
CAF2="${out#started }"; PIDS+=("$CAF2")
[[ "$out" =~ ^started\ [0-9]+$ ]] && ok "start over a garbage marker launches a fresh one" || no "start over a garbage marker (got: '$out')"
run stop --watch "$SESSION" >/dev/null

# --- 7. a marker pointing at a live process that is not ours -----------------
sleep 300 & OTHER=$!; PIDS+=("$OTHER")
printf '%s\n' "$OTHER" > "$MARKERS/$SESSION.pid"
out="$(run stop --watch "$SESSION")"
[[ "$out" == "not-running" ]] && ok "foreign live PID: not-running" || no "foreign live PID (got: '$out')"
kill -0 "$OTHER" 2>/dev/null && ok "foreign live PID is left alone" || no "foreign live PID is left alone"
[[ "$(run status --watch "$SESSION")" == "not-running" ]] && ok "status does not claim a foreign PID" || no "status does not claim a foreign PID"

# --- 8. usage errors ---------------------------------------------------------
run start --watch abc >/dev/null 2>&1; rc=$?
[[ $rc -eq 2 ]] && ok "non-numeric --watch exits 2" || no "non-numeric --watch exits 2 (got: $rc)"
run start --watch 1 >/dev/null 2>&1; rc=$?
[[ $rc -eq 2 ]] && ok "--watch 1 (launchd) exits 2" || no "--watch 1 exits 2 (got: $rc)"
run bogus >/dev/null 2>&1; rc=$?
[[ $rc -eq 2 ]] && ok "unknown action exits 2" || no "unknown action exits 2 (got: $rc)"
run >/dev/null 2>&1; rc=$?
[[ $rc -eq 2 ]] && ok "no action exits 2" || no "no action exits 2 (got: $rc)"

# --- 9. outside macOS: nothing runs, nothing is written ----------------------
rm -rf "$TMPDIR/workflow-dev-validate"; : > "$ARGV_LOG"
out="$(FAKE_UNAME=Linux run start --watch "$SESSION")"; rc=$?
[[ $rc -eq 0 && "$out" == "unsupported" ]] && ok "Linux: unsupported, exit 0" || no "Linux (got: rc=$rc '$out')"
[[ ! -s "$ARGV_LOG" ]] && ok "Linux: caffeinate never ran" || no "Linux: caffeinate never ran"
[[ ! -e "$TMPDIR/workflow-dev-validate" ]] && ok "Linux: no marker written" || no "Linux: no marker written"
out="$(FAKE_UNAME=Linux run stop --watch "$SESSION")"
[[ "$out" == "unsupported" ]] && ok "Linux: stop is unsupported too" || no "Linux: stop (got: '$out')"

# --- 10. macOS with no caffeinate in PATH ------------------------------------
NOCAF="$TMP/nocaf"
mkdir -p "$NOCAF"
for tool in bash ps awk sed head tr kill basename dirname mkdir mv rm chmod mktemp cat find nohup; do
  p="$(command -v "$tool" 2>/dev/null)" && [[ "$p" == /* ]] && ln -sf "$p" "$NOCAF/$tool"
done
ln -sf "$TMP/bin/uname" "$NOCAF/uname"
out="$(PATH="$NOCAF" "$NOCAF/bash" "$SCRIPT" start --watch "$SESSION")"; rc=$?
[[ $rc -eq 0 && "$out" == "unsupported" ]] && ok "no caffeinate: unsupported, exit 0" || no "no caffeinate (got: rc=$rc '$out')"

# --- 11. no session to watch -------------------------------------------------
out="$(KEEP_AWAKE_SESSION_COMM=no-such-session-process run start)"; rc=$?
[[ $rc -eq 0 && "$out" == "no-session" ]] && ok "no session: no-session, exit 0" || no "no session (got: rc=$rc '$out')"
[[ ! -s "$ARGV_LOG" ]] && ok "no session: caffeinate never ran" || no "no session: caffeinate never ran"
out="$(CLAUDE_PID="$DEAD" KEEP_AWAKE_SESSION_COMM=no-such-session-process run start)"
[[ "$out" == "no-session" ]] && ok "a dead CLAUDE_PID is not a session" || no "a dead CLAUDE_PID (got: '$out')"

# --- 12. CLAUDE_PID is the session; when it ends, caffeinate ends ------------
sleep 300 & SESSION2=$!; PIDS+=("$SESSION2")
out="$(CLAUDE_PID="$SESSION2" run start)"
CAF3="${out#started }"; PIDS+=("$CAF3")
[[ "$out" =~ ^started\ [0-9]+$ && -e "$MARKERS/$SESSION2.pid" ]] && ok "CLAUDE_PID is used as the session" || no "CLAUDE_PID is used as the session (got: '$out')"
kill "$SESSION2"; wait "$SESSION2" 2>/dev/null
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do kill -0 "$CAF3" 2>/dev/null || break; sleep 0.2; done
kill -0 "$CAF3" 2>/dev/null && no "caffeinate ends with its session (-w)" || ok "caffeinate ends with its session (-w)"

# --- 13. the ancestor walk finds the named session process -------------------
# The test's own shell is an ancestor of the script; naming its command proves
# the walk without depending on a Claude Code session being around.
SELF_COMM="$(ps -o comm= -p $$ | sed 's#.*/##; s/^-//')"
out="$(KEEP_AWAKE_SESSION_COMM="$SELF_COMM" run status)"
[[ "$out" == "not-running" ]] && ok "ancestor walk resolves a session" || no "ancestor walk resolves a session (got: '$out')"

# --- 14. two starts at the same instant launch one caffeinate ---------------
rm -rf "$TMPDIR/workflow-dev-validate"; : > "$ARGV_LOG"
sleep 300 & SESSION3=$!; PIDS+=("$SESSION3")
run start --watch "$SESSION3" > "$TMP/r1" & J1=$!
run start --watch "$SESSION3" > "$TMP/r2" & J2=$!
wait "$J1"; wait "$J2"
for f in "$TMP/r1" "$TMP/r2"; do p="$(awk '{print $2}' "$f")"; [[ -n "$p" ]] && PIDS+=("$p"); done
sleep 0.5
[[ "$(wc -l < "$ARGV_LOG" | tr -d ' ')" == "1" ]] && ok "parallel starts launch a single caffeinate" || no "parallel starts launch a single caffeinate (launched $(wc -l < "$ARGV_LOG" | tr -d ' '); got: $(cat "$TMP/r1") / $(cat "$TMP/r2"))"
[[ "$(sort "$TMP/r1" "$TMP/r2" | awk '{print $1}' | tr '\n' ' ')" == "running started " ]] && ok "one parallel start says started, the other running" || no "parallel start answers (got: $(cat "$TMP/r1") / $(cat "$TMP/r2"))"
[[ "$(run stop --watch "$SESSION3")" =~ ^stopped ]] && ok "stop after parallel starts ends it" || no "stop after parallel starts ends it"
[[ ! -e "$MARKERS/$SESSION3.lock" ]] && ok "the lock is released" || no "the lock is released"

# --- 15. a lock left by a dead holder does not block -------------------------
mkdir -p "$MARKERS/$SESSION3.lock"
out="$(run start --watch "$SESSION3")"
p="${out#started }"; PIDS+=("$p")
[[ "$out" =~ ^started\ [0-9]+$ ]] && ok "a stale lock is taken over" || no "a stale lock is taken over (got: '$out')"
run stop --watch "$SESSION3" >/dev/null

count_ours() {
  ps -U "$(id -u)" -o command= | grep -c -- "caffeinate -i -w $1\$"
}

# --- 16. a stale lock from a dead holder, then parallel starts ---------------
sleep 0 & GONE=$!; wait "$GONE" 2>/dev/null
for loop in 1 2 3 4 5; do
  mkdir -p "$MARKERS/$SESSION3.lock"; printf '%s\n' "$GONE" > "$MARKERS/$SESSION3.lock/pid"
  for k in 1 2 3 4; do run start --watch "$SESSION3" > "$TMP/p$k" 2>&1 & eval "J$k=\$!"; done
  rcs=""
  for k in 1 2 3 4; do eval "wait \$J$k"; rcs="$rcs$?"; p="$(awk '{print $2}' "$TMP/p$k")"; is_num='^[0-9]+$'; [[ "$p" =~ $is_num ]] && PIDS+=("$p"); done
  sleep 0.3
  [[ "$(count_ours "$SESSION3")" == "1" && "$rcs" == "0000" ]] && ok "dead-holder lock + 4 parallel starts: one caffeinate, all exit 0 ($loop)" || no "dead-holder lock + parallel starts ($loop): $(count_ours "$SESSION3") alive, exits $rcs, out: $(cat "$TMP"/p1 "$TMP"/p2 "$TMP"/p3 "$TMP"/p4 | tr '\n' '|')"
  run stop --watch "$SESSION3" >/dev/null
  sleep 0.3
  [[ "$(count_ours "$SESSION3")" == "0" ]] && ok "then stop leaves none alive ($loop)" || no "then stop leaves none alive ($loop)"
  [[ ! -e "$MARKERS/$SESSION3.lock.takeover" ]] && ok "no takeover guard left behind ($loop)" || no "no takeover guard left behind ($loop)"
done

# --- 17. a caffeinate with our arguments that we did not save is not ours ---
caffeinate -i -w "$SESSION3" & HUMANS=$!; PIDS+=("$HUMANS")
sleep 0.3
out="$(run stop --watch "$SESSION3")"
[[ "$out" == "not-running" ]] && ok "stop names nothing it did not save" || no "stop names nothing it did not save (got: '$out')"
kill -0 "$HUMANS" 2>/dev/null && ok "a same-argument caffeinate it did not start is left alone" || no "a same-argument caffeinate it did not start is left alone"
kill "$HUMANS" 2>/dev/null; wait "$HUMANS" 2>/dev/null

# --- 18. a lock held by a live call is reported, not waited on forever -------
bash -c "sleep 300; : autonomous-keep-awake" 2>/dev/null & HOLDER=$!; PIDS+=("$HOLDER")
mkdir -p "$MARKERS/$SESSION3.lock"; printf '%s\n' "$HOLDER" > "$MARKERS/$SESSION3.lock/pid"
start_s=$SECONDS
run start --watch "$SESSION3" >"$TMP/out18" 2>"$TMP/err18"; rc=$?
[[ $rc -eq 1 && -s "$TMP/err18" && ! -s "$TMP/out18" ]] && ok "held lock: exit 1 with a reason" || no "held lock (got: rc=$rc out=$(cat "$TMP/out18"))"
(( SECONDS - start_s <= 8 )) && ok "held lock: gives up within the bound" || no "held lock: gives up within the bound ($((SECONDS - start_s))s)"
[[ -d "$MARKERS/$SESSION3.lock" ]] && ok "someone else's live lock is not removed" || no "someone else's live lock is not removed"
rm -rf "$MARKERS/$SESSION3.lock"

# --- 19. leftovers of a killed takeover, and a reused holder PID ------------
mkdir -p "$MARKERS/$SESSION3.lock" "$MARKERS/$SESSION3.lock.takeover"
printf '%s\n' "$GONE" > "$MARKERS/$SESSION3.lock/pid"
printf '%s\n' "$GONE" > "$MARKERS/$SESSION3.lock.takeover/pid"
out="$(run start --watch "$SESSION3")"; p="${out#started }"; PIDS+=("$p")
[[ "$out" =~ ^started\ [0-9]+$ && ! -e "$MARKERS/$SESSION3.lock.takeover" ]] && ok "a dead takeover guard does not block the session" || no "a dead takeover guard (got: '$out')"
run stop --watch "$SESSION3" >/dev/null
mkdir -p "$MARKERS/$SESSION3.lock"; printf '%s\n' "$OTHER" > "$MARKERS/$SESSION3.lock/pid"
# OTHER is a plain `sleep`: as a holder it reads as a PID reused by another
# program, so the lock is stale.
out="$(run start --watch "$SESSION3")"; p="${out#started }"; PIDS+=("$p")
[[ "$out" =~ ^started\ [0-9]+$ ]] && ok "a holder PID reused by another program is stale" || no "a reused holder PID (got: '$out')"
kill -0 "$OTHER" 2>/dev/null && ok "the process that reused the PID is untouched" || no "the process that reused the PID is untouched"
run stop --watch "$SESSION3" >/dev/null
mkdir -p "$MARKERS/$SESSION3.lock"; printf '0\n' > "$MARKERS/$SESSION3.lock/pid"
out="$(run start --watch "$SESSION3")"; p="${out#started }"; PIDS+=("$p")
[[ "$out" =~ ^started\ [0-9]+$ ]] && ok "a holder PID of 0 is stale" || no "a holder PID of 0 (got: '$out')"
run stop --watch "$SESSION3" >/dev/null

# --- 20. a lock and a guard both left empty by killed calls -----------------
mkdir -p "$MARKERS/$SESSION3.lock" "$MARKERS/$SESSION3.lock.takeover"
out="$(run start --watch "$SESSION3")"; rc=$?; p="${out#started }"; PIDS+=("$p")
[[ $rc -eq 0 && "$out" =~ ^started\ [0-9]+$ ]] && ok "empty lock + empty guard clear on their own" || no "empty lock + empty guard (got: rc=$rc '$out')"
run stop --watch "$SESSION3" >/dev/null
[[ ! -e "$MARKERS/$SESSION3.lock" && ! -e "$MARKERS/$SESSION3.lock.takeover" ]] && ok "nothing left behind after the takeover" || no "nothing left behind after the takeover"

# --- 21. an untrusted marker directory is refused, nothing is killed ---------
rm -rf "$TMPDIR/workflow-dev-validate"
mkdir -p "$MARKERS"; chmod 700 "$TMPDIR/workflow-dev-validate"; chmod 777 "$MARKERS"
printf '%s\n' "$OTHER" > "$MARKERS/$SESSION.pid"
run stop --watch "$SESSION" >/dev/null 2>"$TMP/err"; rc=$?
[[ $rc -eq 1 && -s "$TMP/err" ]] && ok "untrusted marker dir: exit 1 with a reason" || no "untrusted marker dir (got: rc=$rc)"
kill -0 "$OTHER" 2>/dev/null && ok "untrusted marker dir: nothing killed" || no "untrusted marker dir: nothing killed"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
