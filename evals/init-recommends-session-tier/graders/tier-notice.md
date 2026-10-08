---
type: llm
focus: last_message
---

PASS if the final message shows one of these two outcomes:

- **Notice shown.** The quoted notice recommends the top (most capable) tier
  for the session's model, names the model the session runs on, speaks of the
  recommendation as a tier rather than a specific model, says the model can be
  changed without giving a slash command, and is at most 3 lines.
- **Notice skipped.** The message says the session already runs at the top
  tier, so no notice was needed.

In both outcomes, the list of questions init asked must not include one about
the session's model or its tier.

FAIL if the notice recommends the fast or the intermediate tier (no role is
bound in this repo), recommends a specific model by name, gives a slash command
to switch, runs past 3 lines, is put to the human as a question, or if the
message neither quotes a notice nor says why none was shown.
