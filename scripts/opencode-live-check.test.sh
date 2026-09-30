#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Tests for opencode-live-check.sh — one case per verdict, the three output
# modes, the no-jq fallback, and the one property everything rests on: the hash
# the plugin writes and the hash this script computes agree. No test framework in
# this repo; run it directly:
#
#   bash scripts/opencode-live-check.test.sh
#
# Exits non-zero if any assertion fails.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/opencode-live-check.sh"
REAL_PLUGIN="$HERE/../opencode/plugin.ts"

pass=0
fail=0
ok() { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }

TMP="$(mktemp -d)" || { echo "mktemp failed"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME/.workflow-dev"
PLUGIN="$TMP/workflow-dev.ts"
printf 'export default { id: "stub" }\n' > "$PLUGIN"
HASH="$(shasum -a 256 "$PLUGIN" | cut -d' ' -f1)"
MARKER="$HOME/.workflow-dev/opencode-live.json"

status() { WD_OPENCODE_PLUGIN="$PLUGIN" WD_OPENCODE_SERVICE_PID="$1" bash "$SCRIPT" --status; }
expect() {
  local got; got="$(status "$1")"
  [[ "$got" == "$2" ]] && ok "$3" || no "$3 (got: $got, want: $2)"
}

# --- 1: one verdict per case -------------------------------------------------
expect "" not-loaded "no service running → not-loaded"

rm -f "$MARKER"
expect 4242 not-loaded "service running, no marker → not-loaded"

printf '{"pid":999,"hash":"%s","loadedAt":"t","firedAt":"t"}\n' "$HASH" > "$MARKER"
expect 4242 not-loaded "a marker from another process (a private server, an old service) → not-loaded"

printf '{"pid":4242,"hash":"%s","loadedAt":"t","firedAt":"t"}\n' "$HASH" > "$MARKER"
WD_OPENCODE_PLUGIN="$TMP/missing.ts" WD_OPENCODE_SERVICE_PID=4242 bash "$SCRIPT" --status | grep -qx not-loaded \
  && ok "entry file missing → not-loaded" || no "entry file missing → not-loaded"

printf '{"pid":4242,"hash":"%s","loadedAt":"t"}\n' "$HASH" > "$MARKER"
expect 4242 not-firing "loaded from the current file, notice never sent → not-firing"

printf '{"pid":4242,"hash":"%s","loadedAt":"t","firedAt":"2026-09-30T00:00:00Z"}\n' "$HASH" > "$MARKER"
expect 4242 live "loaded, current, fired → live"

printf '// edited after load\n' >> "$PLUGIN"
expect 4242 stale "file changed after the service loaded it → stale"
printf 'export default { id: "stub" }\n' > "$PLUGIN"

# --- 2: the three output modes -----------------------------------------------
out="$(WD_OPENCODE_PLUGIN="$PLUGIN" WD_OPENCODE_SERVICE_PID=4242 bash "$SCRIPT" --message)"
[[ -z "$out" ]] && ok "--message is silent when live" || no "--message is silent when live (got: $out)"

WD_OPENCODE_PLUGIN="$PLUGIN" WD_OPENCODE_SERVICE_PID=4242 bash "$SCRIPT" >/dev/null
[[ $? -eq 0 ]] && ok "report exits 0 when live" || no "report exits 0 when live"

out="$(WD_OPENCODE_PLUGIN="$PLUGIN" WD_OPENCODE_SERVICE_PID=7 bash "$SCRIPT" --message)"
[[ "$out" == *"pid 7"* && "$out" == *"opencode service restart"* ]] \
  && ok "--message explains not-loaded and names the fix" || no "--message explains not-loaded (got: $out)"

WD_OPENCODE_PLUGIN="$PLUGIN" WD_OPENCODE_SERVICE_PID=7 bash "$SCRIPT" >/dev/null
[[ $? -ne 0 ]] && ok "report exits non-zero when not live" || no "report exits non-zero when not live"

rc=0; WD_OPENCODE_PLUGIN="$PLUGIN" WD_OPENCODE_SERVICE_PID=7 bash "$SCRIPT" --status >/dev/null || rc=$?
[[ $rc -eq 0 ]] && ok "--status always exits 0" || no "--status always exits 0 (rc: $rc)"

# --- 3: without jq, the fallback reads the same fields ------------------------
NOJQ="$TMP/nojq-bin"
mkdir -p "$NOJQ"
for t in sed head cut shasum; do ln -s "$(command -v "$t")" "$NOJQ/$t"; done
nojq() { PATH="$NOJQ" WD_OPENCODE_PLUGIN="$PLUGIN" WD_OPENCODE_SERVICE_PID=4242 /bin/bash "$SCRIPT" --status; }
[[ "$(nojq)" == "live" ]] && ok "no jq: live is still read as live" || no "no jq: live (got: $(nojq))"
printf '{"pid":4242,"hash":"%s","loadedAt":"t"}\n' "$HASH" > "$MARKER"
[[ "$(nojq)" == "not-firing" ]] && ok "no jq: a missing firedAt is still noticed" || no "no jq: not-firing (got: $(nojq))"

# --- 4: the plugin's hash and this script's hash agree ------------------------
# Everything above feeds the script a marker it wrote the hash for itself. This
# runs the real plugin as the service under node, lets it write the marker, and
# checks the script accepts it — the two formulas meeting, not each in isolation.
if command -v node >/dev/null 2>&1; then
  rm -f "$MARKER"
  PID="$(cd "$TMP" && HOME="$HOME" node --input-type=module -e "
    process.argv.push('--service')
    const p = (await import('$REAL_PLUGIN')).default
    const noop = async () => ({ dispose: async () => {} })
    await p.setup({ location: {}, tool: { hook: noop }, session: { hook: noop, synthetic: async () => {} }, event: { subscribe: noop } })
    console.log(process.pid)
  " 2>/dev/null)"
  got="$(WD_OPENCODE_PLUGIN="$REAL_PLUGIN" WD_OPENCODE_SERVICE_PID="$PID" bash "$SCRIPT" --status)"
  [[ "$got" == "not-firing" ]] \
    && ok "the plugin's own marker is accepted as loaded from the current file" \
    || no "the plugin's own marker is accepted (got: $got — a hash mismatch reads as stale)"
else
  echo "  skip  node isn't installed — plugin/script hash agreement not exercised"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
