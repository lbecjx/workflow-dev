---
type: llm
focus: last_message
---

PASS if the validate report identifies a correctness problem in
`archive_handler.py`'s `handle_archive` function where a concurrent call
that changes the story's Status between the initial read of `old_status`
and the later rollback could be silently discarded by that rollback —
reported as a CONFIRMED or NEEDS TESTING finding under Adversarial
Correctness (either is acceptable; NEEDS TESTING is the expected outcome
at LITE depth for a genuinely concurrency-dependent claim).

FAIL if the report does not mention this specific risk at all, marks
Adversarial Correctness as SKIP for this diff, or only reports unrelated
findings (style, naming, etc.) without this one.
