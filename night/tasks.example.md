# Night shift task list

Every `## heading` starts a task; everything under it is the brief handed to the
agent. One worktree and one branch per task, so tasks never interfere.

Write briefs the way you would for a competent contractor who cannot ask
follow-up questions: name the file, say what "done" looks like, and say how to
check it. The measured failure mode of these local models is dropping one
constraint out of several — so state the constraint that matters most twice, in
different words, and give a concrete example of the edge case.

Prefer several small tasks to one large one. A task that goes wrong wastes only
its own slot, and at ~17 tok/s a night holds roughly 500k tokens of work.

## Add a --version flag to wgexpose

In `net/wgexpose.py`, add a `--version` argument that prints the version string
and exits 0 without binding a socket. Define the version as a module-level
constant near the top rather than inline in the parser. Do not change any
existing behaviour: running it without `--version` must still require the bind
and target arguments exactly as it does now.

Verify: `python net/wgexpose.py --version` prints a version and exits 0, and
`python net/wgexpose.py` with no arguments still exits 2 with the usage error.

## Give the gen3d studio a job-cancel endpoint

`gen3d/gen3d-ui.py` can cancel a *queued* job but not a running one. Add a
`POST /api/kill?id=<job>` route that terminates the running subprocess for that
job, marks it `cancelled`, and lets the worker thread continue to the next job
without leaving the LLM worker stopped.

The subprocess handle is not currently kept anywhere — store it on the Job so
the handler can reach it, and guard against the race where the job finishes
between the lookup and the kill.

Verify: start a generation, POST to the kill endpoint, and confirm the queue
moves on and `llama-server` comes back up when the queue drains.

## Write a smoke test for the cluster MCP server

There is no test for `mcp/cluster_mcp.py`. Add `mcp/test_cluster_mcp.py` using
only the standard library (`unittest`), driving the server over stdio as a
subprocess exactly like a real MCP client would: initialize, tools/list, then
one `tools/call` against a tool that needs no network (`cluster_status` is fine
even when every tier is down — it should still return text, not raise).

Do not import the module directly; the point is to test the protocol surface.
The test must pass whether or not any cluster service is running.
