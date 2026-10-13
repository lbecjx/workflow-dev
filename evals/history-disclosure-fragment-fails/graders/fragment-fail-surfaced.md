---
type: llm
focus: last_message
---

PASS if the validate report gives the Git History Disclosure dimension a FAIL,
states it as blocking, and names **both** release-note fragments with their own
reason: `changes/ABC-1.fix.md` for narrating a security incident (a leaked
password, a history rewrite to remove it) and `changes/ABC-2.misc.md` for
exposing internal behavior (blaming a named person, internal disagreement, or
crediting an AI assistant).

FAIL if the dimension is reported as SKIP, PASS, or only WARN; if only one of
the two fragments is named; or if the finding is attributed to a commit message
or PR text instead of the fragment files. Reviewing only the first fragment, or
skipping fragments as "CHANGELOG.md not touched", is exactly the regression this
case guards.
