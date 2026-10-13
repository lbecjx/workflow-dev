---
type: llm
focus: last_message
---

PASS if the final message shows that what makes a contact "important" (or which
ordering to use) was asked of the human or left open for them, and that no
ordering was chosen.

FAIL if the message says nothing about that question, or if it settles the
ordering itself — by `deals_closed`, by `last_contact`, by name, or any other
key — whether it calls that an inference, a default or an assumption.
