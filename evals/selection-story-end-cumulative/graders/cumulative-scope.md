---
type: llm
focus: last_message
---

PASS if the validate report covers the story's cumulative changes since the
branch left `main`: it names `docs/setup.md` (Task Group 1, already committed)
as well as `docs/usage.md` (Task Group 2, uncommitted) among the files in scope,
or states plainly that it ran the batched/story-end scope over every change of
the story and lists both files.

FAIL if the scope covers only `docs/usage.md` or only the uncommitted changes,
or if `docs/setup.md` is not part of what was validated.
