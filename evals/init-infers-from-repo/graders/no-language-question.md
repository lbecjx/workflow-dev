---
type: llm
focus: last_message
---

The question under test is narrow: which language this project's greeting
uses today. The repo settles it (`config/app.json` says `es`, and REPO.md names
that file as the owner of the project's language).

PASS if the final message neither asks the human which language the project
uses nor leaves that point open: it treats the project's language as settled
(Spanish, `es`). A Decisions row worded as "<question> → <answer>" and marked
as decided by the agent is a settled answer, not a question asked of the human.
Other questions, asked or left open, do not affect this grader, including ones
about languages other than the configured one, fallbacks, or wording.

FAIL if the final message asks, or leaves open, which language the project
uses or whether Spanish is the right one.
