#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Tests for pre-commit-validate-check.sh. It needs a real git repo and a real
# marker file, so this builds a throwaway repo and points TMPDIR at a throwaway
# directory — the live /tmp marker store is never read or written.
#
# What it pins:
#   - the *deferred* marker gets its own `allow` answer, never an ask;
#   - a matching marker of either kind means no ask, so the reminder cannot
#     become a tax paid on every commit after validate passed once.
#
#   bash scripts/pre-commit-validate-check.test.sh

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/pre-commit-validate-check.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok() { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }

# Payload construction needs real JSON escaping, and the scripts' own jq-less
# extraction is best-effort by design. Skip rather than fail on a host without
# jq, the same way the other suites in this repo do.
if ! command -v jq >/dev/null 2>&1; then
  echo "  skip  jq isn't installed — payload construction for this suite needs it"
  exit 0
fi

PROJ="$TMP/proj"
export TMPDIR="$TMP/tmpdir"
# The dialog text follows the tester's Claude Code `language` setting
# (hook-language.sh), so a throwaway HOME keeps every case below on the English
# default; section 11 sets a language on purpose.
export HOME="$TMP/home"
mkdir -p "$PROJ" "$TMPDIR" "$HOME"

( cd "$PROJ" \
  && git init -q . \
  && git config user.email t@example.com \
  && git config user.name t \
  && printf 'one\n' > tracked.txt \
  && git add tracked.txt \
  && git commit -qm "chore: seed" \
  && printf 'one\ntwo\n' > tracked.txt ) || { echo "  FAIL could not build the throwaway repo"; exit 1; }
mkdir -p "$PROJ/.workflow-dev/context"

mk() { printf '{"tool_input":{"command":%s}}' "$(printf '%s' "$1" | jq -Rs .)"; }
hook() { ( cd "$PROJ" && printf '%s' "$1" | bash "$SCRIPT" ); }
envelope_reason() { printf '%s' "$1" | sed -E 's/.*"permissionDecisionReason":"(.*)"\}\}$/\1/'; }
# The reminder text when the hook asks — empty for silence or an `allow`.
plain() {
  local out; out="$(hook "$1")"
  case "$out" in *'"permissionDecision":"ask"'*) envelope_reason "$out" ;; esac
}

# Same formula the script uses to key its marker, restated here on purpose: the
# test's job is to place a marker where the script looks for one.
MARKER_DIR="$TMPDIR/workflow-dev-validate"
REPO_HASH="$( cd "$PROJ" && git rev-parse --show-toplevel | tr -d '\n' | shasum | cut -c1-12 )"
MARKER="$MARKER_DIR/$REPO_HASH.json"
current_hash() {
  ( cd "$PROJ" \
    && { git diff --name-only HEAD -- . ':!.workflow-dev';
         git ls-files --others --exclude-standard -- . ':!.workflow-dev';
       } | sort -u | while IFS= read -r f; do
         [[ -n "$f" ]] && printf '%s\n' "$f" && cat "$f" 2>/dev/null
       done | shasum | cut -d' ' -f1 )
}

# --- 1: not a commit → silence ---------------------------------------------
[[ -z "$(hook "$(mk 'ls -la')")" ]] && ok "non-commit command → silent" || no "non-commit command → silent"

# --- 2: a commit with no marker → ask --------------------------------------
mkdir -p "$MARKER_DIR"; rm -f "$MARKER"
COMMIT="$(mk 'git commit -m "feat: x"')"
JSON_OUT="$(hook "$COMMIT")"
[[ -n "$(envelope_reason "$JSON_OUT")" ]] && ok "the ask carries the reminder" || no "the ask carries the reminder (got: $JSON_OUT)"
case "$JSON_OUT" in
  *'"permissionDecision":"ask"'*) ok "a commit with no marker asks (never denies)" ;;
  *) no "a commit with no marker asks (got: $JSON_OUT)" ;;
esac

# --- 3: a matching 'deferred' marker → allow --------------------------------
printf '{"diffHash":"%s","status":"deferred","at":"2026-09-29T00:00:00Z"}' "$(current_hash)" > "$MARKER"
JSON_OUT="$(hook "$COMMIT")"
case "$JSON_OUT" in
  *'"permissionDecision":"allow"'*) ok "deferred marker → hook mode allows" ;;
  *) no "deferred marker → hook mode allows (got: $JSON_OUT)" ;;
esac
[[ -z "$(plain "$COMMIT")" ]] && ok "deferred marker → no ask" || no "deferred marker → no ask (got: $(plain "$COMMIT"))"

# --- 4: a matching 'validated' marker → silence -----------------------------
printf '{"diffHash":"%s","status":"validated","at":"2026-09-29T00:00:00Z"}' "$(current_hash)" > "$MARKER"
[[ -z "$(hook "$COMMIT")" ]] && ok "validated marker → silent" || no "validated marker → silent"

# --- 5: a marker from an older diff is not a match --------------------------
printf '{"diffHash":"deadbeef","status":"validated","at":"2026-09-29T00:00:00Z"}' > "$MARKER"
[[ -n "$(plain "$COMMIT")" ]] && ok "stale marker hash → the reminder comes back" || no "stale marker hash → the reminder comes back"

# --- 6: no .workflow-dev/context → this project doesn't use the workflow -----
rm -rf "$PROJ/.workflow-dev"
rm -f "$MARKER"
[[ -z "$(hook "$COMMIT")" ]] && ok "no context dir → silent" || no "no context dir → silent"

# --- 7: which commands count as a commit ------------------------------------
# With no marker, a command the matcher calls a commit gets the reminder and
# anything else is silent. The old substring match got both columns wrong.
mkdir -p "$PROJ/.workflow-dev/context"; rm -f "$MARKER"
fires() { [[ -n "$(plain "$(mk "$1")")" ]]; }

for c in 'echo "done" && git commit -m "x"' \
         'git -C ../other commit -m "x"' \
         'git -c user.name=x commit -m "x"' \
         'git  commit -m "x"' \
         'cd /tmp/p && git add -A && git commit -m "x"' \
         'bash -c "git commit -m x"' \
         'eval "git commit -m x"'; do
  fires "$c" && ok "real/ambiguous commit gets the reminder: $c" || no "real/ambiguous commit gets the reminder: $c"
done

for c in 'echo "run git commit later"' \
         'grep -rn "git commit" docs/' \
         'git commit-tree HEAD^{tree}' \
         'git commit-graph write' \
         'git log --grep="git commit"' \
         '# git commit later'; do
  fires "$c" && no "mention stays silent: $c" || ok "mention stays silent: $c"
done

# A heredoc that writes about committing — the shape that fired live.
DOC="$(printf 'cat > notes.md <<'"'"'EOF'"'"'\nthen run git commit\nEOF')"
fires "$DOC" && no "heredoc that mentions a commit stays silent" || ok "heredoc that mentions a commit stays silent"
# ...and the same hook still asks for the real commit that follows it.
fires "$(printf '%s\ngit commit -m x' "$DOC")" && ok "a real commit after such a heredoc still asks" || no "a real commit after such a heredoc still asks"

# --- 8: without jq, the fallback extractor reads past an escaped quote -------
# Everything after the first \" used to be invisible to it. PATH is narrowed to
# a directory of links to just the tools the script needs, so jq is absent.
NOJQ="$TMP/nojq-bin"
mkdir -p "$NOJQ"
for t in bash cat grep sed awk head cut sort tr git shasum dirname uname find; do
  p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$NOJQ/$t"
done
nojq_fires() { [[ "$( cd "$PROJ" && mk "$1" | PATH="$NOJQ" bash "$SCRIPT" )" == *'"permissionDecision":"ask"'* ]]; }
if PATH="$NOJQ" command -v jq >/dev/null 2>&1; then
  echo "  skip  could not hide jq from the fallback checks"
else
  nojq_fires 'echo "done" && git commit -m "x"' && ok "no jq: a commit after an escaped quote still asks" || no "no jq: a commit after an escaped quote still asks"
  nojq_fires 'git commit -m "x"' && ok "no jq: a plain commit asks" || no "no jq: a plain commit asks"
  # A multi-line command reaches the fallback with \n and \t escaped; the tab
  # before the closing delimiter of a `<<-` heredoc must come back as a tab.
  nojq_fires "$(printf 'cat <<-EOF > f\n\tbody\n\tEOF\ngit commit -m x')" && ok "no jq: a commit after a tab-indented <<- heredoc asks" || no "no jq: a commit after a tab-indented <<- heredoc asks"
  nojq_fires "$(printf 'git\tcommit -m x')" && ok "no jq: a tab between git and commit asks" || no "no jq: a tab between git and commit asks"
  nojq_fires "$(printf 'cat > notes.md <<'"'"'EOF'"'"'\nthen run git commit\nEOF')" && no "no jq: a heredoc mention stays silent" || ok "no jq: a heredoc mention stays silent"
  nojq_fires 'echo "run git commit later"' && no "no jq: a mention stays silent" || ok "no jq: a mention stays silent"
fi

# --- 9: an untrusted marker directory asks, never passes silently (WD-0027) ---
# A marker is a permission, so a directory anyone could have written to cannot
# grant it. Every case below has a *matching* marker in place, so a reminder can
# only be coming from the directory check — never from a missing marker.
mkdir -p "$PROJ/.workflow-dev/context"; mkdir -p "$MARKER_DIR"; chmod 700 "$MARKER_DIR"
printf '{"diffHash":"%s","status":"validated","at":"2026-09-29T00:00:00Z"}' "$(current_hash)" > "$MARKER"
[[ -z "$(hook "$COMMIT")" ]] && ok "private dir + matching marker → silent (the happy path)" || no "private dir + matching marker → silent"

chmod 777 "$MARKER_DIR"
JSON_OUT="$(hook "$COMMIT")"
PLAIN_OUT="$(plain "$COMMIT")"
[[ -n "$PLAIN_OUT" ]] && ok "world-writable dir + matching marker → asks (no silent pass)" || no "world-writable dir + matching marker → asks"
case "$JSON_OUT" in
  *'"permissionDecision":"ask"'*) ok "world-writable dir → hook mode asks, never denies" ;;
  *) no "world-writable dir → hook mode asks (got: $JSON_OUT)" ;;
esac
case "$PLAIN_OUT" in
  *"group- or world-writable"*) ok "world-writable dir → the reminder says why" ;;
  *) no "world-writable dir → the reminder says why (got: $PLAIN_OUT)" ;;
esac
chmod 700 "$MARKER_DIR"

# A symlinked marker directory pointing at a private one that holds the marker:
# the marker is there and readable, and must still not be trusted.
LINKED_MARKER_DIR="$TMPDIR/linked-marker-dir"
mv "$MARKER_DIR" "$LINKED_MARKER_DIR"
ln -s "$LINKED_MARKER_DIR" "$MARKER_DIR"
[[ -n "$(plain "$COMMIT")" ]] && ok "symlinked marker dir + matching marker → asks" || no "symlinked marker dir + matching marker → asks"
[[ -n "$(hook "$COMMIT")" ]] && ok "symlinked marker dir → hook mode is not silent" || no "symlinked marker dir → hook mode is not silent"
rm -f "$MARKER_DIR"
mv "$LINKED_MARKER_DIR" "$MARKER_DIR"
[[ -z "$(hook "$COMMIT")" ]] && ok "…and restoring the real directory restores silence" || no "…and restoring the real directory restores silence"

# --- 10: trust is checked at the read, not before the slow hash (WD-0027) ----
# The race the change's own adversarial pass found: the trust verdict used to be
# computed before CURRENT_HASH, so a store created during that pass (the
# missing-directory rule reads as "trusted") had its marker consumed under a
# stale verdict. This pins the fix deterministically — a `shasum` shim plants a
# world-writable store carrying the real current-diff hash on the *second*
# call (the CURRENT_HASH one), and the gate must still ask.
RACE_TMP="$TMP/race-tmp"
RACE_BIN="$TMP/race-bin"
mkdir -p "$RACE_TMP" "$RACE_BIN"
REAL_SHASUM="$(command -v shasum)"
cat > "$RACE_BIN/shasum" <<'SHIM'
#!/bin/bash
n=0
[ -f "$SHASUM_COUNT" ] && n="$(cat "$SHASUM_COUNT")"
n=$((n + 1))
printf '%s' "$n" > "$SHASUM_COUNT"
if [ "$n" -eq 2 ]; then
  out="$("$SHASUM_REAL")"
  h="$(printf '%s' "$out" | cut -d' ' -f1)"
  mkdir -p "$SHASUM_MARKER_DIR"
  chmod 777 "$SHASUM_MARKER_DIR"
  printf '{"diffHash":"%s","status":"validated"}' "$h" > "$SHASUM_MARKER_DIR/$SHASUM_REPO_HASH.json"
  printf '%s\n' "$out"
else
  exec "$SHASUM_REAL"
fi
SHIM
chmod +x "$RACE_BIN/shasum"

( cd "$PROJ" \
  && env TMPDIR="$RACE_TMP" \
         SHASUM_COUNT="$TMP/race-count" \
         SHASUM_MARKER_DIR="$RACE_TMP/workflow-dev-validate" \
         SHASUM_REPO_HASH="$REPO_HASH" \
         SHASUM_REAL="$REAL_SHASUM" \
         PATH="$RACE_BIN:$PATH" \
         bash "$SCRIPT" <<< "$COMMIT" ) > "$TMP/race-out" 2>&1
# The shim must actually have fired, or this passes for the wrong reason.
[[ "$(cat "$TMP/race-count" 2>/dev/null)" == "2" && -f "$RACE_TMP/workflow-dev-validate/$REPO_HASH.json" ]] \
  && ok "the race shim planted a marker during the hash pass" \
  || no "the race shim planted a marker during the hash pass (count: $(cat "$TMP/race-count" 2>/dev/null))"
RACE_OUT="$(cat "$TMP/race-out")"
[[ -n "$RACE_OUT" ]] && ok "a store appearing mid-pass is not trusted — the gate asks" || no "a store appearing mid-pass is not trusted — the gate asks (got silence)"
case "$RACE_OUT" in
  *"group- or world-writable"*) ok "…and names why" ;;
  *) no "…and names why (got: $RACE_OUT)" ;;
esac

# --- 11: the dialog speaks the conversation's language ------------------------
# The decision never changes with the language; only the words do. English is
# what every section above already pinned (no transcript, empty HOME).
SPANISH_TRANSCRIPT="$TMP/es.jsonl"
jq -cn '{type:"user",message:{role:"user",content:"¿Puedes revisar el plan y decirme qué falta?"}}' > "$SPANISH_TRANSCRIPT"
with_transcript() { printf '%s' "$1" | jq -c --arg p "$2" '. + {transcript_path: $p}'; }
ES_COMMIT="$(with_transcript "$COMMIT" "$SPANISH_TRANSCRIPT")"
rm -f "$MARKER"; chmod 700 "$MARKER_DIR"

JSON_OUT="$(hook "$ES_COMMIT")"
case "$JSON_OUT" in
  *'"permissionDecision":"ask"'*"No hay un registro de /workflow-dev:validate"*) ok "Spanish conversation → the validate ask is in Spanish" ;;
  *) no "Spanish conversation → the validate ask is in Spanish (got: $JSON_OUT)" ;;
esac
printf '%s' "$JSON_OUT" | jq -e . >/dev/null 2>&1 && ok "…and is valid JSON" || no "…and is valid JSON"

printf '{"diffHash":"%s","status":"deferred","at":"2026-09-29T00:00:00Z"}' "$(current_hash)" > "$MARKER"
JSON_OUT="$(hook "$ES_COMMIT")"
case "$JSON_OUT" in
  *'"permissionDecision":"allow"'*"Validación diferida"*) ok "Spanish conversation → the deferred allow is in Spanish" ;;
  *) no "Spanish conversation → the deferred allow is in Spanish (got: $JSON_OUT)" ;;
esac
JSON_OUT="$(hook "$COMMIT")"
case "$JSON_OUT" in
  *'"permissionDecision":"allow"'*"Validation deferred for this task group"*) ok "no language anywhere → the deferred allow stays English" ;;
  *) no "no language anywhere → the deferred allow stays English (got: $JSON_OUT)" ;;
esac
rm -f "$MARKER"

# The untrusted-directory note joins the ask in the same language.
chmod 777 "$MARKER_DIR"
case "$(hook "$ES_COMMIT")" in
  *"No se puede confiar en el directorio de marcadores"*"group- or world-writable"*) ok "Spanish ask → the trust note is Spanish, its detail stays as is" ;;
  *) no "Spanish ask → the trust note is Spanish (got: $(hook "$ES_COMMIT"))" ;;
esac
chmod 700 "$MARKER_DIR"

# Claude Code's language setting answers when the conversation cannot.
mkdir -p "$HOME/.claude"
printf '{"language":"spanish"}' > "$HOME/.claude/settings.json"
case "$(hook "$COMMIT")" in
  *'"permissionDecision":"ask"'*"No hay un registro"*) ok "language setting spanish, no transcript → Spanish" ;;
  *) no "language setting spanish, no transcript → Spanish (got: $(hook "$COMMIT"))" ;;
esac
printf '{"language":"esperanto"}' > "$HOME/.claude/settings.json"
case "$(hook "$COMMIT")" in
  *'"permissionDecision":"ask"'*"No matching /workflow-dev:validate record"*) ok "a language with no text → English, same decision" ;;
  *) no "a language with no text → English (got: $(hook "$COMMIT"))" ;;
esac
printf '{"language":' > "$HOME/.claude/settings.json"
case "$(hook "$(with_transcript "$COMMIT" "$TMP/missing.jsonl")")" in
  *'"permissionDecision":"ask"'*"No matching /workflow-dev:validate record"*) ok "missing transcript + malformed setting → English, same decision" ;;
  *) no "missing transcript + malformed setting → English (got: $(hook "$COMMIT"))" ;;
esac
rm -f "$HOME/.claude/settings.json"

# init records the conversation's language in config.json; it is the last source.
printf '{"gitignored":true,"language":"es"}' > "$PROJ/.workflow-dev/config.json"
case "$(hook "$COMMIT")" in
  *'"permissionDecision":"ask"'*"No hay un registro"*) ok "config.json language es, nothing else → Spanish" ;;
  *) no "config.json language es, nothing else → Spanish (got: $(hook "$COMMIT"))" ;;
esac
rm -f "$PROJ/.workflow-dev/config.json"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
exit $((fail == 0 ? 0 : 1))
