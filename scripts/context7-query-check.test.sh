#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Tests for context7-query-check.sh: a plain library-docs lookup is allowed
# with no dialog, one that looks like it carries a secret, a local path or
# pasted code is sent back to the agent to rewrite, and nothing else is
# touched. Each case runs with jq, again with python3 alone (jq is not assumed installed), and
# with neither, where the hook must say nothing. Every run uses a throwaway
# HOME, so no real settings are read.
#
#   bash scripts/context7-query-check.test.sh
#
# Exits non-zero if any assertion fails.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/context7-query-check.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

HOME_DIR="$TMP/home"; mkdir -p "$HOME_DIR"
REPO="$TMP/acme-billing"; mkdir -p "$REPO"

# PATHs with every tool the hook needs but jq: one with python3, one with no
# JSON parser at all.
NOJQ="$TMP/nojq"; NONE="$TMP/none"; mkdir -p "$NOJQ" "$NONE"
for t in bash cat grep sed head tr dirname date mktemp rm uname xcode-select; do
  p="$(command -v "$t")" && ln -s "$p" "$NOJQ/$t" && ln -s "$p" "$NONE/$t"
done
# The real interpreter, not a version-manager shim that needs its own PATH.
PY="$(python3 -c 'import sys; print(sys.executable)' 2>/dev/null)" && ln -s "$PY" "$NOJQ/python3"

pass=0
fail=0
ok() { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }

RESOLVE="mcp__plugin_workflow-dev_context7__resolve-library-id"
QUERY="mcp__plugin_workflow-dev_context7__query-docs"

# run PATHMODE TOOL INPUT_JSON [CWD] -> stdout, as Claude Code would call it.
run() {
  local payload="{\"session_id\":\"t\",\"cwd\":\"${4:-$REPO}\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"$2\",\"tool_input\":$3}"
  case "$1" in
    python) printf '%s' "$payload" | env -i HOME="$HOME_DIR" PATH="$NOJQ" bash "$SCRIPT" ;;
    none)   printf '%s' "$payload" | env -i HOME="$HOME_DIR" PATH="$NONE" bash "$SCRIPT" ;;
    *)      printf '%s' "$payload" | env HOME="$HOME_DIR" bash "$SCRIPT" ;;
  esac
}

expect() { # $1 label, $2 want (allow|deny|silent), $3 tool, $4 input, [$5 cwd]
  local mode out got want
  for mode in jq python none; do
    [[ "$mode" == "jq" ]] && ! command -v jq >/dev/null 2>&1 && continue
    [[ "$mode" == "python" && -z "$PY" ]] && continue
    want="$2"; [[ "$mode" == "none" ]] && want="silent"
    out="$(run "$mode" "$3" "$4" "${5:-}")"
    case "$out" in
      "") got="silent" ;;
      *'"permissionDecision":"allow"'*) got="allow" ;;
      *'"permissionDecision":"ask"'*) got="ask" ;;
      *'"permissionDecision":"deny"'*) got="deny" ;;
      *) got="other: $out" ;;
    esac
    [[ "$got" == "$want" ]] && ok "$1 → $want ($mode)" || no "$1 → $want ($mode, got: $got)"
    if [[ "$got" == "deny" ]]; then
      case "$out" in
        *'"permissionDecisionReason":"'*Context7*library-docs.md*) ok "$1: reason names Context7 and the rule ($mode)" ;;
        *) no "$1: reason names Context7 and the rule ($mode, got: $out)" ;;
      esac
    fi
    if command -v jq >/dev/null 2>&1 && [[ -n "$out" ]]; then
      printf '%s' "$out" | jq -e . >/dev/null 2>&1 && ok "$1: valid JSON ($mode)" || no "$1: valid JSON ($mode, got: $out)"
    fi
  done
}

# --- 1: plain lookups run with no dialog --------------------------------------
expect "resolve react" allow "$RESOLVE" '{"libraryName":"react","query":"useEffect cleanup in React 19"}'
expect "query zod docs" allow "$QUERY" '{"libraryId":"/colinhacks/zod","query":"zod 3.23: how to refine a schema with an async check"}'
expect "long library id slug" allow "$QUERY" '{"libraryId":"/websites/developer_mozilla_org-en-US-docs-Web","query":"fetch AbortSignal timeout"}'
expect "escaped quotes in the question" allow "$QUERY" '{"libraryId":"/vercel/next.js","query":"what does \"use cache\" do in Next.js 16"}'
expect "a short multi-line question" allow "$QUERY" '{"libraryId":"/vercel/next.js","query":"Next.js 16 caching\nhow to revalidate a tag"}'

# --- 2: anything that looks private is held for the human ---------------------
expect "AWS key" deny "$QUERY" '{"libraryId":"/aws/aws-sdk-js-v3","query":"why does AKIAIOSFODNN7EXAMPLE get access denied"}'
expect "GitHub token" deny "$RESOLVE" '{"libraryName":"octokit","query":"auth with ghp_0123456789abcdefghijABCDEFGHIJ"}'
expect "sk- key" deny "$QUERY" '{"libraryId":"/openai/openai-node","query":"client with key sk-proj-abcdef0123456789XYZ"}'
expect "Context7 key" deny "$QUERY" '{"libraryId":"/x/y","query":"ctx7sk-1234 not accepted"}'
expect "private key block" deny "$QUERY" '{"libraryId":"/x/y","query":"parse -----BEGIN RSA PRIVATE KEY----- in node"}'
expect "bearer token" deny "$QUERY" '{"libraryId":"/x/y","query":"header Bearer abc.def-123456789"}'
expect "JWT" deny "$QUERY" '{"libraryId":"/x/y","query":"decode eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0"}'
expect "password assignment" deny "$QUERY" '{"libraryId":"/x/y","query":"connect with password=hunter2"}'
expect "API key assignment" deny "$QUERY" '{"libraryId":"/x/y","query":"set api_key: abc"}'
expect "long hex run" deny "$QUERY" '{"libraryId":"/x/y","query":"token 9f86d081884c7d659a2feaa0c55ad015a3bf4f1b"}'
expect "random-looking run" deny "$QUERY" '{"libraryId":"/x/y","query":"value Zx81kQp0LmN3vR7tYw2Ab9Cd4Ef6Gh"}'
expect "the project's own path" deny "$QUERY" "{\"libraryId\":\"/x/y\",\"query\":\"import from $REPO/src/db.ts fails\"}"
expect "a home path" deny "$QUERY" '{"libraryId":"/x/y","query":"config at /Users/someone/app/vite.config.ts"}'
expect "a Windows path" deny "$QUERY" '{"libraryId":"/x/y","query":"config at C:\\Users\\dev\\app"}'
LONG="$(printf 'const a = 1; %.0s' $(seq 1 40))"
expect "a long pasted block" deny "$QUERY" "{\"libraryId\":\"/x/y\",\"query\":\"$LONG\"}"
expect "many pasted lines" deny "$QUERY" '{"libraryId":"/x/y","query":"a\nb\nc\nd\ne\nf"}'
expect "a secret in the library name" deny "$RESOLVE" '{"libraryName":"ghp_0123456789abcdefghijABCDEFGHIJ","query":"auth"}'
# JSON escapes are decoded before any check: a tab, \u escapes, escaped slashes.
expect "tab before a home path" deny "$QUERY" '{"libraryId":"/x/y","query":"fails on\t/Users/bob/acme/src/db.ts"}'
expect "tab before an sk- key" deny "$QUERY" '{"libraryId":"/x/y","query":"client key\tsk-abcdef0123456789abcdef"}'
expect "unicode-escaped GitHub token" deny "$QUERY" '{"libraryId":"/x/y","query":"auth \u0067hp_abcdefghij0123456789abcdefghij"}'
expect "escaped slashes in a path" deny "$QUERY" '{"libraryId":"/x/y","query":"config at \/Users\/bob\/app"}'
expect "lines joined by an escaped newline" deny "$QUERY" '{"libraryId":"/x/y","query":"a\u000ab\u000ac\u000ad\u000ae\u000af"}'
# Any field of the input is read, not only the known ones.
expect "a secret in an unknown field" deny "$QUERY" '{"libraryId":"/x/y","query":"q","language":"ghp_0123456789abcdefghijABCDEFGHIJ"}'
expect "a secret in a nested field" deny "$QUERY" '{"libraryId":"/x/y","options":{"topic":"AKIAIOSFODNN7EXAMPLE"}}'
# Shapes the first patterns missed.
expect "quoted password key" deny "$QUERY" '{"libraryId":"/x/y","query":"config {\"password\": \"hunter2\"}"}'
expect "credentials in a URL" deny "$QUERY" '{"libraryId":"/x/y","query":"connect postgres://admin:S3cr3tPass@db.internal:5432/app"}'
expect "lowercase token with digits" deny "$QUERY" '{"libraryId":"/x/y","query":"use token 7f3kq9zr2mx8vw4np6ty1bc5hd0j"}'
expect "a path under ~" deny "$QUERY" '{"libraryId":"/x/y","query":"reads ~/work/app/.env"}'
expect "a path under /opt" deny "$QUERY" '{"libraryId":"/x/y","query":"config at /opt/acme/vite.config.ts"}'
expect "a path under /Volumes" deny "$QUERY" '{"libraryId":"/x/y","query":"src at /Volumes/Work/acme/src/db.ts"}'

# --- 2b: the session's folder is not a false alarm ------------------------------
expect "cwd / is not a path hit" allow "$QUERY" '{"libraryId":"/vercel/next.js","query":"what is use cache"}' "/"
expect "cwd /app does not match /apple" allow "$QUERY" '{"libraryId":"/apple/swift","query":"async let"}' "/app"
expect "cwd /app followed by a file" deny "$QUERY" '{"libraryId":"/x/y","query":"see /app/src/main.ts"}' "/app"
expect "cwd /app inside a Next.js path" allow "$QUERY" '{"libraryId":"/vercel/next.js","query":"how does the layout in src/app/layout.tsx work"}' "/app"
expect "cwd /app inside a monorepo path" allow "$QUERY" '{"libraryId":"/vercel/next.js","query":"routing in packages/web/app/page.tsx"}' "/app"
expect "cwd /app quoted" deny "$QUERY" "{\"libraryId\":\"/x/y\",\"query\":\"root '/app/src' not found\"}" "/app"
for q in 'why does vite fail in /workspaces/myrepo?' 'build output of /workspaces/myrepo. help' "root '/workspaces/myrepo' not found" 'error /workspaces/myrepo: ENOENT' 'open /workspaces/myrepo'; do
  expect "project path in: $q" deny "$QUERY" "{\"libraryId\":\"/x/y\",\"query\":\"$q\"}" "/workspaces/myrepo"
done
expect "project path then another field" deny "$QUERY" '{"query":"/workspaces/myrepo","libraryId":"/vercel/next.js"}' "/workspaces/myrepo"
expect "project path at a line end" deny "$QUERY" '{"libraryId":"/x/y","query":"open /workspaces/myrepo\nnext"}' "/workspaces/myrepo"
expect "cwd as the tail of a longer path" allow "$QUERY" '{"libraryId":"/x/y","query":"a /ab/ab/a"}' "/ab/a"
expect "overlap, then the project itself" deny "$QUERY" '{"libraryId":"/x/y","query":"x/ab/a and /ab/a"}' "/ab/a"
expect "cwd with a trailing slash" deny "$QUERY" '{"libraryId":"/x/y","query":"fail in /w/myrepo/src/x"}' "/w/myrepo/"
expect "a longer sibling name" allow "$QUERY" '{"libraryId":"/x/y","query":"fail in /workspaces/myrepo2 and /workspaces/myrepo.git"}' "/workspaces/myrepo"

# --- 3: nothing else is touched ------------------------------------------------
expect "a Context7 tool the plugin does not use" silent "mcp__plugin_workflow-dev_context7__get-library-docs" '{"libraryId":"/x/y","query":"q"}'
expect "another plugin's context7" silent "mcp__context7__query-docs" '{"libraryId":"/x/y","query":"ghp_0123456789abcdefghijABCDEFGHIJ"}'
expect "Bash" silent "Bash" '{"command":"ls"}'
expect "empty input" silent "$QUERY" '{}'
OUT="$(printf 'not json' | env HOME="$HOME_DIR" bash "$SCRIPT")"
[[ -z "$OUT" ]] && ok "malformed input → silent" || no "malformed input → silent (got: $OUT)"

# --- 3b: a long paste is held fast, well inside the hook's 5 s timeout ----------
LONGFILE="$TMP/long.json"
{ printf '{"tool_name":"%s","cwd":"%s","tool_input":{"libraryId":"/x/y","query":"' "$QUERY" "$REPO"
  for _ in $(seq 1 3000); do printf 'x = 1; '; done
  printf '"}}'; } > "$LONGFILE"
for mode in jq python; do
  [[ "$mode" == "jq" ]] && ! command -v jq >/dev/null 2>&1 && continue
  [[ "$mode" == "python" && -z "$PY" ]] && continue
  t0=$SECONDS
  if [[ "$mode" == "python" ]]; then OUT="$(env -i HOME="$HOME_DIR" PATH="$NOJQ" bash "$SCRIPT" < "$LONGFILE")"
  else OUT="$(env HOME="$HOME_DIR" bash "$SCRIPT" < "$LONGFILE")"; fi
  dt=$((SECONDS - t0))
  case "$OUT" in *'"permissionDecision":"deny"'*) ok "21 KB paste → deny ($mode)" ;; *) no "21 KB paste → deny ($mode, got: $OUT)" ;; esac
  (( dt <= 2 )) && ok "21 KB paste answered in ${dt}s ($mode)" || no "21 KB paste answered in ${dt}s ($mode)"
done

# --- 4: the reason never echoes what matched -----------------------------------
OUT="$(run jq "$QUERY" '{"libraryId":"/x/y","query":"ghp_0123456789abcdefghijABCDEFGHIJ"}')"
case "$OUT" in
  *ghp_*) no "reason does not echo the secret (got: $OUT)" ;;
  *) ok "reason does not echo the secret" ;;
esac

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
