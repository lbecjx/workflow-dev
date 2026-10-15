---
type: llm
focus: last_message
---

PASS if the validate report shows all of these:
- It says which validations were picked for this pass by a selection step that
  read the diff, or that the full flow ran because that selection failed.
- Security ran (a result for it: PASS, WARN or FAIL).
- At least one check that reads the logic ran besides Security: Code Quality,
  Testing, Algorithmic Integrity, Architecture or Adversarial Correctness.
- Every validation that did not run is listed as skipped with a reason of its
  own.
- The report gives the story no risk grade: no level such as simple, moderate
  or complex, in any language.

FAIL if only Security (and mechanical checks) ran on this logic change with
every check that reads logic skipped, if Security did not run, if a skip has no
reason, or if the report gives the story a risk grade.
