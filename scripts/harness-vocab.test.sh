#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Guards the rule in ../references/harness-tools.md: shipped text names the
# **capability**, and never presents one harness's tool name as the universal way
# to do something. A file MAY say `Bash` or `AskUserQuestion` — but only next to
# the environment it belongs to. Bare, it reads as the name everywhere.
#
# --- What this guard measured, and the claim it used to make -------------------
#
# The first version of this guard scanned `skills/` only, and justified itself
# with "bare, it reads as the name everywhere, which is exactly how an agent under
# OpenCode ends up calling a tool that isn't there". The 2026-09-29 forensics in
# WD-0016 **refuted that**: no shipped skill ever named `Bash` as the shell. The
# two real `bash` events followed reading *other* text — `.workflow-dev/context/
# REPO.md` §3, whose `# PreToolUse:Bash` comments are factually correct for Claude
# Code. So the guard now scans the shipped tree, and the files it deliberately
# does NOT scan are listed below with the reason.
#
# That exclusion list is also the honest statement of what no wording guard can
# protect: correct Claude-Code vocabulary in a file an agent reads is not a leak,
# so the vector that actually fired is outside this guard by its nature — not by
# oversight. Closing that vector needs a mechanism, not wording (see WD-0016 and
# the prevention story it points at).
#
# --- Scope: what is scanned, what is not, and why ------------------------------
#
# Everything shipped is scanned, `evals/*/prompt.md` included: each
# `allowed_tools` line carries a comment naming the environment, so its Claude
# Code names pass the same check as everywhere else (WD-0016 TG3). The values
# stay Claude Code names — that is the eval runner's vocabulary, and the comment
# is what records the mismatch.
#
# Excluded, each with the reason it is out of scope:
#   CHANGELOG.md    historical record. It describes past Claude-Code-only
#                   behaviour; rewriting history to dodge a guard is worse than
#                   the guard not seeing it.
#   .workflow-dev/  this repo's own dev context, not shipped to a consumer — and
#   local-backlog/  it is exactly where the measured vector lives (above).
#   .git/, node_modules/   never shipped.
#
# Two tokens only, deliberately. The story also lists `Read`, `Write`, `Edit`,
# `Glob`, `Grep`, `Agent` and `Task` as names not to present as universal, and
# this script does not check them: every one is ordinary English in these files
# ("Read every file", "Task Group 1", "Agent Roles"), so matching them would
# fail on the plan's own vocabulary rather than on a leak. Those are reviewed by
# hand; only the two unambiguous tokens are mechanical.
#
#   bash scripts/harness-vocab.test.sh
#
# Exits non-zero if any occurrence stands alone. It also self-checks the things a
# guard of this shape gets wrong if nothing tests them: that a bare name fails
# *and says where*, that an unreadable or empty tree fails instead of reading as
# clean, that a qualified name still passes (so it can't be a blanket reject), and
# that an allowlisted path is genuinely skipped (so the exclusion can't silently
# widen). HARNESS_VOCAB_ROOT overrides the tree under test — used by those
# self-checks, never for a normal run.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
if [ -n "${HARNESS_VOCAB_ROOT:-}" ]; then
  ROOT="$HARNESS_VOCAB_ROOT"
else
  # `cd -P` is what makes the paths in a failure actionable, and it is the
  # repo's own idiom for resolving a plugin path through a skill symlink. The
  # plugin root is `skills/`'s parent; see the scope note above for the exclusions.
  ROOT="$(cd -P "$HERE/.." && pwd)"
fi

# One place for what the token scan skips. Each entry has its reason in the
# header — keep them in step, because an exclusion that outlives its reason is
# how a guard quietly stops covering what it claims to cover.
EXCLUDES=(--exclude-dir=.git --exclude-dir=.workflow-dev --exclude-dir=local-backlog
          --exclude-dir=node_modules --exclude=CHANGELOG.md)

pass=0
fail=0
ok() { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }

# A tree nobody can read is not a clean tree. `grep` exits 2 for a missing path
# and 1 for no match, and folding both into "found nothing" would turn this
# guard green in precisely the situation where it is blind — a renamed
# directory, a bad ROOT, a permissions change.
if [ ! -r "$ROOT" ]; then
  no "cannot read the tree under test: $ROOT"
  printf '\n%s passed, %s failed\n' "$pass" "$fail"
  exit 1
fi

# Nor is an empty tree a clean one. A renamed or misspelled directory that still
# exists (an empty leftover) is readable and match-free, so the check above lets
# it through and both tokens report "0 occurrence(s)" as a pass.
if ! find "$ROOT" -type f -name '*.md' -print -quit | grep -q .; then
  no "no markdown under the tree under test: $ROOT — a clean tree is not an empty one"
  printf '\n%s passed, %s failed\n' "$pass" "$fail"
  exit 1
fi

# A name is only "presented as universal" when nothing in its neighbourhood says
# which environment it belongs to. The window is ±2 lines — room for the clause
# that qualifies it (the name is usually the second half of the sentence), small
# enough that a mention further away can't launder it. The four markers are the
# words these files actually use to name an environment; `harness` and
# `environment` are in the set because the skills say "whatever the environment
# calls it" instead of naming a product.
CONTEXT=2
MARKERS='Claude Code|OpenCode|harness|environment'

check_token() {
  local token="$1" hits=0 orphans=0 hit file line from to
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    hits=$((hits + 1))
    file="${hit%%:*}"; line="${hit#*:}"; line="${line%%:*}"
    from=$((line > CONTEXT ? line - CONTEXT : 1))
    to=$((line + CONTEXT))
    if ! sed -n "${from},${to}p" "$file" | grep -qE "$MARKERS"; then
      no "$token at $file:$line — no environment named nearby"
      orphans=$((orphans + 1))
    fi
  done < <(grep -rnF "$token" "$ROOT" --include='*.md' "${EXCLUDES[@]}" 2>/dev/null)
  [ "$orphans" -eq 0 ] && ok "$token: $hits occurrence(s), each naming its environment"
}

check_token 'AskUserQuestion'
check_token 'Bash'

# --- self-checks: the guard has to be able to fail, and to pass -------------
if [ -z "${HARNESS_VOCAB_ROOT:-}" ]; then
  FIXTURE="$(mktemp -d)" || FIXTURE=""
  if [ -z "$FIXTURE" ]; then
    no "self-check: mktemp -d failed"
  else
    trap 'rm -rf "$FIXTURE"' EXIT

    # 1. a bare name fails, and the failure has to say which file and line —
    #    an unrelated crash (missing sed, a syntax error) must not score the
    #    same as correct orphan detection.
    mkdir -p "$FIXTURE/bad/skills/demo"
    printf 'Run this with Bash.\n' > "$FIXTURE/bad/skills/demo/SKILL.md"
    printf 'Ask via AskUserQuestion.\n' > "$FIXTURE/bad/skills/demo/other.md"
    out="$(HARNESS_VOCAB_ROOT="$FIXTURE/bad" bash "$0" 2>&1)"
    rc=$?
    case "$out" in
      *"demo/SKILL.md:"*) ok "self-check: a bare name fails, naming the file and line" ;;
      *) no "self-check: a bare name must fail naming the file — got: $(printf '%s' "$out" | tail -1)" ;;
    esac
    case "$out" in
      *"demo/other.md:"*) ok "self-check: the second token is checked too" ;;
      *) no "self-check: \`AskUserQuestion\` must be checked too — got: $(printf '%s' "$out" | tail -1)" ;;
    esac
    [ "$rc" -ne 0 ] && ok "self-check: a bare name exits non-zero" \
      || no "self-check: a bare name must exit non-zero"

    # 2. a tree that cannot be read is a failure, never a clean pass.
    if HARNESS_VOCAB_ROOT="$FIXTURE/does-not-exist" bash "$0" >/dev/null 2>&1; then
      no "self-check: an unreadable tree must fail, not pass"
    else
      ok "self-check: an unreadable tree fails"
    fi

    # 3. an empty tree is readable and match-free — it must fail too, or a
    #    renamed directory left behind as an empty directory reads as clean.
    mkdir -p "$FIXTURE/empty/skills"
    if HARNESS_VOCAB_ROOT="$FIXTURE/empty" bash "$0" >/dev/null 2>&1; then
      no "self-check: an empty tree must fail, not pass"
    else
      ok "self-check: an empty tree fails"
    fi

    # 4. a name qualified by its environment passes — otherwise this guard
    #    could be a blanket reject and still look green on the real tree.
    mkdir -p "$FIXTURE/good/skills/demo"
    printf 'Run it with `Bash` in Claude Code, `shell` on OpenCode, or whatever\n' > "$FIXTURE/good/skills/demo/SKILL.md"
    printf 'the environment calls it.\n' >> "$FIXTURE/good/skills/demo/SKILL.md"
    if HARNESS_VOCAB_ROOT="$FIXTURE/good" bash "$0" >/dev/null 2>&1; then
      ok "self-check: a name qualified by its environment passes"
    else
      no "self-check: a name qualified by its environment must pass"
    fi

    # 5. an allowlisted path is genuinely skipped. Without this, an exclusion
    #    added for a good reason can widen into "the guard no longer looks at
    #    anything outside skills/" and still report green — which is the exact
    #    failure the scope note in the header exists to prevent.
    mkdir -p "$FIXTURE/allow/skills/demo"
    printf 'Run it with `Bash` in Claude Code.\n' > "$FIXTURE/allow/skills/demo/SKILL.md"
    printf 'a plain Bash tool call has no way to learn a thing\n' > "$FIXTURE/allow/CHANGELOG.md"
    if HARNESS_VOCAB_ROOT="$FIXTURE/allow" bash "$0" >/dev/null 2>&1; then
      ok "self-check: an allowlisted path with a bare name is skipped"
    else
      no "self-check: an allowlisted path must be skipped — got: $(HARNESS_VOCAB_ROOT="$FIXTURE/allow" bash "$0" 2>&1 | grep FAIL | head -1)"
    fi
  fi
fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
