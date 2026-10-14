---
type: regex
target: { source: file, path: .workflow-dev/config.env }
pattern: '(^|\n)gitignored=true\n(.*\n)*agentCoauthorship=no(\n|$)|(^|\n)agentCoauthorship=no\n(.*\n)*gitignored=true(\n|$)'
---

Nobody can answer this run, so `.workflow-dev/config.env` ends with the unattended defaults saved: `gitignored=true` and `agentCoauthorship=no`.
