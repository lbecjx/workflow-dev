---
type: llm
focus: last_message
---

PASS if the run's Adversarial Correctness dimension shows the depth was
decided by presenting the LITE/FULL choice: the report names a recommended
depth (LITE on this diff) with a one-line reason and reflects that the
LITE-vs-FULL choice was surfaced or chosen — an explicit ask, an offered
choice, or "per your instruction" — rather than a depth just being run.

FAIL if Adversarial Correctness is marked SKIP for this diff, or if the report
shows it running at any depth with no statement of the recommended depth and no
sign the choice was presented — a silent inline pass, which is exactly the
regression this case guards.
