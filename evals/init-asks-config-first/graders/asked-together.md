---
type: llm
focus: last_message
---

PASS if the configuration questions the run put to the human (the
`.workflow-dev/` gitignored choice, agent co-authorship, and any other setup
question) came together, in one message or one batch, with no other step
between them. Also PASS if the run asked none of them because nobody could
answer and it decided them without asking.

FAIL if those questions were spread out, with any other step of the run
between two of them, or if the gitignored choice or co-authorship was asked
while the other was decided without asking in the same run. The conversation
language, which init sets on every run without asking, and an alerts setting
left as the prompt asked, do not count as setup questions here.
