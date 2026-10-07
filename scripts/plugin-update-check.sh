#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code and OpenCode
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Tells the developer, at most once per session per version, when a newer copy
# of this plugin is available — or when it already *is* on disk and only needs
# a session restart (WD-0023's incident: the fix merged, but the running
# session kept the old hooks and still showed the exact question the fix
# removed). Never asks, blocks, or denies — the skill it fires alongside runs
# exactly as it would without this.
#
# Three versions, three questions:
#   running   — what THIS session loaded: this file's own sibling
#               ../.claude-plugin/plugin.json. Only a restart changes this.
#   on-disk   — the highest NON-ORPHANED version `claude plugin update` has
#               already fetched into the cache, whether this session has
#               picked it up or not. Claude Code leaves old cache folders
#               behind and marks a no-longer-current one with its own
#               `.orphaned_at` file; counting those as installed (found live
#               on this very machine: 21 of 22 cached folders carry one) gave
#               a false "just restart" notice that a restart never clears,
#               and could mask a real "behind" case under a downgrade.
#   latest    — what the GitHub repo says right now, fetched over the network
#               and cached for a bounded time so this never costs a request
#               per skill call.
#
#   latest > on-disk           → "behind": name the update command.
#   on-disk > running          → "updated but not restarted": no update
#                                 command, just say to restart.
#   otherwise                  → silent.
#
# Two modes, one owner of the wording:
#   plugin-update-check.sh
#       Claude Code `PreToolUse` (matcher: Skill) — emits additionalContext
#       only, never a permissionDecision: every script in this repo already
#       treats "no JSON on stdout" on this event as "proceed normally," so
#       additionalContext alone is the same family of answer, just with text
#       attached, never a question.
#   plugin-update-check.sh --expansion
#       Claude Code `UserPromptExpansion` — the user typing
#       `/workflow-dev:<skill>` directly, same text, that event's own
#       additionalContext envelope.
#   plugin-update-check.sh --message [payload]
#       Prints the reminder as plain text, nothing otherwise. Not called by
#       any harness today (OpenCode support is out of scope for this check —
#       its update path is a `git pull` in a clone, not `claude plugin
#       update`) — kept anyway so this script's tests, and any future caller,
#       have one place to ask "what would it say" without parsing JSON.
#
# This script does NOT reuse model-tiering-check.sh's "is this one of our
# skills" detection by sourcing it — it duplicates the small check inline so a
# bug here can never touch that already-shipped, stable script, which nothing
# in this story's ACs asks to change.
#
# Every path below that cannot complete confidently is a silent "say nothing,"
# never a loud failure: no curl, no network, a timeout, a response that
# doesn't parse, no $HOME, a state directory it cannot trust or cannot write.
# A version notice that guesses wrong is worse than one that stays quiet.
#
# The state directory is a shared, predictable path (`${TMPDIR:-/tmp}/...`),
# same as this repo's existing validate/message markers. On a host where
# `$TMPDIR` is unset and `/tmp` is shared between users (Linux; macOS's own
# `$TMPDIR` is already per-user, mode 0700), another local user could plant a
# symlink or a fake "latest" there — a cache with a future `fetchedAt` reads
# as fresh forever, which can hide a real update or announce a fake one. This
# script never trusts that directory until it has checked it is a real
# directory it owns and not a symlink; if it isn't, every read/write to it is
# skipped for this run — correctness degrades (no cache, no "once per
# session" throttle, every call re-fetches), nothing is corrupted, and no
# write lands anywhere attacker-chosen. The rest of this plugin's markers
# (`validate-mark-deferred.sh`, `git-message-mark-reviewed.sh`) share the same
# unhardened pattern; WD-0027 tracks hardening them the same way.

set -u

MODE="hook"
PAYLOAD_ARG=""
case "${1:-}" in
  --expansion) MODE="expansion" ;;
  --message) MODE="message"; PAYLOAD_ARG="${2:-}" ;;
esac

quiet() { exit 0; }

if [[ "$MODE" == "message" && -n "$PAYLOAD_ARG" ]]; then
  INPUT="$PAYLOAD_ARG"
else
  INPUT="$(cat)"
fi

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PLUGIN_ROOT="$(cd -P "$HERE/.." && pwd -P)"

# --- Is this even a workflow-dev skill? -------------------------------------
# Same detection model-tiering-check.sh has, kept separate on purpose (see the
# header). The Skill tool's input field name isn't documented, and the two
# events carry the skill's name under different keys, so try the known ones
# and fall back to "does the invocation name one of this plugin's own skills."
json_string() { # $1 = key
  printf '%s' "$INPUT" | grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 | sed -E 's/.*: *"(.*)"/\1/'
}

SKILL="$(json_string skill)"
[[ -z "$SKILL" ]] && SKILL="$(json_string command_name)"
SKILL="${SKILL#workflow-dev:}"
SKILL="${SKILL#workflow-dev-}"

if [[ -z "$SKILL" ]]; then
  for d in "$PLUGIN_ROOT"/skills/*/; do
    name="$(basename "$d")"
    case "$INPUT" in
      *"workflow-dev:$name"*|*"workflow-dev-$name"*) SKILL="$name"; break ;;
    esac
  done
fi

[[ -n "$SKILL" && -d "$PLUGIN_ROOT/skills/$SKILL" ]] || quiet

# --- Versions ----------------------------------------------------------------
read_version() { # $1 = path to a plugin.json
  [[ -f "$1" ]] || return 1
  if command -v jq >/dev/null 2>&1; then
    jq -r '.version // empty' "$1" 2>/dev/null
  else
    grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' "$1" | head -1 | sed -E 's/.*"([^"]*)"$/\1/'
  fi
}

# Three-part numeric compare — "1.9.0" < "1.10.0", which plain string
# comparison gets wrong. Returns 0 (true) when $1 > $2. `10#` forces base-10
# reads: a bare `08`/`09` is otherwise read as octal and errors out under
# `set -u`'s arithmetic (`(( ai > bi ))` on "08"), which would leak to stderr
# despite this script's own silence promise. Semver forbids leading zeros, so
# this only guards against a planted or hand-edited version string, not a
# real one — see the state-directory hardening note above.
version_gt() {
  local a="$1" b="$2" i ai bi
  local -a A B
  IFS='.' read -r -a A <<< "$a"
  IFS='.' read -r -a B <<< "$b"
  for i in 0 1 2; do
    ai="${A[i]:-0}"; bi="${B[i]:-0}"
    [[ "$ai" =~ ^[0-9]+$ ]] || return 1
    [[ "$bi" =~ ^[0-9]+$ ]] || return 1
    (( 10#$ai > 10#$bi )) && return 0
    (( 10#$ai < 10#$bi )) && return 1
  done
  return 1
}

RUNNING="$(read_version "$PLUGIN_ROOT/.claude-plugin/plugin.json")"
[[ -n "$RUNNING" ]] || quiet

# `${HOME:-}` rather than `${HOME:?}`: an unset $HOME used to abort the whole
# script under `set -u` (a real, confirmed path), which is exactly the loud
# failure this file promises never to have. An empty default here just makes
# the on-disk scan find nothing, same as a cache root that doesn't exist.
# Hardcodes this plugin's own marketplace name and repo (lbecjx/workflow-dev,
# branch main, matching fetch_latest below) rather than deriving it from
# $PLUGIN_ROOT or a marketplace manifest — true today (checked against
# ~/.claude/plugins/marketplaces/lbecjx/.claude-plugin/marketplace.json) and
# the one assumption that would need revisiting if this plugin were ever
# republished under a different marketplace name or default branch.
CACHE_ROOT="${WD_PLUGIN_CACHE_ROOT:-${HOME:-}/.claude/plugins/cache/lbecjx/workflow-dev}"
ON_DISK="$RUNNING"
if [[ -n "${HOME:-}" || -n "${WD_PLUGIN_CACHE_ROOT:-}" ]] && [[ -d "$CACHE_ROOT" ]]; then
  for d in "$CACHE_ROOT"/*/; do
    v="$(basename "$d")"
    [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
    # Claude Code marks a cache folder it no longer considers current with its
    # own `.orphaned_at` file — confirmed live on this machine (21 of 22
    # cached workflow-dev folders carry one, only the installed version does
    # not). Counting an orphan as "on disk" gave a false, permanent "just
    # restart" notice for a version that was never really installed.
    [[ -f "${d}.orphaned_at" ]] && continue
    version_gt "$v" "$ON_DISK" && ON_DISK="$v"
  done
fi

# --- The state directory: only trusted if it's ours, and not a symlink -----
# See the header note. A directory someone else created, or a symlink sitting
# where the directory belongs, means every read and write below is skipped —
# this run just answers without a cache or a "notified" record, which costs a
# repeated fetch, never a corrupted file or a write to an attacker's target.
STATE_DIR="${TMPDIR:-/tmp}/workflow-dev-update-check"
mkdir -m 700 -p "$STATE_DIR" 2>/dev/null
STATE_OK=0
[[ -d "$STATE_DIR" && ! -L "$STATE_DIR" && -O "$STATE_DIR" ]] && STATE_OK=1

CACHE_FILE="$STATE_DIR/latest.json"
NOTIFIED_FILE="$STATE_DIR/notified"
TTL_SECONDS=86400   # 24h — a version bump here happens at most a few times a
                    # day; a day-old "latest" is never stale enough to mislead.
FAIL_TTL_SECONDS=1800 # 30m — a failed/unreachable fetch is throttled far
                    # shorter than a successful one, so a real network outage
                    # recovers quickly once it clears, instead of needing a
                    # full day before the next real answer.
FAIL_FILE="$STATE_DIR/last-failed-fetch"

now_epoch() { date -u +%s 2>/dev/null; }

# A numeric field pulled out of our own JSON, defensively: must be digits
# only (no sign, no leading-zero-as-octal surprise once forced through
# `10#`), so a planted or corrupted cache file can't produce an arithmetic
# error here either.
read_epoch() { # $1 = file, $2 = key
  local v
  v="$(grep -o "\"$2\"[[:space:]]*:[[:space:]]*[0-9]*" "$1" 2>/dev/null | grep -o '[0-9]*$')"
  [[ "$v" =~ ^[0-9]+$ ]] && printf '%s' "$v"
}

cache_fresh() {
  [[ "$STATE_OK" -eq 1 && -f "$CACHE_FILE" ]] || return 1
  local fetched now
  fetched="$(read_epoch "$CACHE_FILE" fetchedAt)" || return 1
  [[ -n "$fetched" ]] || return 1
  now="$(now_epoch)" || return 1
  # A `fetchedAt` in the future — clock skew, or planted by another local
  # user sharing an unset `$TMPDIR` — used to read as "fresh" forever, since
  # `now - fetched` only has to be below the TTL, and a negative number
  # always is. Reject it instead of trusting it.
  (( 10#$now >= 10#$fetched )) || return 1
  (( 10#$now - 10#$fetched < TTL_SECONDS ))
}

fetch_recently_failed() {
  [[ "$STATE_OK" -eq 1 && -f "$FAIL_FILE" ]] || return 1
  local failed now
  failed="$(read_epoch "$FAIL_FILE" failedAt)" || return 1
  now="$(now_epoch)" || return 1
  (( 10#$now >= 10#$failed )) || return 1
  (( 10#$now - 10#$failed < FAIL_TTL_SECONDS ))
}

fetch_latest() {
  command -v curl >/dev/null 2>&1 || return 1
  local url="${WD_PLUGIN_MANIFEST_URL:-https://raw.githubusercontent.com/lbecjx/workflow-dev/main/.claude-plugin/plugin.json}"
  curl -fsSL -m 3 "$url" 2>/dev/null
}

# Writes atomically (temp file + rename) and keeps stderr out of the way
# *before* the destination redirect runs — `cmd > file 2>/dev/null` still lets
# the shell's own "file: No such file or directory" reach real stderr if the
# open itself fails, because redirections apply left to right and the first
# one has already failed by the time the second takes effect (confirmed:
# reversing the order makes it silent). A write that can't land (an unwritable
# or vanished state dir) is just skipped, never reported.
atomic_write() { # $1 = destination, $2 = content
  [[ "$STATE_OK" -eq 1 ]] || return 0
  local tmp
  tmp="$(mktemp "$STATE_DIR/.tmp.XXXXXX" 2>/dev/null)" || return 0
  { printf '%s' "$2" > "$tmp"; } 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 0; }
  { mv -f "$tmp" "$1"; } 2>/dev/null || rm -f "$tmp" 2>/dev/null
}

LATEST=""
if cache_fresh; then
  LATEST="$(grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' "$CACHE_FILE" | head -1 | sed -E 's/.*"([^"]*)"$/\1/')"
elif fetch_recently_failed; then
  : # A fetch failed inside the last FAIL_TTL_SECONDS — don't retry yet. This
    # is what keeps an unreachable network from costing the full curl timeout
    # on every single skill call; LATEST stays empty, so this run is quiet.
else
  RAW="$(fetch_latest)" || RAW=""
  LATEST="$(printf '%s' "$RAW" | { command -v jq >/dev/null 2>&1 && jq -r '.version // empty' 2>/dev/null || grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*"([^"]*)"$/\1/'; })"
  if [[ -n "$LATEST" && "$LATEST" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    atomic_write "$CACHE_FILE" "{\"version\":\"$LATEST\",\"fetchedAt\":$(now_epoch)}"
  else
    LATEST=""
    atomic_write "$FAIL_FILE" "{\"failedAt\":$(now_epoch)}"
  fi
fi

[[ -n "$LATEST" && "$LATEST" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || quiet

# --- Decide which case, if any -----------------------------------------------
CASE=""
if version_gt "$LATEST" "$ON_DISK"; then
  CASE="behind"
elif version_gt "$ON_DISK" "$RUNNING"; then
  CASE="updated"
fi
[[ -n "$CASE" ]] || quiet

# --- Notified this session (or this TTL window) for this exact state? -------
# Session identity, if the payload carries one. If it doesn't, the fallback
# key rolls over with the same TTL window the version cache itself uses
# (`now / TTL_SECONDS`, an integer bucket) — not a bare "window" literal, which
# never expired and stayed silent forever past the first notice. Either way:
# never crash on a missing field, never notify on every single skill call.
SESSION_ID="$(json_string session_id)"
if [[ -n "$SESSION_ID" ]]; then
  NOTIFY_SCOPE="$SESSION_ID"
else
  NOW_FOR_BUCKET="$(now_epoch)"
  if [[ "$NOW_FOR_BUCKET" =~ ^[0-9]+$ ]]; then
    NOTIFY_SCOPE="window-$(( 10#$NOW_FOR_BUCKET / TTL_SECONDS ))"
  else
    NOTIFY_SCOPE="window"
  fi
fi
NOTIFY_KEY="$NOTIFY_SCOPE|$CASE|$LATEST|$ON_DISK"

# Exact-line match (`-x`), not substring: a session id that happens to be a
# suffix of an earlier one, or a version string that's a suffix of another
# (`…|1.2.1` inside `…|1.2.10`), must not false-match.
if [[ "$STATE_OK" -eq 1 && -f "$NOTIFIED_FILE" ]] && grep -qxF "$NOTIFY_KEY" "$NOTIFIED_FILE" 2>/dev/null; then
  quiet
fi

# --- Build the text ----------------------------------------------------------
if [[ "$CASE" == "behind" ]]; then
  REMINDER="A newer workflow-dev is available ($RUNNING installed, $LATEST available). Run \`claude plugin update workflow-dev\`, then restart the session to load it."
else
  REMINDER="workflow-dev was already updated to $ON_DISK, but this session is still running $RUNNING. Restart the session to load it — no update command needed."
fi

# Appending still isn't atomic across two truly concurrent invocations in the
# same session (a narrow, confirmed, low-severity race: both can read "not
# notified yet" before either writes) — the worst outcome is one duplicate
# notice, not a corrupted file or a missed one, and isn't worth a cross-
# platform lock for a best-effort "at most once" reminder.
if [[ "$STATE_OK" -eq 1 ]]; then
  { printf '%s\n' "$NOTIFY_KEY" >> "$NOTIFIED_FILE"; } 2>/dev/null
fi

case "$MODE" in
  message)
    printf '%s' "$REMINDER"
    ;;
  expansion)
    REMINDER_JSON="${REMINDER//\\/\\\\}"; REMINDER_JSON="${REMINDER_JSON//\"/\\\"}"
    printf '{"hookSpecificOutput":{"hookEventName":"UserPromptExpansion","additionalContext":"%s"}}' "$REMINDER_JSON"
    ;;
  *)
    REMINDER_JSON="${REMINDER//\\/\\\\}"; REMINDER_JSON="${REMINDER_JSON//\"/\\\"}"
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"%s"}}' "$REMINDER_JSON"
    ;;
esac
exit 0
