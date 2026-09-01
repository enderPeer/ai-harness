---
description: Fan the task out across the cluster — scout, parallel drafts, independent verification, then one synthesis
---

Work on this the exhaustive way, using the whole cluster rather than your own
context. The hardware is free; your context is the scarce thing.

**Task:** $ARGUMENTS

Run it in four passes, and do not skip a pass because the task "looks small":

1. **Map.** Delegate to the `scout` subagent to locate every file that matters —
   call sites, config, tests, docs. Ask for `file:line` references, not prose.
   If several areas are independent, send several scout tasks in one go.

2. **Fan out.** For each independent piece of work, delegate in parallel:
   - `drafter` for anything self-contained (a new module, a config, a plan);
   - `auditor` for anything that needs a whole file read end to end;
   - `worker_ask` (cluster MCP) for bulk reading or summarising that does not
     need repository tools — it costs nothing and keeps your context clean.
   Give each one the paths scout found, not a vague description.

3. **Verify, adversarially.** Every claim that came back is a lead, not a
   finding. These workers produce confident, plausible, wrong statements at a
   real rate. For each one, check it yourself against the actual file, or send
   a second `auditor` task framed to *refute* it. Drop anything that does not
   survive. State what you dropped.

4. **Land it.** Make the byte-exact edits yourself — workers cannot quote
   existing code reliably. Then verify by running the thing (start the server,
   call the endpoint, open the page), not by reasoning about it.

Report: what you changed, what you verified and how, what you dropped in pass 3,
and anything you deliberately left out.
