---
type: regex
target: { source: file, path: .workflow-dev/config.env }
pattern: '(^|\n)tiering=default(\n|$)'
match: "count:1"
---

`.workflow-dev/config.env` holds `tiering=default` exactly once: the human's answer, saved.
