#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Claude Code `PreToolUse` (matcher: the plugin's Context7 tools). The plugin
# ships the Context7 server so skills can look up a library's docs
# (references/library-docs.md), and a lookup that stops on a permission dialog
# every time is a lookup nobody waits for. So this answers `allow` — the same
# decision config-check.sh emits — and the lookup runs with no dialog, in the
# main agent and in sub-agents alike (probed 2026-10-14, Claude Code 2.1.287).
#
# The exception is a lookup that looks like it carries something private: a
# credential, a path on this machine, or pasted code. The lookup leaves the
# machine for a third-party service, so that one gets `deny`, and the reason
# tells the agent to rewrite it with only the library, its version and a short
# question, say so to the human in the chat, and call again. Not `ask`: a
# dialog pauses an autonomous run until someone answers, and headless it
# comes back as a denial with nothing to act on — the point of the lookup is
# that it happens (owner's decision, WD-0090). The rule itself lives in
# library-docs.md; this is its backstop. The reason never quotes what matched,
# so a secret is not echoed into the transcript.
#
# Silent (no output, Claude Code's own permission flow applies) on: another
# tool (a Context7 tool the plugin does not use included), input it cannot
# read, or no JSON parser (jq or python3) on the machine. A user's
# `permissions.deny` on the server still wins over the `allow`: the tools are
# then not offered at all (probed).

set -u

HERE="$(cd -P "$(dirname "$0")" && pwd -P)"
# shellcheck source=hook-language.sh
source "$HERE/hook-language.sh"

INPUT="$(cat)"

# Only the two tools the plugin uses. A tool the remote server adds later was
# never reviewed, so it gets no `allow`: Claude Code's own dialog decides.
TOOLS=" mcp__plugin_workflow-dev_context7__resolve-library-id mcp__plugin_workflow-dev_context7__query-docs "
# A lookup is a library name, a version and a short question. Past these sizes
# it is no longer a question: it is something pasted.
MAX_CHARS=400
MAX_LINES=4

# macOS ships /usr/bin/python3 as a stub: without the Command Line Tools it
# fails and offers to install them, which would pop up on every lookup.
python3_usable() {
  [[ "$(uname -s 2>/dev/null)" == Darwin && "$(command -v python3)" == /usr/bin/python3 ]] || return 0
  xcode-select -p >/dev/null 2>&1
}

# Decode the payload with a real JSON parser — jq, else python3 — and print
# tool_name, cwd, then every string anywhere under tool_input, one after the
# other (a value's own newlines are kept, so a paste still counts its lines).
# Every string, not three known fields: the server is remote and can rename or
# add fields without a plugin release. A hand-rolled grep decoder missed \t, \uXXXX and \/ escapes, so with
# neither parser the hook says nothing and the normal dialog decides.
decode() {
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$INPUT" | jq -r '
      (.tool_name // "" | tostring), (.cwd // "" | tostring),
      ([.tool_input | .. | strings] | join("\n"))' 2>/dev/null
  elif command -v python3 >/dev/null 2>&1 && python3_usable; then
    printf '%s' "$INPUT" | python3 -c '
import json, sys
d = json.load(sys.stdin)
def strings(v):
    if isinstance(v, str):
        yield v
    elif isinstance(v, dict):
        for x in v.values(): yield from strings(x)
    elif isinstance(v, list):
        for x in v: yield from strings(x)
print(str(d.get("tool_name") or ""))
print(str(d.get("cwd") or ""))
print("\n".join(strings(d.get("tool_input"))))' 2>/dev/null
  fi
}

# Past MAX_CHARS the verdict is `deny` whatever follows, so 64 KB is plenty and
# keeps a multi-megabyte paste inside the hook's timeout.
DECODED="$(set -o pipefail; decode | head -c 65536)" || exit 0
TOOL="$(printf '%s\n' "$DECODED" | sed -n 1p)"
case "$TOOLS" in
  *" $TOOL "*) [[ -n "$TOOL" ]] || exit 0 ;;
  *) exit 0 ;;
esac
CWD="$(printf '%s\n' "$DECODED" | sed -n 2p)"
TEXT="$(printf '%s\n' "$DECODED" | sed '1,2d')"

# Nothing readable in the input: say nothing, so the normal dialog decides.
printf '%s' "$TEXT" | grep -q '[^[:space:]]' || exit 0

# The project's own path, as a whole path. It must start the line or follow
# something that cannot be part of a file name (a space, a quote, `(`), so
# "/app" inside "src/app/layout.tsx" is a Next.js folder, not the project /app.
# And it must end at the end of a line or before something that cannot
# continue a file name (`/`, a space, `?`, `:`, a quote, a sentence's closing
# dot), so "/app" in "/apple/swift" is not the project either. TEXT is at most MAX_CHARS
# here, so the loop is short.
cwd_hit() {
  local line rest before cwd="${CWD%/}"
  [[ -n "$cwd" ]] || return 1
  while IFS= read -r line; do
    while [[ "$line" == *"$cwd"* ]]; do
      rest="${line#*"$cwd"}"
      before="${line%%"$cwd"*}"
      if [[ -z "$before" || ! "${before: -1}" =~ [A-Za-z0-9._~/-] ]]; then
        [[ -z "$rest" || ! "${rest:0:1}" =~ [A-Za-z0-9._-] ]] && return 0
        [[ "${rest:0:1}" == "." && ! "${rest:1:1}" =~ [A-Za-z0-9_-] ]] && return 0
      fi
      # Resume one character after where this match began, so a match that
      # overlaps it is still seen.
      line="${line:$(( ${#before} + 1 ))}"
    done
  done <<< "$TEXT"
  return 1
}

# A long run of token characters that mixes letters and digits like a key:
# upper, lower and a digit, or four digits or more. Library ids and slugs
# (`/websites/developer_mozilla_org`) are split on `/` first and rarely do.
random_run() {
  printf '%s' "$TEXT" | grep -oE '[A-Za-z0-9+/=_-]{24,}' | tr '/' '\n' \
    | grep -E '.{24,}' | grep -E '[0-9]' | grep -E '[A-Za-z]' \
    | grep -qE '[A-Z].*[a-z]|[a-z].*[A-Z]|[0-9].*[0-9].*[0-9].*[0-9]'
}

private=""
# Size first: it is cheap, and a long paste must never reach a check that
# could run past the hook's timeout.
if (( ${#TEXT} > MAX_CHARS )) || (( $(printf '%s\n' "$TEXT" | grep -c .) > MAX_LINES )); then
  private="code"
# Credential shapes: cloud and forge tokens, private keys, bearer tokens,
# JWTs, long hex runs, credentials in a URL, and random-looking runs.
elif printf '%s' "$TEXT" | grep -qE 'AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_|(^|[^A-Za-z0-9])sk-[A-Za-z0-9_-]{16,}|xox[abprs]-|ctx7sk|-----BEGIN|[Bb]earer[[:space:]]+[A-Za-z0-9._~+/-]{8,}|eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}|[0-9a-fA-F]{32,}|://[^/[:space:]:@]+:[^/[:space:]@]+@'; then
  private="secret"
elif random_run; then
  private="secret"
# "key = value" assignments, the key quoted or not.
elif printf '%s' "$TEXT" | grep -qiE '(password|passwd|secret|token|api[_-]?key|access[_-]?key)["'"'"']?[[:space:]]*[:=]'; then
  private="secret"
# Paths on this machine: the project itself, or any home, mount or system root.
elif cwd_hit; then
  private="path"
elif printf '%s' "$TEXT" | grep -qE '(^|[^A-Za-z0-9])(~/|/Users/|/home/|/root/|/private/|/var/|/etc/|/opt/|/tmp/|/srv/|/mnt/|/Volumes/|[A-Za-z]:\\)'; then
  private="path"
fi

if [[ -z "$private" ]]; then
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}\n'
else
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' \
    "$(hook_msg "$(hook_language "$INPUT")" library_query_rewrite)"
fi
exit 0
