---
type: regex
target: { source: file, path: .gitignore }
pattern: '(^|\n)\.workflow-dev/?(\n|$)'
---

`.gitignore` lists `.workflow-dev/`, matching the answer to keep it gitignored: yes.
