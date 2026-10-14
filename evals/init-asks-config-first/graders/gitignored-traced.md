---
type: tool_used
tool: Write
input_match: 'context/EVAL-0008[^"]*\.md[\s\S]*gitignored[^|]*\|\s*Agent \(inferred\)'
---

The story's Decisions record the gitignored default as `Agent (inferred)`: a choice taken without the human leaves a trace.

Graded on the Write that creates the context file, not on the file: runs name it
`EVAL-0008.md` or `EVAL-0008-greeting-name.md`, and a `regex` grader reads one
fixed path.
