---
type: regex
target: { source: file, path: .workflow-dev/config.env }
pattern: '(^|\n)agentCoauthorship=no(\n|$)'
match: "count:1"
---

`.workflow-dev/config.env` holds `agentCoauthorship=no` exactly once: the human's answer, saved.
