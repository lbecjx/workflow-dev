#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code and OpenCode
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Tests for plugin-update-check.sh. No real network: WD_PLUGIN_MANIFEST_URL
# points at local file:// fixtures, which curl reads like any other URL. A
# fake cache root and TMPDIR keep every run isolated from the real
# ~/.claude/plugins/cache and the real update-check state, and from each
# other — each case gets its own state dir so an earlier case's "notified"
# marker can never leak into a later one.
#
#   bash scripts/plugin-update-check.test.sh

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/plugin-update-check.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok() { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }

# A fake plugin root with a skills/plan directory (so the "is this one of our
# skills" check passes) and its own copy of the script, mirroring the real
# layout: <cache-root>/<version>/{scripts,skills,.claude-plugin}.
CACHE="$TMP/cache"
mk_version() { # $1 = version, writes <cache>/<version>/.claude-plugin/plugin.json + skills/plan + scripts/
  local v="$1" dir="$CACHE/$1"
  mkdir -p "$dir/.claude-plugin" "$dir/skills/plan" "$dir/scripts"
  printf '{"version":"%s"}' "$v" > "$dir/.claude-plugin/plugin.json"
  cp "$SCRIPT" "$dir/scripts/plugin-update-check.sh"
}

mk() { printf '{"tool_input":{},"skill":"%s","session_id":"%s"}' "${2:-plan}" "${1:-s1}"; }

# run <running-version> <latest-json-fixture-content> <state-dir> [session-id] [skill] [mode]
run() {
  local running="$1" latest_body="$2" state="$3" sid="${4:-s1}" skill="${5:-plan}" mode="${6:-}"
  local manifest="$TMP/manifest-$RANDOM.json"
  printf '%s' "$latest_body" > "$manifest"
  mkdir -p "$state"
  ( cd "$HERE" && TMPDIR="$state" WD_PLUGIN_CACHE_ROOT="$CACHE" WD_PLUGIN_MANIFEST_URL="file://$manifest" \
    bash -c 'printf "%s" "$1" | bash "$2" '"$mode" _ "$(mk "$sid" "$skill")" "$CACHE/$running/scripts/plugin-update-check.sh" )
}

mk_version "1.0.0"
mk_version "1.1.0"

# --- 1: behind — on-disk (1.1.0) is not the latest (1.2.0) ------------------
OUT=$(run "1.0.0" '{"version":"1.2.0"}' "$TMP/st1" "sA")
case "$OUT" in
  *"1.0.0"*"1.2.0"*"claude plugin update workflow-dev"*"restart"*) ok "behind: names both versions, the command, and restart" ;;
  *) no "behind: names both versions, the command, and restart (got: $OUT)" ;;
esac

# --- 2: updated but not restarted — on-disk (1.1.0) ahead of running (1.0.0),
# and on-disk already is the latest -----------------------------------------
OUT=$(run "1.0.0" '{"version":"1.1.0"}' "$TMP/st2" "sB")
case "$OUT" in
  *"1.1.0"*"1.0.0"*"Restart"*) [[ "$OUT" != *"claude plugin update"* ]] && ok "updated-not-restarted: no update command, just restart" || no "updated-not-restarted: no update command, just restart (got: $OUT)" ;;
  *) no "updated-not-restarted: no update command, just restart (got: $OUT)" ;;
esac

# --- 3: running is already the latest — silent ------------------------------
OUT=$(run "1.1.0" '{"version":"1.1.0"}' "$TMP/st3" "sC")
[[ -z "$OUT" ]] && ok "already latest → silent" || no "already latest → silent (got: $OUT)"

# --- 4: second call, same session, same state → silent ----------------------
STATE="$TMP/st4"
OUT1=$(run "1.0.0" '{"version":"1.2.0"}' "$STATE" "sD")
OUT2=$(run "1.0.0" '{"version":"1.2.0"}' "$STATE" "sD")
[[ -n "$OUT1" ]] && ok "first call in a session → notifies" || no "first call in a session → notifies"
[[ -z "$OUT2" ]] && ok "second call, same session, same state → silent" || no "second call, same session, same state → silent (got: $OUT2)"

# --- 5: a different session is notified independently -----------------------
OUT3=$(run "1.0.0" '{"version":"1.2.0"}' "$STATE" "sE")
[[ -n "$OUT3" ]] && ok "a different session, same state → notifies again" || no "a different session, same state → notifies again"

# --- 6: the cache is actually used — a broken URL on the second call still
# reports correctly, because the first call already cached "latest" ---------
STATE6="$TMP/st6"
mkdir -p "$STATE6"
MANIFEST6="$TMP/manifest6.json"
printf '{"version":"1.2.0"}' > "$MANIFEST6"
( cd "$HERE" && TMPDIR="$STATE6" WD_PLUGIN_CACHE_ROOT="$CACHE" WD_PLUGIN_MANIFEST_URL="file://$MANIFEST6" \
  bash -c 'printf "%s" "$1" | bash "$2" --message' _ "$(mk sF)" "$CACHE/1.0.0/scripts/plugin-update-check.sh" ) >/dev/null
OUT=$( cd "$HERE" && TMPDIR="$STATE6" WD_PLUGIN_CACHE_ROOT="$CACHE" WD_PLUGIN_MANIFEST_URL="file:///does/not/exist.json" \
  bash -c 'printf "%s" "$1" | bash "$2" --message' _ "$(mk sG)" "$CACHE/1.0.0/scripts/plugin-update-check.sh" )
case "$OUT" in
  *"1.2.0"*) ok "a fresh cache is used instead of re-fetching (broken URL, still correct)" ;;
  *) no "a fresh cache is used instead of re-fetching (got: $OUT)" ;;
esac

# --- 7: curl failing / no manifest at all → silent, not an error ------------
STATE7="$TMP/st7"
mkdir -p "$STATE7"
OUT=$( cd "$HERE" && TMPDIR="$STATE7" WD_PLUGIN_CACHE_ROOT="$CACHE" WD_PLUGIN_MANIFEST_URL="file:///does/not/exist.json" \
  bash -c 'printf "%s" "$1" | bash "$2" --message; echo "EXIT=$?"' _ "$(mk sH)" "$CACHE/1.0.0/scripts/plugin-update-check.sh" )
case "$OUT" in
  "EXIT=0") ok "no manifest reachable → silent, exit 0" ;;
  *) no "no manifest reachable → silent, exit 0 (got: $OUT)" ;;
esac

# --- 8: a garbage response → silent, not an error ---------------------------
STATE8="$TMP/st8"
mkdir -p "$STATE8"
GARBAGE="$TMP/garbage.json"
printf 'not json at all, just prose' > "$GARBAGE"
OUT=$( cd "$HERE" && TMPDIR="$STATE8" WD_PLUGIN_CACHE_ROOT="$CACHE" WD_PLUGIN_MANIFEST_URL="file://$GARBAGE" \
  bash -c 'printf "%s" "$1" | bash "$2" --message; echo "EXIT=$?"' _ "$(mk sI)" "$CACHE/1.0.0/scripts/plugin-update-check.sh" )
case "$OUT" in
  "EXIT=0") ok "a garbage manifest response → silent, exit 0" ;;
  *) no "a garbage manifest response → silent, exit 0 (got: $OUT)" ;;
esac

# --- 9: a skill that isn't this plugin's → silent, regardless of version ----
OUT=$(run "1.0.0" '{"version":"1.2.0"}' "$TMP/st9" "sJ" "caveman")
[[ -z "$OUT" ]] && ok "a skill that isn't this plugin's → silent" || no "a skill that isn't this plugin's → silent (got: $OUT)"

# --- 10: hook mode and --expansion mode carry the same text, each in its own
# envelope, with no permissionDecision field (never an ask/block) -----------
STATE10="$TMP/st10"
M10="$TMP/manifest10.json"
printf '{"version":"1.2.0"}' > "$M10"
HOOK_JSON=$( cd "$HERE" && TMPDIR="$STATE10" WD_PLUGIN_CACHE_ROOT="$CACHE" WD_PLUGIN_MANIFEST_URL="file://$M10" \
  bash -c 'printf "%s" "$1" | bash "$2"' _ "$(mk sK)" "$CACHE/1.0.0/scripts/plugin-update-check.sh" )
case "$HOOK_JSON" in
  *'"hookEventName":"PreToolUse"'*'"additionalContext"'*) ok "hook mode: additionalContext envelope" ;;
  *) no "hook mode: additionalContext envelope (got: $HOOK_JSON)" ;;
esac
[[ "$HOOK_JSON" != *'"permissionDecision"'* ]] && ok "hook mode: never a permissionDecision (informational only, AC #4)" || no "hook mode: never a permissionDecision (got: $HOOK_JSON)"

rm -rf "$CACHE/1.0.0/scripts" && mkdir -p "$CACHE/1.0.0/scripts" && cp "$SCRIPT" "$CACHE/1.0.0/scripts/plugin-update-check.sh"
STATE10B="$TMP/st10b"
EXP_JSON=$( cd "$HERE" && TMPDIR="$STATE10B" WD_PLUGIN_CACHE_ROOT="$CACHE" WD_PLUGIN_MANIFEST_URL="file://$M10" \
  bash -c 'printf "%s" "$1" | bash "$2" --expansion' _ "$(mk sL)" "$CACHE/1.0.0/scripts/plugin-update-check.sh" )
case "$EXP_JSON" in
  *'"hookEventName":"UserPromptExpansion"'*'"additionalContext"'*) ok "--expansion mode: additionalContext envelope" ;;
  *) no "--expansion mode: additionalContext envelope (got: $EXP_JSON)" ;;
esac

# --- 11: an orphaned cache folder is not counted as "on disk" ---------------
# Claude Code marks a no-longer-current cache folder with its own
# `.orphaned_at` file. A higher-versioned orphan used to produce a false
# "already updated, just restart" notice that a restart could never clear.
# Isolated cache root: the shared $CACHE already has a non-orphaned 1.1.0 from
# earlier cases, which would mask what this case is actually testing.
CACHE11="$TMP/cache11"
mkdir -p "$CACHE11/1.0.0/.claude-plugin" "$CACHE11/1.0.0/skills/plan" "$CACHE11/1.0.0/scripts"          "$CACHE11/1.24.0/.claude-plugin" "$CACHE11/1.24.0/skills/plan"
printf '{"version":"1.0.0"}' > "$CACHE11/1.0.0/.claude-plugin/plugin.json"
printf '{"version":"1.24.0"}' > "$CACHE11/1.24.0/.claude-plugin/plugin.json"
cp "$SCRIPT" "$CACHE11/1.0.0/scripts/plugin-update-check.sh"
: > "$CACHE11/1.24.0/.orphaned_at"
MF11="$TMP/manifest11.json"
printf '{"version":"1.0.0"}' > "$MF11"
OUT=$( cd "$HERE" && TMPDIR="$TMP/st11" WD_PLUGIN_CACHE_ROOT="$CACHE11" WD_PLUGIN_MANIFEST_URL="file://$MF11"   bash -c 'printf "%s" "$1" | bash "$2" --message' _ "$(mk sM)" "$CACHE11/1.0.0/scripts/plugin-update-check.sh" )
[[ -z "$OUT" ]] && ok "an orphaned, higher-versioned folder is not 'on disk' → silent" || no "an orphaned, higher-versioned folder is not 'on disk' → silent (got: $OUT)"
# A real behind case still fires, with the right advice, when the only
# higher version present is the orphan (nothing was really installed there).
MF11B="$TMP/manifest11b.json"
printf '{"version":"1.24.0"}' > "$MF11B"
OUT=$( cd "$HERE" && TMPDIR="$TMP/st11b" WD_PLUGIN_CACHE_ROOT="$CACHE11" WD_PLUGIN_MANIFEST_URL="file://$MF11B"   bash -c 'printf "%s" "$1" | bash "$2" --message' _ "$(mk sN)" "$CACHE11/1.0.0/scripts/plugin-update-check.sh" )
case "$OUT" in
  *"claude plugin update workflow-dev"*) ok "an orphan never masks a real 'behind' case" ;;
  *) no "an orphan never masks a real 'behind' case (got: $OUT)" ;;
esac

# --- 12: a failed fetch is throttled too, not just a successful one --------
# A broken URL on the first call must not be retried on the very next call —
# otherwise an unreachable network costs the full curl timeout on every skill
# invocation instead of being throttled the way a success is.
STATE12="$TMP/st12"
mkdir -p "$STATE12"
BROKEN="file:///does/not/exist/plugin-update-check-$RANDOM.json"
( cd "$HERE" && TMPDIR="$STATE12" WD_PLUGIN_CACHE_ROOT="$CACHE" WD_PLUGIN_MANIFEST_URL="$BROKEN" \
  bash -c 'printf "%s" "$1" | bash "$2" --message' _ "$(mk sO)" "$CACHE/1.0.0/scripts/plugin-update-check.sh" ) >/dev/null
[[ -f "$STATE12/workflow-dev-update-check/last-failed-fetch" ]] && ok "a failed fetch leaves a throttle marker" || no "a failed fetch leaves a throttle marker"
# A manifest fixed afterward is still not re-fetched within the failure TTL.
GOODM="$TMP/manifest12.json"
printf '{"version":"1.2.0"}' > "$GOODM"
OUT=$( cd "$HERE" && TMPDIR="$STATE12" WD_PLUGIN_CACHE_ROOT="$CACHE" WD_PLUGIN_MANIFEST_URL="file://$GOODM" \
  bash -c 'printf "%s" "$1" | bash "$2" --message' _ "$(mk sP)" "$CACHE/1.0.0/scripts/plugin-update-check.sh" )
[[ -z "$OUT" ]] && ok "a recent fetch failure is not immediately retried" || no "a recent fetch failure is not immediately retried (got: $OUT)"

# --- 13: an unwritable/unusable state dir degrades silently, no stderr ------
STATE13="$TMP/st13-blocker"
printf 'not a directory' > "$STATE13"
MOK="$TMP/manifest13.json"
printf '{"version":"1.2.0"}' > "$MOK"
ERR13="$TMP/st13.err"
RAW=$( cd "$HERE" && TMPDIR="$STATE13" WD_PLUGIN_CACHE_ROOT="$CACHE" WD_PLUGIN_MANIFEST_URL="file://$MOK" ERRFILE="$ERR13" \
  bash -c 'printf "%s" "$1" | bash "$2" --message 2>"$ERRFILE"; echo "RC=$?"' _ "$(mk sQ)" "$CACHE/1.0.0/scripts/plugin-update-check.sh" )
case "$RAW" in
  *"claude plugin update workflow-dev"*"RC=0") ok "a file where the state dir belongs → still answers, exit 0" ;;
  *) no "a file where the state dir belongs → still answers, exit 0 (got: $RAW)" ;;
esac
[[ ! -s "$ERR13" ]] && ok "…and writes nothing to stderr" || no "…and writes nothing to stderr (got: $(cat "$ERR13"))"

# --- 14: unset $HOME degrades to 'no on-disk scan', never aborts ------------
ERR14="$TMP/st14.err"
RAW=$( cd "$HERE" && env -u HOME -u WD_PLUGIN_CACHE_ROOT TMPDIR="$TMP/st14" WD_PLUGIN_MANIFEST_URL="file://$MOK" ERRFILE="$ERR14" \
  bash -c 'printf "%s" "$1" | bash "$2" --message 2>"$ERRFILE"; echo "RC=$?"' _ "$(mk sR)" "$CACHE/1.0.0/scripts/plugin-update-check.sh" )
case "$RAW" in
  *"RC=0"*) ok "unset \$HOME → exit 0, not an abort" ;;
  *) no "unset \$HOME → exit 0, not an abort (got: $RAW)" ;;
esac
[[ ! -s "$ERR14" ]] && ok "…and no 'unbound variable' on stderr" || no "…and no 'unbound variable' on stderr (got: $(cat "$ERR14"))"

# --- 15: a future fetchedAt is rejected, not trusted as fresh forever -------
STATE15="$TMP/st15"
mkdir -p "$STATE15/workflow-dev-update-check"
printf '{"version":"1.0.0","fetchedAt":9999999999}' > "$STATE15/workflow-dev-update-check/latest.json"
BROKEN15="file:///does/not/exist/plugin-update-check-$RANDOM.json"
OUT=$( cd "$HERE" && TMPDIR="$STATE15" WD_PLUGIN_CACHE_ROOT="$CACHE" WD_PLUGIN_MANIFEST_URL="$BROKEN15" \
  bash -c 'printf "%s" "$1" | bash "$2" --message' _ "$(mk sS)" "$CACHE/1.0.0/scripts/plugin-update-check.sh" )
# The planted cache is rejected, so it falls through to the broken URL and
# stays quiet — but it must NOT have silently trusted the planted "1.0.0" as
# fresh (which would have hidden a real update forever).
[[ -z "$OUT" ]] && ok "a future-dated cache entry is rejected (falls through to a fresh fetch attempt)" || no "a future-dated cache entry is rejected (got: $OUT)"

# --- 16: a leading-zero cache-folder version never reaches bash arithmetic
# as octal, and never prints to stderr -------------------------------------
mk_version "1.08.0"
ERR16="$TMP/st16.err"
OUT=$( cd "$HERE" && TMPDIR="$TMP/st16" WD_PLUGIN_CACHE_ROOT="$CACHE" WD_PLUGIN_MANIFEST_URL="file://$MOK" ERRFILE="$ERR16" \
  bash -c 'printf "%s" "$1" | bash "$2" --message 2>"$ERRFILE"' _ "$(mk sT)" "$CACHE/1.0.0/scripts/plugin-update-check.sh" )
[[ ! -s "$ERR16" ]] && ok "a leading-zero version in a cache folder name → no stderr arithmetic error" || no "a leading-zero version in a cache folder name → no stderr arithmetic error (got: $(cat "$ERR16"))"

# --- 17: without a session id, the notify key rotates with the cache TTL,
# instead of a bare literal that never expired ------------------------------
STATE17="$TMP/st17"
PAYLOAD_NOSID='{"tool_input":{},"skill":"plan"}'
( cd "$HERE" && TMPDIR="$STATE17" WD_PLUGIN_CACHE_ROOT="$CACHE" WD_PLUGIN_MANIFEST_URL="file://$MOK" \
  bash -c 'printf "%s" "$1" | bash "$2" --message' _ "$PAYLOAD_NOSID" "$CACHE/1.0.0/scripts/plugin-update-check.sh" ) >/dev/null
NOTIFIED_CONTENT="$(cat "$STATE17/workflow-dev-update-check/notified" 2>/dev/null)"
case "$NOTIFIED_CONTENT" in
  "window|"*) no "no-session-id key rotates with the TTL window, not a bare literal (got: $NOTIFIED_CONTENT)" ;;
  "window-"*) ok "no-session-id key is bucketed by the TTL window, not a bare literal that never expires" ;;
  *) no "no-session-id key is bucketed by the TTL window (got: $NOTIFIED_CONTENT)" ;;
esac

# --- 18: the notified-key match is exact, not a substring -------------------
STATE18="$TMP/st18"
mkdir -p "$STATE18/workflow-dev-update-check"
printf 'sX|behind|1.2.1|1.0.0\n' > "$STATE18/workflow-dev-update-check/notified"
M18="$TMP/manifest18.json"
printf '{"version":"1.2.10"}' > "$M18"
OUT=$( cd "$HERE" && TMPDIR="$STATE18" WD_PLUGIN_CACHE_ROOT="$CACHE" WD_PLUGIN_MANIFEST_URL="file://$M18" \
  bash -c 'printf "%s" "$1" | bash "$2" --message' _ "$(mk sX)" "$CACHE/1.0.0/scripts/plugin-update-check.sh" )
[[ -n "$OUT" ]] && ok "a stored key is not a false-positive substring match for a similar, longer key" || no "a stored key is not a false-positive substring match for a similar, longer key (got: $OUT)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
exit $((fail == 0 ? 0 : 1))
