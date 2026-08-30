---
description: Review the working-tree diff with independent auditors, keeping only findings that survive refutation
agent: build
---

Review the current changes. Scope: $ARGUMENTS (if empty, the full working-tree
diff — get it with `git diff` and `git status --short`).

1. Read the diff yourself first, so you can judge what comes back.
2. For each changed file, delegate an `auditor` task with the file path and the
   diff hunk. Ask for correctness defects first, then reuse and simplification.
   Require a file, a line, and the concrete input or state that fails — a
   finding without a failure case is not a finding.
3. For every finding that comes back, send a second `auditor` task whose job is
   to **refute** it, given the same file. Keep only what survives. Expect to
   drop a good share of them; that is the point of the pass.
4. Report the survivors, most severe first, each as `file:line — defect —
   failing case`. Then list what you dropped and why, in one line each.

Do not edit anything unless asked. If nothing survives, say so plainly rather
than promoting a weak finding to fill the report.
