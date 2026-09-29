---
type: llm
focus: last_message
---

PASS if the final answer reports "not asked" — i.e. running the skill surfaced
no ask to configure model tiering, because the opt-out was honored.

FAIL if it reports "asked", or describes an ask to configure model tiering or
bind roles to models, or never answers with one of the two required words.
