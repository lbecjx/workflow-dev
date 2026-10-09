---
type: tool_used
tool: Skill
# The closing quote after `init` keeps `init-auto`'s own call from matching.
input_match: '"skill"\s*:\s*"(?:[\w-]+:)?init"[\s\S]*local-backlog/EVAL-0004-init-auto\.md'
---

PASS if `init-auto` invokes the `init` skill with the story path exactly as
the human gave it.

FAIL if `init` is never invoked, or is invoked without that path: the wrapper
must pass `init`'s input through unchanged.
