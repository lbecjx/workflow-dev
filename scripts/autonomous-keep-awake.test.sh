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
# a throwaway `sleep`.
#
# What it pins:
#   - start launches one caffeinate with exactly `-i -w <session>` (never -d/-u),
#     and a second start launches nothing;
#   - stop ends this session's caffeinate and leaves another session's alone;
#     with nothing running it is `not-running`, never an error;
#   - only a caffeinate at the exact path the script launches is ours, never
#     one at another path or a process that merely names caffeinate;
#   - when pgrep fails, the answer is `unknown` and nothing is launched or ended;
#   - outside macOS, or with no caffeinate, nothing runs;
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

mkdir -p "$TMP/bin"
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

run() { bash "$SCRIPT" "$@"; }
count_ours() { ps -U "$(id -u)" -o command= | grep -c -- "caffeinate -i -w $1\$"; }
launched() { wc -l < "$ARGV_LOG" | tr -d ' '; }

sleep 300 & SESSION=$!; PIDS+=("$SESSION")
sleep 300 & OTHER_SESSION=$!; PIDS+=("$OTHER_SESSION")

# --- 1. start launches one caffeinate with exactly -i -w <session> ----------
out="$(run start --watch "$SESSION")"; rc=$?
CAF="${out#started }"; PIDS+=("$CAF")
[[ $rc -eq 0 && "$out" =~ ^started\ [0-9]+$ ]] && ok "start prints started <pid>" || no "start prints started <pid> (got: rc=$rc '$out')"
for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -s "$ARGV_LOG" ]] && break; sleep 0.1; done
[[ "$(cat "$ARGV_LOG")" == "-i -w $SESSION" ]] && ok "caffeinate gets exactly -i -w <session>" || no "caffeinate gets exactly -i -w <session> (got: $(cat "$ARGV_LOG"))"
if grep -Eq -- '(^| )-[a-z]*[du]' "$ARGV_LOG"; then no "no -d and no -u in the launched command"; else ok "no -d and no -u in the launched command"; fi
kill -0 "$CAF" 2>/dev/null && ok "caffeinate outlives the start call" || no "caffeinate outlives the start call"

# --- 2. a second start launches nothing --------------------------------------
out="$(run start --watch "$SESSION")"
[[ "$out" == "running $CAF" ]] && ok "second start answers running <same pid>" || no "second start answers running <same pid> (got: '$out')"
out="$(run start --watch "0$SESSION")"
[[ "$out" == "running $CAF" ]] && ok "a leading zero names the same session" || no "a leading zero names the same session (got: '$out')"
[[ "$(launched)" == "1" && "$(count_ours "$SESSION")" == "1" ]] && ok "only one caffeinate was ever launched" || no "only one caffeinate was ever launched ($(launched) launched)"
[[ "$(run status --watch "$SESSION")" == "running $CAF" ]] && ok "status reports running <pid>" || no "status reports running <pid>"

# --- 3. stop closes only its own --------------------------------------------
caffeinate -i -w "$OTHER_SESSION" & OTHER_CAF=$!; PIDS+=("$OTHER_CAF")
sleep 0.3
out="$(run stop --watch "$SESSION")"
[[ "$out" == "stopped $CAF" ]] && ok "stop prints stopped <pid>" || no "stop prints stopped <pid> (got: '$out')"
sleep 0.3
kill -0 "$CAF" 2>/dev/null && no "our caffeinate is ended" || ok "our caffeinate is ended"
kill -0 "$OTHER_CAF" 2>/dev/null && ok "another session's caffeinate is left alone" || no "another session's caffeinate is left alone"

# --- 3b. a process that only names caffeinate in its arguments is not ours --
bash -c 'exec -a "less caffeinate -i -w $1" sleep 300' x "$SESSION" & DECOY=$!; PIDS+=("$DECOY")
sleep 0.3
[[ "$(run status --watch "$SESSION")" == "not-running" ]] && ok "a non-caffeinate naming our arguments is not ours" || no "a non-caffeinate naming our arguments is not ours"
run stop --watch "$SESSION" >/dev/null
kill -0 "$DECOY" 2>/dev/null && ok "stop leaves that process alone" || no "stop leaves that process alone"
kill "$DECOY" 2>/dev/null; wait "$DECOY" 2>/dev/null

# --- 3c. another executable called caffeinate is not ours -------------------
mkdir -p "$TMP/elsewhere"
cp "$TMP/bin/caffeinate" "$TMP/elsewhere/caffeinate"
"$TMP/elsewhere/caffeinate" -i -w "$SESSION" & IMPOSTOR=$!; PIDS+=("$IMPOSTOR")
sleep 0.3
[[ "$(run status --watch "$SESSION")" == "not-running" ]] && ok "a caffeinate at another path is not ours" || no "a caffeinate at another path is not ours"
run stop --watch "$SESSION" >/dev/null
kill -0 "$IMPOSTOR" 2>/dev/null && ok "stop leaves the other-path caffeinate alone" || no "stop leaves the other-path caffeinate alone"
kill "$IMPOSTOR" 2>/dev/null; wait "$IMPOSTOR" 2>/dev/null
: > "$ARGV_LOG"

# --- 3d. pgrep that cannot look: unknown, nothing launched or ended ----------
mkdir -p "$TMP/badpgrep"
printf '#!/bin/bash\nexit 3\n' > "$TMP/badpgrep/pgrep"
chmod +x "$TMP/badpgrep/pgrep"
out="$(PATH="$TMP/badpgrep:$PATH" bash "$SCRIPT" start --watch "$SESSION")"; rc=$?
sleep 0.3
[[ $rc -eq 0 && "$out" == "unknown" ]] && ok "start with a failing pgrep answers unknown, exit 0" || no "start with a failing pgrep (got: rc=$rc '$out')"
[[ ! -s "$ARGV_LOG" ]] && ok "and launches nothing" || no "and launches nothing ($(launched) launched)"
out="$(run start --watch "$SESSION")"; OURS="${out#started }"; PIDS+=("$OURS")
sleep 0.3
out="$(PATH="$TMP/badpgrep:$PATH" bash "$SCRIPT" stop --watch "$SESSION")"
[[ "$out" == "unknown" ]] && ok "stop with a failing pgrep answers unknown" || no "stop with a failing pgrep (got: '$out')"
sleep 0.5
kill -0 "$OURS" 2>/dev/null && ok "and ends nothing, not even ours" || no "and ends nothing, not even ours"
run stop --watch "$SESSION" >/dev/null
: > "$ARGV_LOG"

# --- 4. stop with nothing running is not an error ----------------------------
out="$(run stop --watch "$SESSION")"; rc=$?
[[ $rc -eq 0 && "$out" == "not-running" ]] && ok "stop with nothing running: not-running, exit 0" || no "stop with nothing running (got: rc=$rc '$out')"
[[ "$(run status --watch "$SESSION")" == "not-running" ]] && ok "status reports not-running" || no "status reports not-running"
kill -0 "$OTHER_CAF" 2>/dev/null && ok "still: another session's caffeinate is left alone" || no "still: another session's caffeinate is left alone"

# --- 4b. a caffeinate that died is relaunched by the next start -----------
out="$(run start --watch "$SESSION")"; C1="${out#started }"; PIDS+=("$C1")
kill "$C1"; wait "$C1" 2>/dev/null; sleep 0.2
out="$(run start --watch "$SESSION")"; C2="${out#started }"; PIDS+=("$C2")
[[ "$out" =~ ^started\ [0-9]+$ && "$C2" != "$C1" ]] && kill -0 "$C2" 2>/dev/null && ok "start after ours died launches a new one" || no "start after ours died (got: '$out')"
[[ "$(count_ours "$SESSION")" == "1" ]] && ok "and exactly one is running" || no "and exactly one is running ($(count_ours "$SESSION"))"
run stop --watch "$SESSION" >/dev/null

# --- 5. usage errors ---------------------------------------------------------
run start --watch abc >/dev/null 2>&1; rc=$?
[[ $rc -eq 2 ]] && ok "non-numeric --watch exits 2" || no "non-numeric --watch exits 2 (got: $rc)"
run start --watch 1 >/dev/null 2>&1; rc=$?
[[ $rc -eq 2 ]] && ok "--watch 1 (launchd) exits 2" || no "--watch 1 exits 2 (got: $rc)"
run bogus >/dev/null 2>&1; rc=$?
[[ $rc -eq 2 ]] && ok "unknown action exits 2" || no "unknown action exits 2 (got: $rc)"

# --- 6. outside macOS: nothing runs -----------------------------------------
: > "$ARGV_LOG"
out="$(FAKE_UNAME=Linux run start --watch "$SESSION")"; rc=$?
[[ $rc -eq 0 && "$out" == "unsupported" ]] && ok "Linux: unsupported, exit 0" || no "Linux (got: rc=$rc '$out')"
out="$(FAKE_UNAME=Linux run stop --watch "$OTHER_SESSION")"
[[ "$out" == "unsupported" ]] && ok "Linux: stop is unsupported too" || no "Linux: stop (got: '$out')"
kill -0 "$OTHER_CAF" 2>/dev/null && ok "Linux: stop touches nothing" || no "Linux: stop touches nothing"

# --- 7. macOS with no caffeinate in PATH ------------------------------------
NOCAF="$TMP/nocaf"
mkdir -p "$NOCAF"
for tool in bash ps awk sed tr kill basename dirname pgrep pkill id nohup; do
  p="$(command -v "$tool" 2>/dev/null)" && [[ "$p" == /* ]] && ln -sf "$p" "$NOCAF/$tool"
done
ln -sf "$TMP/bin/uname" "$NOCAF/uname"
out="$(PATH="$NOCAF" "$NOCAF/bash" "$SCRIPT" start --watch "$SESSION")"; rc=$?
[[ $rc -eq 0 && "$out" == "unsupported" ]] && ok "no caffeinate: unsupported, exit 0" || no "no caffeinate (got: rc=$rc '$out')"
[[ ! -s "$ARGV_LOG" ]] && ok "unsupported: caffeinate never ran" || no "unsupported: caffeinate never ran"

# --- 8. no session to watch -------------------------------------------------
out="$(KEEP_AWAKE_SESSION_COMM=no-such-session-process run start)"; rc=$?
[[ $rc -eq 0 && "$out" == "no-session" ]] && ok "no session: no-session, exit 0" || no "no session (got: rc=$rc '$out')"
sleep 0 & DEAD=$!; wait "$DEAD" 2>/dev/null
out="$(CLAUDE_PID="$DEAD" KEEP_AWAKE_SESSION_COMM=no-such-session-process run start)"
[[ "$out" == "no-session" ]] && ok "a dead CLAUDE_PID is not a session" || no "a dead CLAUDE_PID (got: '$out')"
[[ ! -s "$ARGV_LOG" ]] && ok "no session: caffeinate never ran" || no "no session: caffeinate never ran"

# --- 9. CLAUDE_PID is the session; when it ends, caffeinate ends ------------
sleep 300 & SESSION2=$!; PIDS+=("$SESSION2")
out="$(CLAUDE_PID="$SESSION2" run start)"
CAF3="${out#started }"; PIDS+=("$CAF3")
for _ in 1 2 3 4 5 6 7 8 9 10; do [[ "$(tail -1 "$ARGV_LOG")" == "-i -w $SESSION2" ]] && break; sleep 0.1; done
[[ "$out" =~ ^started\ [0-9]+$ && "$(tail -1 "$ARGV_LOG")" == "-i -w $SESSION2" ]] && ok "CLAUDE_PID is used as the session" || no "CLAUDE_PID is used as the session (got: '$out')"
kill "$SESSION2"; wait "$SESSION2" 2>/dev/null
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do kill -0 "$CAF3" 2>/dev/null || break; sleep 0.2; done
kill -0 "$CAF3" 2>/dev/null && no "caffeinate ends with its session (-w)" || ok "caffeinate ends with its session (-w)"

# --- 10. the ancestor walk finds the named session process ------------------
SELF_COMM="$(ps -o comm= -p $$ | sed 's#.*/##; s/^-//')"
out="$(KEEP_AWAKE_SESSION_COMM="$SELF_COMM" run status)"
[[ "$out" == "not-running" ]] && ok "ancestor walk resolves a session" || no "ancestor walk resolves a session (got: '$out')"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
