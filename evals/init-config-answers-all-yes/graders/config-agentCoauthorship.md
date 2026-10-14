---
type: regex
target: { source: file, path: .workflow-dev/config.env }
pattern: '(^|\n)agentCoauthorship=yes(\n|$)'
match: "count:1"
---

`.workflow-dev/config.env` holds `agentCoauthorship=yes` exactly once: the human's answer, saved.
