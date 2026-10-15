#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Tests for the plugin's .mcp.json — the Context7 entry every user gets when
# the plugin is enabled. CI never runs `claude plugin validate`, so this is the
# guard that the entry keeps its URL and that no header ever holds a literal
# key: a key typed into this file would ship to every user.
#
#   bash scripts/mcp-json.test.sh
#
# Exits non-zero if any assertion fails.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
MCP="$HERE/../.mcp.json"

pass=0
fail=0
ok() { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }

# jq is not assumed installed (REPO.md stack); python3 parses JSON as well.
json() {
  if command -v jq >/dev/null 2>&1; then
    jq -r "$1" "$MCP"
  else
    python3 - "$MCP" "$2" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
if sys.argv[2] == 'ALL_HEADERS':
    for server in d.get('mcpServers', {}).values():
        for v in (server.get('headers') or {}).values():
            print(v)
    sys.exit(0)
for part in filter(None, sys.argv[2].split('.')):
    d = d.get(part) if isinstance(d, dict) else None
if isinstance(d, dict):
    print('\n'.join(str(v) for v in d.values()))
elif d is not None:
    print(d)
PY
  fi
}

# --- 1: the file parses ------------------------------------------------------
if json '.' '' >/dev/null 2>&1; then ok ".mcp.json is valid JSON"
else no ".mcp.json is valid JSON"; echo; echo "$pass passed, $fail failed"; exit 1
fi

# --- 2: the Context7 entry, remote, at its exact URL ------------------------
TYPE="$(json '.mcpServers.context7.type // empty' 'mcpServers.context7.type')"
[[ "$TYPE" == "http" ]] && ok "context7 is an http server" \
  || no "context7 is an http server (got: $TYPE)"
URL="$(json '.mcpServers.context7.url // empty' 'mcpServers.context7.url')"
[[ "$URL" == "https://mcp.context7.com/mcp" ]] && ok "context7 url is https://mcp.context7.com/mcp" \
  || no "context7 url is https://mcp.context7.com/mcp (got: $URL)"

# --- 3: no header of any server holds a literal value -----------------------
# Every header must be a whole ${VAR} or ${VAR:-} expansion, so a key only
# ever comes from the user's environment. A non-empty default would be a
# literal shipped to every user whose variable is unset.
VALUES="$(json '.mcpServers[] | .headers // {} | .[]' 'ALL_HEADERS')"
bad=""
while IFS= read -r v; do
  [[ -z "$v" ]] && continue
  [[ "$v" =~ ^\$\{[A-Za-z_][A-Za-z0-9_]*(:-)?\}$ ]] || bad="$bad [$v]"
done <<< "$VALUES"
[[ -z "$bad" ]] && ok "every header value is an env expansion" \
  || no "every header value is an env expansion (literal:$bad)"
case "$VALUES" in
  *'${CONTEXT7_API_KEY:-}'*) ok "key header reads CONTEXT7_API_KEY, empty when unset" ;;
  *) no "key header reads CONTEXT7_API_KEY, empty when unset (got: $VALUES)" ;;
esac

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
