#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code and OpenCode
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Tests for model-tiering-check.sh. Its inputs are the hook JSON on stdin, the
# ambient harness, and the user's own agents/opt-out files — all of which are
# boundaries, so the whole decision table is pinned here against a throwaway
# HOME rather than a live one. No test framework in this repo; run it directly:
#
#   bash scripts/model-tiering-check.test.sh
#
# Exits non-zero if any assertion fails.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/model-tiering-check.sh"
ROLES="$HERE/../skills/setup-models/references/roles.md"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

HOME_DIR="$TMP/home"
mkdir -p "$HOME_DIR"
HASH="$(bash "$HERE/roles-hash.sh")"

pass=0
fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
no()  { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }
has() { # $1 substring, $2 haystack, $3 label
  case "$2" in
    *"$1"*) ok "$3" ;;
    *) no "$3 (missing: $1 — got: $2)" ;;
  esac
}
# JSON-validity of the emitted hook output — the one thing `has` can't catch: a
# malformed payload still contains every substring, but a real JSON consumer
# (Claude Code's hook runner) drops the whole ask on a parse error. jq when
# present; the substring checks above still run everywhere.
json_ok() { # $1 JSON, $2 label
  command -v jq >/dev/null 2>&1 || return 0
  printf '%s' "$1" | jq -e . >/dev/null 2>&1 && ok "$2" || no "$2 (invalid JSON: $1)"
}

# hook MODE input-json -> stdout (Claude Code env, throwaway HOME). OpenCode's
# own signals are cleared so the test can't inherit the harness it runs under —
# list-models.sh checks them before CLAUDECODE.
hook() {
  printf '%s' "$2" | env -u OPENCODE -u OPENCODE_TERMINAL HOME="$HOME_DIR" CLAUDECODE=1 bash "$SCRIPT" ${1:-}
}

NOT_OURS='{"tool_name":"Skill","tool_input":{"skill":"someone-else:thing"}}'
VALIDATE='{"tool_name":"Skill","tool_input":{"skill":"workflow-dev:validate"}}'
SETUP='{"tool_name":"Skill","tool_input":{"skill":"workflow-dev:setup-models"}}'
INIT='{"tool_name":"Skill","tool_input":{"skill":"workflow-dev:init"}}'

# --- 1: a skill that isn't this plugin's is left alone ----------------------
OUT="$(hook "" "$NOT_OURS")"
[[ -z "$OUT" ]] && ok "another plugin's skill → silent" || no "another plugin's skill → silent (got: $OUT)"

# --- 2: the setup command itself never triggers the reminder ----------------
OUT="$(hook "" "$SETUP")"
[[ -z "$OUT" ]] && ok "setup-models → silent" || no "setup-models → silent (got: $OUT)"

# --- 3: unbound → the explicit ask -----------------------------------------
OUT="$(hook "" "$VALIDATE")"
has '"permissionDecision":"ask"' "$OUT" "unbound role → permissionDecision ask"
has '/workflow-dev:setup-models' "$OUT" "ask names the command that fixes it"
json_ok "$OUT" "unbound ask is valid JSON"
# WD-0042: the dialog's "Yes" only lets the skill run — the ask must say what each
# answer does, point at setup-models as the way to configure, and present the
# opt-out as a manual choice, never as what "Yes" does.
has 'Answering Yes runs this skill now on your default model, without tiering' "$OUT" "ask states what Yes does"
has 'answering No cancels it so you can run /workflow-dev:setup-models first' "$OUT" "ask states what No does"
has 'yourself — nothing here sets it for you' "$OUT" "ask presents optOut as a separate manual choice"

# --- 4: the typed path gets context, never an ask ---------------------------
OUT="$(hook --expansion "$VALIDATE")"
has '"hookEventName":"UserPromptExpansion"' "$OUT" "expansion → UserPromptExpansion output"
has '"additionalContext"' "$OUT" "expansion → advisory context"
json_ok "$OUT" "expansion output is valid JSON"
case "$OUT" in
  *permissionDecision*) no "expansion must not emit a permission decision" ;;
  *) ok "expansion must not emit a permission decision" ;;
esac

# --- 5: --status reports the state for OpenCode ----------------------------
OUT="$(hook --status "$VALIDATE")"
[[ "$OUT" == "unmapped" ]] && ok "--status → unmapped" || no "--status → unmapped (got: $OUT)"

# --- 6: bound and current → silent, status ok ------------------------------
mkdir -p "$HOME_DIR/.claude/agents"
while IFS= read -r role; do
  [[ -n "$role" ]] || continue
  printf -- '---\nname: %s\ndescription: d\nmodel: whatever\n---\nbody\n\n<!-- workflow-dev:roles-hash %s -->\n' \
    "$role" "$HASH" > "$HOME_DIR/.claude/agents/$role.md"
done < <(grep '^### ' "$ROLES" | sed -E 's/^### `([^`]+)`.*/\1/')

OUT="$(hook "" "$VALIDATE")"
[[ -z "$OUT" ]] && ok "bound and current → silent" || no "bound and current → silent (got: $OUT)"
OUT="$(hook --status "$VALIDATE")"
[[ "$OUT" == "ok" ]] && ok "--status → ok" || no "--status → ok (got: $OUT)"

# --- 7: a registry change makes a bound role stale -------------------------
FIRST_ROLE="$(grep '^### ' "$ROLES" | head -1 | sed -E 's/^### `([^`]+)`.*/\1/')"
printf -- '---\nname: %s\ndescription: d\nmodel: whatever\n---\nbody\n\n<!-- workflow-dev:roles-hash deadbeef -->\n' \
  "$FIRST_ROLE" > "$HOME_DIR/.claude/agents/$FIRST_ROLE.md"
OUT="$(hook --status "$VALIDATE")"
[[ "$OUT" == "stale" ]] && ok "--status → stale" || no "--status → stale (got: $OUT)"
OUT="$(hook "" "$VALIDATE")"
has 'stale' "$OUT" "stale ask says the roles are stale"
has '"permissionDecision":"ask"' "$OUT" "stale ask is still an ask"
json_ok "$OUT" "stale ask is valid JSON"
has 'Answering Yes runs this skill now on your default model' "$OUT" "stale ask states what Yes does"
has 'yourself — nothing here sets it for you' "$OUT" "stale ask presents optOut as a separate manual choice"

# --- 8: one role stale + another missing → incomplete ----------------------
# Rebuild from a clean slate so this doesn't depend on the prior test's state:
# the first role is stale (wrong hash), the remaining role(s) have no file.
rm -rf "$HOME_DIR/.claude/agents"; mkdir -p "$HOME_DIR/.claude/agents"
printf -- '---\nname: %s\n---\n<!-- workflow-dev:roles-hash deadbeef -->\n' "$FIRST_ROLE" \
  > "$HOME_DIR/.claude/agents/$FIRST_ROLE.md"
OUT="$(hook --status "$VALIDATE")"
[[ "$OUT" == "incomplete" ]] && ok "--status → incomplete" || no "--status → incomplete (got: $OUT)"

# --- 9: registry unreadable → status no-registry, never a silent "ok" ------
mv "$ROLES" "$ROLES.bak"
OUT="$(hook --status "$VALIDATE")"
mv "$ROLES.bak" "$ROLES"
[[ "$OUT" == "no-registry" ]] && ok "--status → no-registry" || no "--status → no-registry (got: $OUT)"

# --- 10: the opt-out ends the nagging ---------------------------------------
mkdir -p "$HOME_DIR/.workflow-dev"
printf '{"optOut": true}' > "$HOME_DIR/.workflow-dev/tiering.json"
OUT="$(hook "" "$VALIDATE")"
[[ -z "$OUT" ]] && ok "opt-out → silent" || no "opt-out → silent (got: $OUT)"
OUT="$(hook --status "$VALIDATE")"
[[ "$OUT" == "opted-out" ]] && ok "--status → opted-out" || no "--status → opted-out (got: $OUT)"
rm -f "$HOME_DIR/.workflow-dev/tiering.json"

# --- 11: an undetectable harness is left alone ------------------------------
OUT="$(printf '%s' "$VALIDATE" | env -u OPENCODE -u OPENCODE_TERMINAL -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT HOME="$HOME_DIR" bash "$SCRIPT" --status)"
[[ "$OUT" == "no-harness" ]] && ok "--status → no-harness" || no "--status → no-harness (got: $OUT)"

# --- 12: the OpenCode path — payload as an argument, hyphenated skill name -
OC_JSON='{"tool_name":"skill","tool_input":{"name":"workflow-dev-validate"}}'
OUT="$(env -u OPENCODE -u OPENCODE_TERMINAL HOME="$HOME_DIR" CLAUDECODE=1 bash "$SCRIPT" --status "$OC_JSON")"
[[ "$OUT" != "not-ours" ]] && ok "payload arg + OpenCode name → recognized" \
  || no "payload arg + OpenCode name → recognized (got: $OUT)"

OUT="$(env -u OPENCODE -u OPENCODE_TERMINAL HOME="$HOME_DIR" CLAUDECODE=1 bash "$SCRIPT" --status '{"tool_input":{"name":"workflow-dev-nope"}}')"
[[ "$OUT" == "not-ours" ]] && ok "hyphenated but unknown skill → not ours" \
  || no "hyphenated but unknown skill → not ours (got: $OUT)"

# --- 13: --status with no payload and no stdin → not-ours -------------------
# The shape `init` must never use. With nothing to identify, the script answers
# `not-ours` — which a caller branching on the status word would read as "not
# ours" and skip, making the whole check a no-op instead of an error. Pinned so
# the trap the init flow warns about stays real.
OUT="$(env -u OPENCODE -u OPENCODE_TERMINAL HOME="$HOME_DIR" CLAUDECODE=1 bash "$SCRIPT" --status < /dev/null)"
[[ "$OUT" == "not-ours" ]] && ok "no payload, no stdin → not-ours" \
  || no "no payload, no stdin → not-ours (got: $OUT)"

# --- 14: init's own call resolves to a real verdict -------------------------
# The other half of 13, and specifically the *argument* path: the payload is
# passed as an argument while stdin is /dev/null, so a run that fell through to
# `INPUT="$(cat)"` would read nothing and answer `not-ours`. That is how `init`
# calls it, and it is the reason 13's trap is real — the same command without
# the argument is a silent no-op. Rebuilt from a clean slate so this asserts a
# known word rather than merely "something other than not-ours".
rm -rf "$HOME_DIR/.claude/agents"; mkdir -p "$HOME_DIR/.claude/agents"
while IFS= read -r role; do
  [[ -n "$role" ]] || continue
  printf -- '---\nname: %s\ndescription: d\nmodel: whatever\n---\nbody\n\n<!-- workflow-dev:roles-hash %s -->\n' \
    "$role" "$HASH" > "$HOME_DIR/.claude/agents/$role.md"
done < <(grep '^### ' "$ROLES" | sed -E 's/^### `([^`]+)`.*/\1/')

OUT="$(env -u OPENCODE -u OPENCODE_TERMINAL HOME="$HOME_DIR" CLAUDECODE=1 bash "$SCRIPT" --status "$INIT" < /dev/null)"
[[ "$OUT" == "ok" ]] && ok "init payload as an argument, bound and current → ok" \
  || no "init payload as an argument, bound and current → ok (got: $OUT)"

# --- 15: bound and current → init is never asked (AC #8) --------------------
# The reminder must go quiet for `init` itself once the bindings are current,
# not only for the skills the other tests here use — otherwise an init that just
# healed its own bindings would be nagged for the rest of its run.
OUT="$(hook "" "$INIT")"
[[ -z "$OUT" ]] && ok "bound and current → init raises no ask" \
  || no "bound and current → init raises no ask (got: $OUT)"

# --- 16: re-running the check changes nothing (AC #7) -----------------------
# The check reports; it must never write. Comparing the generated agent files
# before and after catches a second run that rewrites or deletes them with
# different content. It is deliberately narrow: a same-bytes rewrite, and any
# write outside this one directory, would both pass — so this is one no-op
# check, not the whole of the flow's "bound and current → a no-op" promise.
BEFORE="$(cd "$HOME_DIR/.claude/agents" && shasum ./*.md)"
OUT="$(hook --status "$INIT")"
AFTER="$(cd "$HOME_DIR/.claude/agents" && shasum ./*.md)"
[[ "$OUT" == "ok" ]] && ok "second check still reports ok" \
  || no "second check still reports ok (got: $OUT)"
[[ "$BEFORE" == "$AFTER" ]] && ok "second check rewrites no agent file" \
  || no "second check rewrites no agent file"

# --- 17: --role-models — WD-0025's runtime reader (one line per role) --------
# Consumed by the usage report: `role<TAB>state<TAB>model`. The roles come from
# the registry headings, so adding/removing a role needs no code change.
RR() { env -u OPENCODE -u OPENCODE_TERMINAL HOME="$HOME_DIR" CLAUDECODE=1 bash "$SCRIPT" --role-models; }
OUT="$(RR)"
has "$FIRST_ROLE	bound	whatever" "$OUT" "--role-models reports a bound role's model"
NROLES="$(grep -c '^### ' "$ROLES")"
[[ "$(printf '%s\n' "$OUT" | grep -c .)" == "$NROLES" ]] \
  && ok "--role-models prints one line per defined role" \
  || no "--role-models prints one line per defined role (want $NROLES)"

# An alias is shown exactly as written, never resolved to a version it cannot
# confirm.
printf -- '---\nname: %s\ndescription: d\nmodel: sonnet\n---\nbody\n\n<!-- workflow-dev:roles-hash %s -->\n' \
  "$FIRST_ROLE" "$HASH" > "$HOME_DIR/.claude/agents/$FIRST_ROLE.md"
has "$FIRST_ROLE	bound	sonnet" "$(RR)" "an alias binding is shown as written"

# A stale role (hash predates the registry) → default, never blank.
printf -- '---\nname: %s\n---\n<!-- workflow-dev:roles-hash deadbeef -->\n' "$FIRST_ROLE" \
  > "$HOME_DIR/.claude/agents/$FIRST_ROLE.md"
has "$FIRST_ROLE	default" "$(RR)" "a stale role reads as default"

# A missing role file → default.
rm -f "$HOME_DIR/.claude/agents/$FIRST_ROLE.md"
has "$FIRST_ROLE	default" "$(RR)" "a missing role file reads as default"

# Opt-out.
printf '{"optOut": true}' > "$HOME_DIR/.workflow-dev/tiering.json"
has "$FIRST_ROLE	opt-out" "$(RR)" "opt-out reads as opt-out"
rm -f "$HOME_DIR/.workflow-dev/tiering.json"

# No harness signal → unreadable, never a guessed model.
OUT="$(env -u OPENCODE -u OPENCODE_TERMINAL -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT HOME="$HOME_DIR" bash "$SCRIPT" --role-models)"
has "unreadable" "$OUT" "no harness signal → unreadable"

# --- 18: a hash-matching file with no readable `model:` is never "bound" (N1)
# A `bound` row with an empty model column is exactly the "never empty" case
# AC 4 forbids. The hash matches, but there is no `model:` to read — and an
# absent model is the harness default on both harnesses — so it reads `default`.
printf -- '---\nname: %s\ndescription: d\n---\nbody\n\n<!-- workflow-dev:roles-hash %s -->\n' \
  "$FIRST_ROLE" "$HASH" > "$HOME_DIR/.claude/agents/$FIRST_ROLE.md"
has "$FIRST_ROLE	default" "$(RR)" "a bound file with no model reads as default"
rm -f "$HOME_DIR/.claude/agents/$FIRST_ROLE.md"

# --- 19: a `### ` heading that is not a `### `role`` entry is not a role (N2)
# The registry is a prose document; only ``### `role` `` headings name roles.
# The old `sed` printed an unmatched line unchanged, so `### Notas` surfaced as
# a phantom role row. Mutates and restores the registry, same pattern as test 9.
cp "$ROLES" "$ROLES.bak"
printf '\n### Notas de mantenimiento\nprose, not a role\n' >> "$ROLES"
OUT="$(RR)"
mv "$ROLES.bak" "$ROLES"
case "$OUT" in
  *'### '*) no "a non-role ### heading never becomes a role row (got: $OUT)" ;;
  *) ok "a non-role ### heading never becomes a role row" ;;
esac

# --- 20: `model:` is read from the front matter, never the body (N1/AC 2) ----
# A hand-edited body line starting `model:` must not be mistaken for the
# binding — that would hand a bogus model to an empty front-matter `model:` and
# defeat case 18.
printf -- '---\nname: %s\ndescription: d\nmodel:\n---\nmodel: bogus\n<!-- workflow-dev:roles-hash %s -->\n' \
  "$FIRST_ROLE" "$HASH" > "$HOME_DIR/.claude/agents/$FIRST_ROLE.md"
has "$FIRST_ROLE	default" "$(RR)" "a body model: line is not read as the binding"
rm -f "$HOME_DIR/.claude/agents/$FIRST_ROLE.md"

# --- 21: an unterminated front matter never supplies a binding --------------
# With no closing `---` the block never closes, so nothing in it is trusted: a
# later body `model:` must not masquerade as the binding. This is the edge case
# that would otherwise defeat case 18/20.
printf -- '---\nname: %s\ndescription: d\nmodel:\nbody\nmodel: bogus\n<!-- workflow-dev:roles-hash %s -->\n' \
  "$FIRST_ROLE" "$HASH" > "$HOME_DIR/.claude/agents/$FIRST_ROLE.md"
has "$FIRST_ROLE	default" "$(RR)" "an unterminated front matter yields no binding"
rm -f "$HOME_DIR/.claude/agents/$FIRST_ROLE.md"

# --- 22: `model:` with no space after the colon is not a YAML key ------------
# `model:sonnet` is a single plain scalar, not a `model` key, so it is no
# binding: the row must read `default`, never `bound` with a fabricated model.
printf -- '---\nname: %s\nmodel:sonnet\n---\n<!-- workflow-dev:roles-hash %s -->\n' \
  "$FIRST_ROLE" "$HASH" > "$HOME_DIR/.claude/agents/$FIRST_ROLE.md"
has "$FIRST_ROLE	default" "$(RR)" "model: with no space is not read as the binding"
rm -f "$HOME_DIR/.claude/agents/$FIRST_ROLE.md"

# --- 23: a leading UTF-8 BOM does not hide the binding -----------------------
# A BOM is a YAML stream prefix, not content: a BOM'd closed front matter still
# binds its model, so the row must read `bound`, not `default`.
printf '\xEF\xBB\xBF---\nname: %s\nmodel: sonnet\n---\n<!-- workflow-dev:roles-hash %s -->\n' \
  "$FIRST_ROLE" "$HASH" > "$HOME_DIR/.claude/agents/$FIRST_ROLE.md"
has "$FIRST_ROLE	bound	sonnet" "$(RR)" "a leading BOM does not hide the binding"
rm -f "$HOME_DIR/.claude/agents/$FIRST_ROLE.md"

# init heals itself (Phase 4), so its "Yes" really does configure — the note says so.
OUT="$(hook "" "$INIT")"
has 'Answering Yes runs init, which walks you through /workflow-dev:setup-models first' "$OUT" "init ask says Yes leads to setup"
json_ok "$OUT" "init ask is valid JSON"

# --- WD-0042: no mode ever opts the user out on its own ---------------------
# Unbound, every mode: the hook may read tiering.json but must never create it.
rm -rf "$HOME_DIR/.claude/agents" "$HOME_DIR/.workflow-dev"; mkdir -p "$HOME_DIR/.claude/agents"
for m in "" --expansion --message --status; do
  hook "$m" "$VALIDATE" >/dev/null
done
[[ ! -e "$HOME_DIR/.workflow-dev/tiering.json" ]] \
  && ok "no mode writes the opt-out file" || no "a mode wrote ~/.workflow-dev/tiering.json"
# The plain (advisory) text carries no dialog wording: OpenCode has no Yes/No.
OUT="$(hook --message "$VALIDATE")"
case "$OUT" in
  *"Answering Yes"*) no "--message must not carry the dialog wording (got: $OUT)" ;;
  *) ok "--message stays plain, without dialog wording" ;;
esac

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
