---
type: llm
focus: last_message
---

PASS if the final message shows one of these two outcomes:

- **Notice shown.** The quoted notice recommends the top (most capable) tier
  for the session's model, names the model the session runs on, names the
  models it counts in the top tier, says the model can be changed without
  giving a slash command, and is at most 3 lines. The session's own model must
  not be among the top-tier models it names.
- **Notice skipped.** The message says the session's model is one of the
  top-tier models, so no notice was needed.

In both outcomes, the list of questions init asked must not include one about
the session's model or its tier. A question about binding the agent roles to
models (`/workflow-dev:setup-models`, or keeping the default model for the repo
or story) is a different question and does not count against this.

FAIL if the notice recommends the fast or the intermediate tier (no role is
bound in this repo), names the session's own model as top tier and still shows
the notice, gives a slash command
to switch, runs past 3 lines, is put to the human as a question, or if the
message neither quotes a notice nor says why none was shown.
