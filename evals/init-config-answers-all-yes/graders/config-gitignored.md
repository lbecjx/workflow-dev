---
type: regex
target: { source: file, path: .workflow-dev/config.env }
pattern: '(^|\n)gitignored=true(\n|$)'
match: "count:1"
---

`.workflow-dev/config.env` holds `gitignored=true` exactly once: the human's answer, saved.
