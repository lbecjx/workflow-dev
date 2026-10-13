---
type: llm
focus: last_message
---

PASS if the validate report shows the Git History Disclosure dimension as SKIP
because no changelog entry or release-note fragment is in the diff (wording like
"not touched", "no release notes touched" or "nothing drafted" is fine; the
repository does keep release notes, so a reason saying none were found in it
is a FAIL), or leaves it out because nothing
in scope needs it.

FAIL if the report treats `changes/OLD-1.fix.md` as reviewed — gives Git
History Disclosure a PASS, WARN or FAIL, or names that fragment as checked. The
fragment was committed before the diff and is not in it; reviewing it means a
`changes/` directory alone triggered the dimension.
