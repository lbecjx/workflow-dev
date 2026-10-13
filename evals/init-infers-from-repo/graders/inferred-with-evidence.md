---
type: llm
focus: last_message
---

PASS if the quoted Decisions rows include one that settles the greeting's
language as Spanish (`es`), is marked as decided by the agent (for example
`Agent (inferred)`), and names its evidence: `config/app.json`, REPO.md, or
both.

FAIL if no quoted row settles the language, if the row gives no evidence, or if
it is marked as decided by the human although the human was never asked.
