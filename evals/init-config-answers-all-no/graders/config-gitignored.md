---
type: regex
target: { source: file, path: .workflow-dev/config.env }
pattern: '(^|\n)gitignored=false(\n|$)'
match: "count:1"
---

`.workflow-dev/config.env` holds `gitignored=false` exactly once: the human's answer, saved.
