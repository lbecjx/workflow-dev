---
type: llm
focus: last_message
---

PASS if the final message says the human was told this story is set to step
by step (autonomous mode off) and was asked how to run it, and that the story
file still holds `Autonomous mode: off`.

FAIL if the run switched the story to autonomous, if it says nothing about
the stored `off`, or if it says the row is now `on`.
