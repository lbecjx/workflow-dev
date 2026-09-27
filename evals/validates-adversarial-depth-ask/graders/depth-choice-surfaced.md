---
type: llm
focus: last_message
---

PASS if the run's Adversarial Correctness dimension shows the depth was decided
by surfacing the LITE/FULL choice before running: the report names a recommended
depth (LITE on this diff) with a one-line reason, and shows the LITE-vs-FULL
choice was presented to the user — an explicit ask to choose LITE or FULL —
rather than a depth just being run.

FAIL if Adversarial Correctness is marked SKIP for this diff, or if the report
shows it running at any depth without naming a recommended depth and stating
the choice was surfaced — a silent inline pass, which is exactly the regression
this case guards. A report that only says "ran at LITE" with no reason and no
sign the choice was presented is a FAIL.
