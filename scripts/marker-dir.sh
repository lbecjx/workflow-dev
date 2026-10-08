#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# The one owner of the marker directory's path, its permissions and its
# trustworthiness (WD-0027). Sourced, like command-match.sh, so every reader
# and writer of the directory shares byte-identical logic instead of five
# inline copies that are free to drift. A sourced file (not an exec'd CLI)
# is the shape that reaches all five call sites — four `scripts/*.sh` and the
# shell snippet an agent runs out of validate/SKILL.md Step 6 — including the
# two write sides, which need the directory prepared before they can write.
#
# ## What a marker is, and why the directory is the attack surface
#
# A marker is a permission: "this exact diff was validated", "this diff's
# validation was deferred", "this exact commit/PR message was reviewed". If
# one exists for the hash the hook recomputes, the corresponding pre-commit
# gate stays silent instead of asking the human — that is the whole point of
# the marker, and it is also what makes a *planted* marker a way to switch a
# gate off.
#
# The path is fixed and, on a host with no `TMPDIR` (Linux, CI runners,
# multi-user boxes), resolves to the shared `/tmp`. Another local user can
# therefore pre-create the directory, plant a marker for a hash they can
# compute (the repo-path hash is just `shasum` of a known path), or leave a
# symlink at a name a writer would follow. On macOS `TMPDIR` is per-user
# (`/var/folders/…`, mode 700) so the risk there is low — which is why the
# story is Low priority, not why the path is safe.
#
# ## What this file does about it
#
# - **read side** — `marker_dir_reason DIR` says, in one line, why markers
#   under DIR must not be trusted, or nothing when they may be. A caller
#   reads a marker only when that answer is empty; otherwise it behaves as if
#   no marker exists (it *asks*, with the reason attached). It never passes
#   silently on an untrusted directory, and it never denies — a failed trust
#   check is not evidence of an attack, and this plugin's rule is that only
#   the AI-attribution check denies.
# - **write side** — `marker_ensure_dir DIR` creates DIR with mode 700
#   (`umask 077`), or refuses when DIR exists but is untrustworthy;
#   `marker_write FILE` writes stdin through `mktemp` in the same directory
#   followed by `mv`, so a predictable name is never opened for writing and a
#   symlink planted there is never followed (the same pattern, and the same
#   reasoning, as pre-compact-check.sh's `pendingSave` rewrite). A final
#   component that is a directory — including a symlink to one, which `mv`
#   would happily move the temp file *inside* while reporting success — is
#   refused outright.
#
# ## One residual, stated rather than hidden
#
# The read side checks the directory, then reads the marker; a hostile user who
# can create the store's *parent* could in principle win the instant between
# them. The checks are ordered so the read happens immediately after the check
# (never across the slow `CURRENT_HASH` pass), which is what makes that window
# the same irreducible one a filesystem check-then-open always has in shell —
# closing it entirely would need an `openat`-based helper this plugin does not
# have, and the same-user/root limits below already cover the rest. Recorded so
# a later reader does not mistake the ordering for an accident.
#
# ## Limits, stated on purpose
#
# - A **same-user** attacker is out of scope. Every check here is about *who
#   owns* the directory; once the attacker runs as this user, there is no
#   ownership boundary left to check — they can write the markers directly,
#   exactly as we can. Nothing in this file pretends otherwise.
# - **root** is likewise out of scope: mode and ownership bits do not stop it.
# - Moving the path to a per-user location (`$XDG_RUNTIME_DIR`, `~/.workflow-dev/`)
#   was the story's other candidate and was not taken: the checks above close
#   the finding without orphaning existing markers, and relocation would
#   change the happy-path location for a threat the ownership check already
#   covers. If the path ever does move, it moves *here*, in `marker_root`.
# - Trusting a directory does not make the marker inside it authentic: a
#   marker is still just a hash match. The check narrows the window to "the
#   current user's own directory", which is the boundary the story asked for.

# The root of the marker store: the fixed path every call site shares.
marker_root() {
  printf '%s' "${TMPDIR:-/tmp}/workflow-dev-validate"
}

# The reviewed-message store, for the message hook's read side and the two
# write sides that key by message hash.
marker_subdir() {
  printf '%s/messages' "$(marker_root)"
}

# 0 when $1 is group- or world-writable, 1 otherwise. Deliberately **fails
# closed**: when the mode cannot be read at all — no `find` in PATH — it reports
# writable, so a caller asks instead of trusting a directory whose permissions
# it could not check. `find -perm` avoids `stat -f %Lp` (BSD) vs `stat -c %a`
# (GNU), which differ, and matches the shape the story itself names.
marker_dir_world_writable() {
  local perms
  perms="$(find "$1" -maxdepth 0 \( -perm -g+w -o -perm -o+w \) -print 2>/dev/null)" || return 0
  [[ -n "$perms" ]]
}

# Why markers under $1 (a directory) must not be trusted — empty when they may.
# Deliberately one line and no side effects: callers attach it to a reminder.
# **Return contract:** always exits 0; the answer is the *output*, empty when the
# directory may be trusted and a one-line reason when it may not. Callers test
# the string, not the status (`reason="$(marker_dir_reason …)" || true` is
# defensive only).
#
# A missing directory is trusted on purpose. "There is no directory" means
# "there are no markers", so the normal reminder fires on its own; reporting a
# missing directory as untrusted would turn every first run into a security
# warning. The checks below only fire on something that actually exists:
#   - a symlink at the final component (a planted redirect),
#   - anything that exists but is not a directory,
#   - a directory owned by someone else,
#   - a directory group- or world-writable (anyone could drop a marker in).
# `-O` (owned by the current user) and `-L` (symlink) are the tests bash 3.2
# provides, and are the ones the story itself names.
marker_dir_reason() {
  local dir="$1"
  if [[ -L "$dir" ]]; then
    printf '%s is a symlink' "$dir"
  elif [[ -e "$dir" && ! -d "$dir" ]]; then
    printf '%s exists but is not a directory' "$dir"
  elif [[ -d "$dir" && ! -O "$dir" ]]; then
    printf '%s is not owned by the current user' "$dir"
  elif [[ -d "$dir" ]] && marker_dir_world_writable "$dir"; then
    printf '%s is group- or world-writable' "$dir"
  fi
}

# The sentence a caller appends to its reminder/ask when the chain is not
# trusted (empty reason → empty output). Defined here, with the reason it is
# built from, so both hooks share one wording and one sanitizer instead of two
# copies — and so the escaping has a single owner.
#
# The reason names a path derived from `$TMPDIR`, and hook mode embeds the
# result in a JSON string, so *every* byte that could terminate or corrupt that
# string must go: `[:cntrl:]` drops all C0 controls and DEL (newline, tab, …),
# and `"` and `\` are dropped explicitly. Without the control-character sweep a
# tab in `TMPDIR` produced invalid JSON (found by this change's own adversarial
# pass). `LC_ALL=C` keeps the class byte-wise on a UTF-8 locale.
marker_trust_note() {
  local reason="$1"
  [[ -n "$reason" ]] || return 0
  printf ' (The marker directory cannot be trusted: %s.)' \
    "$(printf '%s' "$reason" | LC_ALL=C tr -d '[:cntrl:]"\\')"
}

# The reason to distrust $1 when it lives (or is meant to live) under
# marker_root — every component from the root down to $1, not just the last
# one. A writable *parent* is enough to swap the child out (rename it away,
# drop a replacement in), so checking only the leaf would let a 700 `messages/`
# sit under a 777 root and still be replaced at will.
#
# The walk stops AT the root, deliberately: the root's own parent is
# `${TMPDIR:-/tmp}`, which on a shared /tmp is world-writable by design (mode
# 1777, the sticky bit is what makes it usable at all). Demanding that parent be
# private would make the check fail everywhere — the boundary this story draws
# is the marker store, so the marker store is where the chain begins.
marker_chain_reason() {
  local target="$1" root current reason
  root="$(marker_root)"
  current="$target"
  while [[ "$current" == "$root" || "$current" == "$root/"* ]]; do
    reason="$(marker_dir_reason "$current")"
    [[ -n "$reason" ]] && { printf '%s' "$reason"; return; }
    [[ "$current" == "$root" ]] && return
    current="$(dirname "$current")"
  done
  # Not under the root (only reachable if a caller passes something else) —
  # fall back to checking the directory itself.
  marker_dir_reason "$target"
}

# Make $1 ready to write markers into: create it mode 700 when it is absent,
# or succeed when it exists and is trustworthy all the way up to the root. On an
# untrustworthy chain it prints the reason and returns 1 — the caller must not
# write there.
marker_ensure_dir() {
  local dir="$1" reason
  if [[ -e "$dir" || -L "$dir" ]]; then
    reason="$(marker_chain_reason "$dir")" || true
    [[ -z "$reason" ]] && return 0
    printf '%s\n' "$reason" >&2
    return 1
  fi
  # Before creating, make sure what already exists above it *within the marker
  # store* is trustworthy — `mkdir -p` would otherwise happily create through a
  # planted parent. The root itself is exempt: its parent is `${TMPDIR:-/tmp}`,
  # world-writable by design on a shared /tmp.
  if [[ "$dir" != "$(marker_root)" ]]; then
    reason="$(marker_chain_reason "$(dirname "$dir")")" || true
    if [[ -n "$reason" ]]; then
      printf '%s\n' "$reason" >&2
      return 1
    fi
  fi
  # `umask 077` in a subshell: the caller's umask is none of this file's
  # business, and the file mode (600) is belt-and-braces on top of it because
  # marker contents are hash-keyed machine state, not shareable data.
  ( umask 077 && mkdir -p "$dir" ) || return 1
}

# Write stdin to $1, atomically and without ever opening a predictable path for
# writing: a `mktemp` name in the same directory is filled, then `mv`d into
# place. A `>` at the final name would follow a symlink planted there and would
# also race a concurrent run; this mirrors pre-compact-check.sh's reasoning for
# `pendingSave`. Re-checks the whole chain's trust even though callers run
# marker_ensure_dir first — the write is the moment the consequence lands, so it
# does not rely on a caller having asked.
marker_write() {
  local file="$1" dir base tmp reason
  dir="$(dirname "$file")"
  base="$(basename "$file")"
  reason="$(marker_chain_reason "$dir")" || true
  if [[ -n "$reason" ]]; then
    printf '%s\n' "$reason" >&2
    return 1
  fi
  # A final component that is a directory (a symlink to one included — `-d`
  # follows the link) must be refused: `mv "$tmp" "$file"` would silently move
  # the temp file *inside* it and report success, leaving no marker at the name
  # the reader looks for. A symlink to a *file* is fine and deliberately not
  # refused: `mv` replaces the link itself, never writes through it.
  if [[ -d "$file" || ( -e "$file" && ! -f "$file" ) ]]; then
    printf '%s is not a plain file — refusing to write a marker through it' "$file" >&2
    return 1
  fi
  tmp="$(mktemp "$dir/.$base.XXXXXX")" || return 1
  if cat > "$tmp"; then
    chmod 600 "$tmp"
    # Clean up on a failed `mv` too (ENOSPC, EPERM, an immutable target, …):
    # the temp file is only ours, and leaking one per failure is a small mess
    # that nothing else would ever collect.
    mv "$tmp" "$file" || { rm -f "$tmp"; return 1; }
  else
    rm -f "$tmp"
    return 1
  fi
}
