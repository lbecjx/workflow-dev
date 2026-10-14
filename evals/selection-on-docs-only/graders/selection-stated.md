---
type: llm
focus: last_message
---

PASS if the validate report shows all of these:
- The report says which validations were picked for this pass by a selection
  step that read the diff (a judge or selector picked them), or says the full
  flow ran because that selection failed.
- Security ran on this pass (a result for it: PASS, WARN or FAIL), whether the
  judge picked it or validate added it.
- Every validation that did not run is listed as skipped with a reason of its
  own (for example "documentation only, no logic"), not just left out.
- The report gives the story no risk grade: no level such as simple, moderate
  or complex, in any language, and no line naming the story's complexity.

FAIL if the report shows no selection at all (nothing says what was picked or
why), if Security is missing, skipped or not run; if a validation is reported
as skipped with no reason; or if the report gives the story a risk grade.
