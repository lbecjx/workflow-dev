#!/bin/bash
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Tests that every evals/*/case.yaml is one YAML document. `claude plugin eval`
# refuses a case.yaml that holds a second document ("case.yaml must be a YAML
# object") and drops that case from the run. The other cases still run and
# score, and the refusal is one line among their results, so it is easy to
# miss, and no CI job runs the eval suite. Three cases added in #99 carried a
# second document (the run settings, which belong in prompt.md's frontmatter)
# and never ran until WD-0095. This test runs on every push, so the shape is
# caught there.
#
# The check reads the file with awk, not a YAML parser: jq cannot read YAML,
# and nothing guarantees PyYAML on the CI image. It counts document markers at
# column 0 (`---` or `...`, alone or followed by a space, a tab or a comment;
# a CRLF line ending is stripped first). One `---` before any content is the
# optional start marker of the single document, after blank lines, comments or
# `%` directives; any other marker means a second document. The awk errs toward
# failing: an unusual but valid file fails with its name, it never passes a
# file the runner would refuse.
# Run directly: bash .github/scripts/evals-case-shape.test.sh

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/test-lib.sh"

EVALS="$HERE/../../evals"

# separators <file>: how many document markers the file has beyond the optional
# start marker of its one document. Every CR becomes a line break first (`tr`),
# so a CRLF or lone-CR file reads like an LF one: awk splits on LF only, and
# BSD awk has no regex record separator. A `...` end marker counts only when
# content follows it, since a trailing `...` closes the one document.
separators() {
  tr '\r' '\n' < "$1" | awk '
    /^---([ \t]|$)/ {
      if (!content && !started) {
        started = 1
        rest = substr($0, 4); sub(/^[ \t]+/, "", rest)
        if (rest != "" && rest !~ /^#/) content = 1
        next
      }
      n++; ended = 0; next
    }
    /^\.\.\.([ \t]|$)/ { ended = 1; next }
    /^[ \t]*$/ || /^[ \t]*#/ { next }
    !content && /^%/ { next }
    { if (ended) { n++; ended = 0 }; content = 1 }
    END { print n + 0 }'
}

found=0
for f in "$EVALS"/*/case.yaml; do
  [[ -f "$f" ]] || continue
  found=$((found + 1))
  name="$(basename "$(dirname "$f")")"
  check "$name/case.yaml is one YAML document" test "$(separators "$f")" -eq 0
done

check "at least one evals/*/case.yaml was found" test "$found" -gt 0

# The check itself. The four "caught" shapes are ones `claude plugin eval`
# refused when measured on 2026-10-13; the "allowed" ones are valid single
# documents.
# shape <label> <expected count> <printf format>
shape() {
  printf -- "$3" > "$TMP/shape.yaml"
  check "$1" test "$(separators "$TMP/shape.yaml")" -eq "$2"
}
shape "a second document is caught" 1 'name: x\n---\nmax_turns: 1\n'
shape "a separator with a comment is caught" 1 'name: x\n--- # run settings\nmax_turns: 1\n'
shape "a CRLF separator is caught" 1 'name: x\r\n---\r\nmax_turns: 1\r\n'
shape "a lone-CR separator is caught" 1 'name: x\r---\rmax_turns: 1\r'
shape "a document after an end marker is caught" 1 'name: x\n...\nmax_turns: 1\n'
shape "a leading start marker is allowed" 0 '---\nname: x\n'
shape "a trailing end marker is allowed" 0 'name: x\n...\n# done\n'
shape "a start marker after a comment is allowed" 0 '# header\n---\nname: x\n'
shape "a start marker after a directive is allowed" 0 '%%YAML 1.2\n---\nname: x\n'
shape "an indented --- inside a block scalar is allowed" 0 'description: >\n  ---\nname: x\n'

finish
