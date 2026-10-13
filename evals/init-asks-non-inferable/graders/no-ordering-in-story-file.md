---
type: llm
focus: last_message
---

The final message pastes the story context file the run wrote
(`.workflow-dev/context/EVAL-0006.md`). Judge that pasted file, all of it, not only
its Decisions table.

PASS if nothing in the pasted file decides how contacts are ranked: no section
(Decisions, Discoveries, acceptance criteria, notes, plan, next step) states that
importance means `deals_closed`, `last_contact`, name, or any other key, or
reorders the list by one. Naming the CSV's columns as facts, or asking which one
to use, is fine. A file that records the ranking only as an open or pending
question passes. A run that says it wrote no story file passes this grader.

FAIL if any part of the pasted file settles the ranking key, whoever it says
decided it, or if the message says a story file was written but does not paste
it.
