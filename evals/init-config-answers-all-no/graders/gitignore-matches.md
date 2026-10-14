---
type: regex
target: { source: file, path: .gitignore }
pattern: '(^|\n)\.workflow-dev/?(\n|$)'
match: not_contains
---

`.gitignore` does not list `.workflow-dev/`, matching the answer to keep it gitignored: no.
