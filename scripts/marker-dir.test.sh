#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Tests for marker-dir.sh — the one owner of the marker directory's path, its
# permissions and its trust check (WD-0027). The two hook suites pin what the
# *hooks* do with an untrusted directory; this suite pins the helper itself, so
# the rule has one place to fail rather than three.
#
# What it pins:
#   - the path is built in exactly one place (`marker_root` / `marker_subdir`);
#   - `marker_ensure_dir` creates mode 700 (never the umask default);
#   - `marker_dir_reason` is empty for a missing or private directory, and names
#     the reason for a symlink, a non-directory, and a group/world-writable one;
#   - `marker_write` writes mode 600 through a temp file, and a symlink planted
#     at the target name is replaced, never followed;
#   - the mode check **fails closed** when it cannot run at all.
#
#   bash scripts/marker-dir.test.sh

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=marker-dir.sh
source "$HERE/marker-dir.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok() { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }

# BSD `stat -f %Lp` and GNU `stat -c %a` disagree; try each and keep whichever
# answers an octal mode, the same portability rule marker-dir.sh follows.
mode_of() {
  local m
  m="$(stat -f '%Lp' "$1" 2>/dev/null)" && [[ "$m" =~ ^[0-7]+$ ]] && { printf '%s' "$m"; return 0; }
  stat -c '%a' "$1" 2>/dev/null
}

# Everything happens under a throwaway TMPDIR — the live marker store is never
# read or written, and `marker_root` is exercised through its real lookup.
export TMPDIR="$TMP/tmpdir"
mkdir -p "$TMPDIR"

ROOT="$(marker_root)"
[[ "$ROOT" == "$TMPDIR/workflow-dev-validate" ]] \
  && ok "marker_root resolves under TMPDIR" || no "marker_root resolves under TMPDIR (got: $ROOT)"
[[ "$(marker_subdir)" == "$ROOT/messages" ]] \
  && ok "marker_subdir is <root>/messages" || no "marker_subdir is <root>/messages (got: $(marker_subdir))"

# --- a missing directory is trusted: "no directory" means "no markers" -------
[[ -z "$(marker_dir_reason "$ROOT")" ]] \
  && ok "a missing directory is trusted (no marker can exist)" || no "a missing directory is trusted (got: $(marker_dir_reason "$ROOT"))"

# --- creation: mode 700, root and messages ----------------------------------
marker_ensure_dir "$ROOT" || no "marker_ensure_dir creates the root"
[[ -d "$ROOT" ]] && ok "the root exists after marker_ensure_dir" || no "the root exists after marker_ensure_dir"
[[ "$(mode_of "$ROOT")" == "700" ]] && ok "the root is created mode 700" || no "the root is created mode 700 (got: $(mode_of "$ROOT"))"
marker_ensure_dir "$(marker_subdir)" || no "marker_ensure_dir creates messages/"
[[ "$(mode_of "$(marker_subdir)")" == "700" ]] && ok "messages/ is created mode 700" || no "messages/ is created mode 700 (got: $(mode_of "$(marker_subdir)"))"
[[ -z "$(marker_dir_reason "$ROOT")" ]] && ok "a private directory is trusted" || no "a private directory is trusted (got: $(marker_dir_reason "$ROOT"))"

# --- creating under a world-writable TMPDIR still works ---------------------
# On Linux with no TMPDIR the store's parent is /tmp (mode 1777); creating the
# store there must not be refused, because the boundary this story draws starts
# at the store itself, never at its parent. A check that walked one level too
# far would fail closed on every shared-temp host.
SHARED="$TMP/shared"
mkdir -p "$SHARED"; chmod 1777 "$SHARED"
# `export TMPDIR=…` inside the subshell, not a `TMPDIR=… cmd` prefix: a prefix
# assignment is not visible to the `$(marker_root)` expansion in the argument,
# which would quietly resolve the *old* TMPDIR and make this vacuous.
( export TMPDIR="$SHARED"; marker_ensure_dir "$(marker_root)" ) || no "marker_ensure_dir creates the store under a world-writable parent"
[[ "$(mode_of "$SHARED/workflow-dev-validate")" == "700" ]] \
  && ok "the store is created mode 700 under a world-writable parent" \
  || no "the store is created mode 700 under a world-writable parent (got: $(mode_of "$SHARED/workflow-dev-validate"))"
( export TMPDIR="$SHARED"; marker_ensure_dir "$(marker_subdir)" ) \
  && ok "…and messages/ is created under it too" \
  || no "…and messages/ is created under it too"

# --- reasons: world-writable, symlink, not-a-directory ----------------------
WORLD="$TMP/world"
mkdir -p "$WORLD"; chmod 777 "$WORLD"
case "$(marker_dir_reason "$WORLD")" in
  *"group- or world-writable"*) ok "a world-writable directory is not trusted, and says why" ;;
  *) no "a world-writable directory is not trusted (got: $(marker_dir_reason "$WORLD"))" ;;
esac

LINK="$TMP/link-to-trusted"
ln -s "$ROOT" "$LINK"
case "$(marker_dir_reason "$LINK")" in
  *"symlink"*) ok "a symlinked directory is not trusted, and says why" ;;
  *) no "a symlinked directory is not trusted (got: $(marker_dir_reason "$LINK"))" ;;
esac

NOTDIR="$TMP/regular-file"
printf 'x\n' > "$NOTDIR"
case "$(marker_dir_reason "$NOTDIR")" in
  *"not a directory"*) ok "a regular file in the path is not trusted, and says why" ;;
  *) no "a regular file in the path is not trusted (got: $(marker_dir_reason "$NOTDIR"))" ;;
esac

# --- marker_ensure_dir refuses an untrustworthy existing directory ----------
marker_ensure_dir "$WORLD" 2>/dev/null && no "marker_ensure_dir refuses a world-writable directory" || ok "marker_ensure_dir refuses a world-writable directory"
marker_ensure_dir "$LINK" 2>/dev/null && no "marker_ensure_dir refuses a symlinked directory" || ok "marker_ensure_dir refuses a symlinked directory"

# --- marker_write: mode 600, via a temp file --------------------------------
MARK="$ROOT/body.json"
printf '{"diffHash":"abc"}' | marker_write "$MARK" || no "marker_write writes"
[[ "$(cat "$MARK" 2>/dev/null)" == '{"diffHash":"abc"}' ]] && ok "marker_write stores the piped content" || no "marker_write stores the piped content (got: $(cat "$MARK" 2>/dev/null))"
[[ "$(mode_of "$MARK")" == "600" ]] && ok "a written marker is mode 600" || no "a written marker is mode 600 (got: $(mode_of "$MARK"))"
if compgen -G "$ROOT/.body.json.*" >/dev/null; then
  no "marker_write leaves no temp file behind"
else
  ok "marker_write leaves no temp file behind"
fi

# --- marker_write refuses an untrustworthy directory ------------------------
printf 'x' | marker_write "$WORLD/planted.json" 2>/dev/null && no "marker_write refuses a world-writable directory" || ok "marker_write refuses a world-writable directory"
[[ -e "$WORLD/planted.json" ]] && no "nothing landed in the untrusted directory" || ok "nothing landed in the untrusted directory"

# --- a symlink planted at the target name is replaced, never followed -------
# The reason write is mktemp+mv and not `>`: `>` would write through the link
# into the victim file, which is exactly the redirect a shared /tmp allows.
VICTIM="$TMP/victim"
printf 'ORIGINAL' > "$VICTIM"
PLANTED="$ROOT/planted-name.json"
ln -s "$VICTIM" "$PLANTED"
printf 'NEW' | marker_write "$PLANTED" || no "marker_write succeeds over a planted symlink"
[[ "$(cat "$VICTIM")" == "ORIGINAL" ]] && ok "a planted symlink target is not written through" || no "a planted symlink target is not written through (got: $(cat "$VICTIM"))"
[[ ! -L "$PLANTED" && "$(cat "$PLANTED" 2>/dev/null)" == "NEW" ]] \
  && ok "the symlink at the marker name is replaced by the real file" \
  || no "the symlink at the marker name is replaced by the real file"

# A symlink at the target name pointing at a *directory*: `mv` would move the
# temp file inside it and report success, leaving no marker at the name.
LINKED_TARGET="$TMP/linked-target"
mkdir -p "$LINKED_TARGET"
DIR_TARGET="$ROOT/dir-target.json"
ln -s "$LINKED_TARGET" "$DIR_TARGET"
printf 'x' | marker_write "$DIR_TARGET" 2>/dev/null \
  && no "marker_write refuses a target symlinked to a directory" \
  || ok "marker_write refuses a target symlinked to a directory"
[[ -z "$(ls -A "$LINKED_TARGET")" ]] \
  && ok "nothing was moved into the linked directory" \
  || no "nothing was moved into the linked directory"

# A non-regular, non-symlink target (a FIFO) is refused too — `mv` would replace
# it, but a marker written through a pipe name is not a marker.
if command -v mkfifo >/dev/null 2>&1; then
  FIFO="$ROOT/fifo.json"
  mkfifo "$FIFO"
  printf 'x' | marker_write "$FIFO" 2>/dev/null \
    && no "marker_write refuses a non-regular target" \
    || ok "marker_write refuses a non-regular target"
  rm -f "$FIFO"
fi

# A failed `mv` leaves no temp file behind (the cleanup branch). An immutable
# target makes `mv` fail; chflags is BSD-only, so skip where it isn't there.
if command -v chflags >/dev/null 2>&1; then
  IMMUT="$ROOT/immutable.json"
  printf 'keep' > "$IMMUT"
  chflags uchg "$IMMUT"
  printf 'new' | marker_write "$IMMUT" 2>/dev/null \
    && no "marker_write reports failure when mv fails" \
    || ok "marker_write reports failure when mv fails"
  chflags nouchg "$IMMUT"
  [[ "$(cat "$IMMUT")" == "keep" ]] && ok "a failed write leaves the target untouched" || no "a failed write leaves the target untouched"
  if compgen -G "$ROOT/.immutable.json.*" >/dev/null; then
    no "a failed mv leaves no temp file behind"
  else
    ok "a failed mv leaves no temp file behind"
  fi
fi

# --- marker_trust_note: one wording, and JSON-safe quoting ------------------
NOTE="$(marker_trust_note 'the store is group- or world-writable')"
case "$NOTE" in
  *"cannot be trusted"*"the store is group- or world-writable"*) ok "the note carries the reason" ;;
  *) no "the note carries the reason (got: $NOTE)" ;;
esac
[[ -z "$(marker_trust_note '')" ]] && ok "no reason → no note" || no "no reason → no note (got: $(marker_trust_note ''))"
ES_WRAP=' (No se puede confiar en el directorio de marcadores: %s.)'
case "$(marker_trust_note 'the store is group- or world-writable' "$ES_WRAP")" in
  " (No se puede confiar en el directorio de marcadores: the store is group- or world-writable.)") ok "a translated wrapper is used, the reason unchanged" ;;
  *) no "a translated wrapper is used (got: $(marker_trust_note 'x' "$ES_WRAP"))" ;;
esac
[[ "$(marker_trust_note 'r' '')" == "$(marker_trust_note 'r')" ]] && ok "an empty wrapper keeps the English one" || no "an empty wrapper keeps the English one"
[[ -z "$(marker_trust_note '' "$ES_WRAP")" ]] && ok "no reason → no note, in any language" || no "no reason → no note, in any language"
SAFE_ES="$(marker_trust_note "$(printf 'p"q\\r\ts')" "$ES_WRAP")"
case "$SAFE_ES" in *'"'*|*'\'*|*$'\t'*) no "a translated note is still sanitized" ;; *) ok "a translated note is still sanitized" ;; esac

# A reason is built from `$TMPDIR`, and hook mode embeds the note in a JSON
# string — so a quote, a backslash, or any control character must not survive.
HOSTILE="$(printf 'p"q\\r\ts\nt')"
SAFE="$(marker_trust_note "$HOSTILE")"
bad=0
case "$SAFE" in *'"'*) bad=1 ;; esac
case "$SAFE" in *'\'*) bad=1 ;; esac
case "$SAFE" in *$'\t'*) bad=1 ;; esac
case "$SAFE" in *$'\n'*) bad=1 ;; esac
[[ $bad -eq 0 ]] && ok "the note drops quotes, backslashes and control characters" || no "the note drops quotes, backslashes and control characters (got: $SAFE)"

# --- a writable parent is not hidden by a private child ---------------------
# The messages store is where this matters: a 700 `messages/` under a 777 root
# can be renamed away and swapped wholesale, so the parent is part of the
# decision, not just the leaf.
chmod 777 "$ROOT"
case "$(marker_chain_reason "$(marker_subdir)")" in
  *"group- or world-writable"*) ok "a private child under a writable parent is not trusted" ;;
  *) no "a private child under a writable parent is not trusted (got: $(marker_chain_reason "$(marker_subdir)"))" ;;
esac
marker_ensure_dir "$(marker_subdir)" 2>/dev/null && no "marker_ensure_dir refuses a private child under a writable root" || ok "marker_ensure_dir refuses a private child under a writable root"
printf 'x' | marker_write "$(marker_subdir)/planted.json" 2>/dev/null && no "marker_write refuses a private child under a writable root" || ok "marker_write refuses a private child under a writable root"
[[ -e "$(marker_subdir)/planted.json" ]] && no "nothing landed under the writable root" || ok "nothing landed under the writable root"
chmod 700 "$ROOT"
[[ -z "$(marker_chain_reason "$(marker_subdir)")" ]] && ok "…and a private root restores trust in the child" || no "…and a private root restores trust in the child"

# --- the mode check fails closed when it cannot run -------------------------
# A host without `find` cannot read the mode; the safe direction is to report
# the directory untrustworthy (ask) rather than trust what was never checked.
# bash is called by absolute path: `PATH=… bash` looks bash up *after* the
# narrowed PATH takes effect, so a bare `bash` would not be found at all.
EMPTY_BIN="$TMP/empty-bin"
mkdir -p "$EMPTY_BIN"
BASH_BIN="$(command -v bash)"
PRIVATE="$TMP/private"
mkdir -p "$PRIVATE"; chmod 700 "$PRIVATE"
FAILED_CLOSED="$( PATH="$EMPTY_BIN" "$BASH_BIN" -c 'source "$1"; marker_dir_reason "$2"' _ "$HERE/marker-dir.sh" "$PRIVATE" 2>/dev/null )"
case "$FAILED_CLOSED" in
  *"group- or world-writable"*) ok "the mode check fails closed when find is unavailable" ;;
  *) no "the mode check fails closed when find is unavailable (got: '$FAILED_CLOSED')" ;;
esac

# Ownership (`-O`) cannot be exercised without a second user (root), so it is
# left to the code path every other case already runs; noted rather than faked.
echo "  note  -O (owned by the current user) is not separately exercisable without root"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
exit $((fail == 0 ? 0 : 1))
