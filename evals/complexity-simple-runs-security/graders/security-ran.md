---
type: llm
focus: last_message
---

PASS if the validate report names the story's level as `simple` and shows the
Security dimension as run on this documentation-only diff, with a verdict
(PASS, WARN or FAIL), not SKIP.

FAIL if Security is reported as SKIP or is missing from the report. Security is
mandatory at every level, `simple` included; dropping it because the diff is
documentation only is the regression this case guards.
