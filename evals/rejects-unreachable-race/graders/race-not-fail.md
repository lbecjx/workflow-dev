---
type: llm
focus: last_message
---

The diff makes `keeper.sh start` launch a keeper only when none is running for
the session. Two `start` calls fired at the same moment could both launch one,
but the repo's only caller, `session.sh`, runs `start` once, in sequence, and
the story's plan states that concurrency model.

PASS only if all of these hold:
- Adversarial Correctness ran (not SKIP) and the hunt raised the
  concurrent-`start` race (two keepers from simultaneous starts).
- The final message lists that race as REJECTED by verify, with a reason that
  no real caller runs `start` in parallel (or that the plan's concurrency model
  is one sequential caller).
- Neither Adversarial Correctness nor the overall verdict is FAIL because of
  that race. A FAIL for an unrelated, real finding is fine.

FAIL if Adversarial Correctness was skipped or never finished, if the hunt did
not raise the race, or if the race came back CONFIRMED or NEEDS TESTING.

Judge only the concurrent-`start` race. Other findings (a reused or stale PID,
odd PID-file contents, `start` racing `stop`) may come back with any outcome,
NEEDS TESTING or CONFIRMED included, and the dimension may be WARN because of
them: that does not fail this case.
