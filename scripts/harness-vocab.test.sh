#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code and OpenCode
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
# oversight. Closing that vector needs a mechanism, not wording.
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
# **The exclusion list defines the scan, including its emptiness check.** The same
# `EXCLUDES` array feeds both the file list and the check that the list is not
# empty, so a tree whose only Markdown is excluded (say, a lone `CHANGELOG.md`)
# fails as empty rather than passing as clean. Keeping those two in step is the
# point: an earlier version counted every `*.md` for emptiness but skipped some
# for matching, so an excluded-only tree reported a green `0 occurrence(s)`.
#
# **A scan that cannot read the tree fails; it does not report clean.** `grep`
# exits 0 for a match, 1 for no match, and 2 for an error (an unreadable
# subdirectory, an I/O error). Folding 2 into 1 — which `2>/dev/null` alone does —
# turns this guard green in exactly the situation where it is blind. Both greps
# are therefore status-checked: the recursive listing that builds the file list,
# and the per-file scan that finds the hits. Either one erroring fails loudly.
#
# Two tokens only, deliberately. The story also lists `Read`, `Write`, `Edit`,
# `Glob`, `Grep`, `Agent` and `Task` as names not to present as universal, and
# this script does not check them: every one is ordinary English in these files
# ("Read every file", "Task Group 1", "Agent Roles"), so matching them would
# fail on the plan's own vocabulary rather than on a leak. Those are reviewed by
# hand; only the two unambiguous tokens are mechanical.
#
# **A false positive here is loud, on purpose.** The tokens match as fixed
# strings, so a `Bash` used as the *language name* — "written in Bash" — with no
# harness or mapping reference inside the window fails the guard. That is the
# right direction to be wrong in: the remedy is one word (name the harness, point
# at the mapping, or say "shell scripts"), while a guard that stayed quiet on a
# real leak to avoid an occasional awkward sentence would have the trade
# backwards.
#
#   bash scripts/harness-vocab.test.sh
#
# Exits non-zero if any occurrence stands alone. It also self-checks the things a
# guard of this shape gets wrong if nothing tests them: that a bare name fails
# *and says where*, that a tree the scan cannot read fails instead of reading as
# clean, that an empty or excluded-only tree fails, that a qualified name still
# passes (so it can't be a blanket reject), that a bare name **outside `skills/`**
# is still caught (the scope this guard claims), that the ±2-line window is the
# one it says it is, and that an allowlisted path is genuinely skipped (so the
# exclusion can't silently widen). HARNESS_VOCAB_ROOT overrides the tree under
# test — used by those self-checks, never for a normal run.

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

# A name is only "presented as universal" when nothing in its neighbourhood says
# which environment it belongs to. The window is ±2 lines — room for the clause
# that qualifies it (the name is usually the second half of the sentence), small
# enough that a mention further away can't launder it. The markers are what the
# acceptance criterion actually asks for: a **harness named** (Claude Code,
# OpenCode) or a **pointer to the shared mapping** (`harness-tools`). Generic
# words like "environment" used to be accepted here and were dropped: "set up the
# environment" qualified a bare `Bash` while naming no harness and pointing
# nowhere, which is a false negative in the one direction this guard must not fail.
CONTEXT=2
MARKERS='Claude Code|OpenCode|harness-tools'

# A tree nobody can read is not a clean tree. `[ -r ]` covers only the root
# itself; the recursive listing below is what catches an unreadable subtree.
if [ ! -r "$ROOT" ]; then
  no "cannot read the tree under test: $ROOT"
  printf '\n%s passed, %s failed\n' "$pass" "$fail"
  exit 1
fi

# The scannable files, from the same exclusions the token check uses — so the
# emptiness check below can never disagree with the scan about what counts.
# `-a` keeps a stray NUL byte from turning a file into an unparsable
# "Binary file … matches" line; grep still reports line numbers either way.
ERRFILE="$(mktemp)" || ERRFILE=""
if [ -z "$ERRFILE" ]; then
  no "cannot create a temp file for the scan's error output"
  printf '\n%s passed, %s failed\n' "$pass" "$fail"
  exit 1
fi
SCAN_ERR="$ERRFILE.scan"
trap 'rm -f "$ERRFILE" "$SCAN_ERR"' EXIT

FILES="$(grep -rlF -a -e '' "$ROOT" --include='*.md' "${EXCLUDES[@]}" 2>"$SCAN_ERR")"
rc=$?
if [ "$rc" -gt 1 ]; then
  # 0 = found files, 1 = found none, >1 = grep could not finish. A tree the scan
  # cannot read must fail here, not read as "found nothing".
  no "the scan could not read the tree under test (grep exit $rc): $(head -1 "$SCAN_ERR")"
  printf '\n%s passed, %s failed\n' "$pass" "$fail"
  exit 1
fi

# Nor is an empty tree a clean one. A renamed or misspelled directory that still
# exists (an empty leftover) is readable and match-free, and so is a tree whose
# only Markdown is excluded — both would otherwise report "0 occurrence(s)" as a
# pass. This uses the same file list the token scan walks, deliberately.
if [ -z "$FILES" ]; then
  no "no scannable markdown under the tree under test: $ROOT — a clean tree is not an empty one"
  printf '\n%s passed, %s failed\n' "$pass" "$fail"
  exit 1
fi

# A hit is read per file, from `grep -n`'s `LINE:text` — never from a combined
# `path:LINE:text`. A checkout path containing a colon (legal on APFS and ext4)
# would otherwise be split at the wrong colon and leave the line number
# unparsable; keeping the path out of the parsed string removes the whole class.
# The numeric guard is the backstop: an unexpected shape fails loudly instead of
# reaching the arithmetic below as a non-number.
check_token() {
  local token="$1" hits=0 orphans=0 f l out rc line from to
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    # The per-file scan's status is checked for the same reason the listing's is:
    # a file the scan cannot read must fail loudly rather than score as "no
    # match". This is also what catches a name that arrived split — `$FILES` is
    # newline-delimited, so a path containing a newline reaches here as fragments
    # that do not exist, and grep exits 2 instead of reporting a clean zero.
    out="$(grep -nF -a "$token" "$f" 2>/dev/null)"
    rc=$?
    if [ "$rc" -gt 1 ]; then
      no "$token in $f — the scan could not read it (grep exit $rc)"
      orphans=$((orphans + 1))
      continue
    fi
    while IFS= read -r l; do
      [ -n "$l" ] || continue
      line="${l%%:*}"
      case "$line" in
        ''|*[!0-9]*)
          no "$token in $f — unparsable grep line: $l"
          orphans=$((orphans + 1))
          continue
          ;;
      esac
      hits=$((hits + 1))
      from=$((line > CONTEXT ? line - CONTEXT : 1))
      to=$((line + CONTEXT))
      if ! sed -n "${from},${to}p" "$f" | grep -qE "$MARKERS"; then
        no "$token at $f:$line — no harness or mapping reference nearby"
        orphans=$((orphans + 1))
      fi
    done <<< "$out"
  done <<< "$FILES"
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
    trap 'chmod -R u+rwX "$FIXTURE" 2>/dev/null; rm -f "$ERRFILE" "$SCAN_ERR"; rm -rf "$FIXTURE"' EXIT

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

    # 2. a name outside `skills/` is caught: the scope this version widened to.
    #    Without this, narrowing the scan back to `skills/` would still pass
    #    every other check — the widening would be untested and could regress.
    mkdir -p "$FIXTURE/wide/skills/demo"
    printf 'Run it with `Bash` in Claude Code.\n' > "$FIXTURE/wide/skills/demo/SKILL.md"
    printf 'Spawn it with Bash.\n' > "$FIXTURE/wide/notes.md"
    if HARNESS_VOCAB_ROOT="$FIXTURE/wide" bash "$0" 2>&1 | grep -q "notes.md:"; then
      ok "self-check: a bare name outside skills/ is caught"
    else
      no "self-check: a bare name in a scanned non-skills/ path must be caught"
    fi

    # 3. a tree the scan cannot read is a failure, never a clean pass — and the
    #    tree here is *unreadable*, not merely absent (check 5), because
    #    `2>/dev/null` and a permission problem is what previously reported
    #    clean. Root can read anything, so this is skipped when running as root.
    if [ "$(id -u)" -eq 0 ]; then
      ok "self-check: unreadable-subtree case skipped (running as root)"
    else
      mkdir -p "$FIXTURE/denied/skills/secret"
      printf 'Run it with `Bash` in Claude Code.\n' > "$FIXTURE/denied/skills/ok.md"
      printf 'Run this with Bash.\n' > "$FIXTURE/denied/skills/secret/SKILL.md"
      chmod 000 "$FIXTURE/denied/skills/secret"
      if HARNESS_VOCAB_ROOT="$FIXTURE/denied" bash "$0" >/dev/null 2>&1; then
        no "self-check: an unreadable subtree must fail, not pass"
      else
        ok "self-check: an unreadable subtree fails"
      fi
      chmod 700 "$FIXTURE/denied/skills/secret"
    fi

    # 4. an excluded-only tree is readable and match-free, but it is not clean:
    #    its one Markdown file is out of scope by design, so the scan has nothing
    #    to say. It must fail as empty rather than report a green "0 occurrence(s)".
    mkdir -p "$FIXTURE/excluded"
    printf 'a plain Bash tool call has no way to learn a thing\n' > "$FIXTURE/excluded/CHANGELOG.md"
    if HARNESS_VOCAB_ROOT="$FIXTURE/excluded" bash "$0" >/dev/null 2>&1; then
      no "self-check: an excluded-only tree must fail, not pass"
    else
      ok "self-check: an excluded-only tree fails"
    fi

    # 5. a tree that does not exist at all must fail, distinctly from #3.
    if HARNESS_VOCAB_ROOT="$FIXTURE/does-not-exist" bash "$0" >/dev/null 2>&1; then
      no "self-check: a missing tree must fail, not pass"
    else
      ok "self-check: a missing tree fails"
    fi

    # 6. an empty tree: a directory with no Markdown anywhere.
    mkdir -p "$FIXTURE/empty/skills"
    if HARNESS_VOCAB_ROOT="$FIXTURE/empty" bash "$0" >/dev/null 2>&1; then
      no "self-check: an empty tree must fail, not pass"
    else
      ok "self-check: an empty tree fails"
    fi

    # 7. a name qualified by its environment passes — otherwise this guard
    #    could be a blanket reject and still look green on the real tree.
    mkdir -p "$FIXTURE/good/skills/demo"
    printf 'Run it with `Bash` in Claude Code, `shell` on OpenCode, or whatever\n' > "$FIXTURE/good/skills/demo/SKILL.md"
    printf 'the environment calls it.\n' >> "$FIXTURE/good/skills/demo/SKILL.md"
    if HARNESS_VOCAB_ROOT="$FIXTURE/good" bash "$0" >/dev/null 2>&1; then
      ok "self-check: a name qualified by its environment passes"
    else
      no "self-check: a name qualified by its environment must pass"
    fi

    # 8. the window is the ±2 lines the header claims, no wider and no narrower:
    #    a marker exactly at the edge qualifies, one line beyond it does not.
    mkdir -p "$FIXTURE/window/edge" "$FIXTURE/window/past"
    printf '# Claude Code\n\nRun this with Bash.\n' > "$FIXTURE/window/edge/SKILL.md"
    if HARNESS_VOCAB_ROOT="$FIXTURE/window/edge" bash "$0" >/dev/null 2>&1; then
      ok "self-check: a marker at the window edge qualifies"
    else
      no "self-check: a marker 2 lines above must qualify (±2 is inclusive)"
    fi
    mkdir -p "$FIXTURE/window/far"
    printf '# Claude Code\n\n\n\nRun this with Bash.\n' > "$FIXTURE/window/far/SKILL.md"
    if HARNESS_VOCAB_ROOT="$FIXTURE/window/far" bash "$0" >/dev/null 2>&1; then
      no "self-check: a marker beyond the window must not qualify"
    else
      ok "self-check: a marker beyond the window does not qualify"
    fi

    # 9. an allowlisted path is genuinely skipped. Without this, an exclusion
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

    # 10. an excluded *directory* is skipped too. Exercise it, because otherwise
    #     only `CHANGELOG.md` proves any exclusion at all and a typo in one of
    #     the `--exclude-dir` entries would widen the guard's noise silently.
    #     `local-backlog` stands in for the group; a `.workflow-dev` typo would
    #     still be caught by the real tree, and `.git`/`node_modules` are
    #     never-scanned by construction.
    mkdir -p "$FIXTURE/xdir/skills/demo" "$FIXTURE/xdir/local-backlog"
    printf 'Run it with `Bash` in Claude Code.\n' > "$FIXTURE/xdir/skills/demo/SKILL.md"
    printf 'a plain Bash tool call has no way to learn a thing\n' > "$FIXTURE/xdir/local-backlog/notes.md"
    if HARNESS_VOCAB_ROOT="$FIXTURE/xdir" bash "$0" >/dev/null 2>&1; then
      ok "self-check: an excluded directory with a bare name is skipped"
    else
      no "self-check: an excluded directory must be skipped — got: $(HARNESS_VOCAB_ROOT="$FIXTURE/xdir" bash "$0" 2>&1 | grep FAIL | head -1)"
    fi
  fi
fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
