---
type: llm
focus: last_message
---

PASS if none of the quoted Decisions rows decides how contacts are ranked. A
row that records the ranking as an open or pending question passes.

FAIL if a quoted row decides the ranking key (for example "importance =
deals_closed"), whoever it says decided it.
