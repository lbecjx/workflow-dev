---
type: tool_used
# `Bash` is Claude Code's shell tool, which is the vocabulary the `claude plugin
# eval` runner records tool calls in.
tool: Bash
input_match: 'model-tiering-check\.sh\s+--status\s+\S*\{'
---

PASS if the run invoked the tiering check in its reporting mode **with its
payload** — proving init's detection step actually executed, and passed that
payload as an argument rather than falling through to stdin.

FAIL if the check is never invoked, or is invoked with no payload. Both matter:
a run that never checked its bindings is exactly as quiet as one that checked
and found the repo default, and a payload-less call answers `not-ours`, which the
caller reads as "not ours" and skips — a no-op wearing the same silence.

The match is anchored on the payload's opening brace, not merely on there being
*something* after `--status`. A trailing shell token is not evidence of a
payload: `--status < /dev/null` and `--status 2>/dev/null` are both payload-less
calls, and a looser pattern would pass them.
