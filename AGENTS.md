# Working in this repo

This is the harness that runs a small multi-machine AI cluster. Everything here
is stdlib-only by choice: PowerShell for the Windows-side servers, Python
standard library for the pipelines. Do not add dependencies to make something
marginally shorter.

## The hardware you are running on

| Tier | Where | Use it for |
|---|---|---|
| local RTX 4080 | this machine, `:8080` | fast search and bulk reading; hosts the 3D pipeline |
| barza, RTX PRO 4500 | off-site over TLS, Q5 quant | drafting where correctness beats speed (51/51 vs 47 and 45 on an executed benchmark) |
| specht, 2× AMD | `:9088` via tunnel, 131k context | whole-file audits, long documents |
| adler, RTX 4090 | `:9188` via tunnel | ComfyUI image generation |

The local 4080 runs **either** the LLM worker **or** Hunyuan3D, never both —
16 GB does not fit them together. The 3D studio handles that swap itself.

## Division of labour that actually works here

Measured, not assumed: the free 30B workers reliably produce **self-contained**
artifacts — a new module, a plan, a summary, a review, a JSON blob — and
reliably fail at **quoting existing code verbatim**, whole-file surgery on
complex sources, and geometry math.

So: hand bulk reading and first drafts to `worker_ask` or the `drafter` /
`auditor` subagents, and do the edits that must be byte-exact yourself. Treat a
worker's review as a lead to verify, not a finding to act on — they produce
confident, plausible, wrong claims at a noticeable rate.

Reasoning mode is a budget hazard on mechanical tasks: these models will spend
their entire token budget "thinking" and return nothing. `worker_ask` disables
it by default (`no_think`), and `glm.ps1` has `-NoThink`.

## Cluster tools (MCP)

`mcp/cluster_mcp.py` exposes the whole cluster to an agent:

- `cluster_status` — which tiers are up, local GPU state. Start here when
  something is unreachable.
- `worker_ask` — delegate a self-contained task to a free worker: `specht` for
  131k context, `local` for speed, `barza` for accuracy. Costs nothing.
- `gen3d_generate` / `gen3d_job` / `gen3d_gallery` — concept art → GLB mesh.
  One image, or four views (front/back/left/right) for the multi-view model.
- `comfy_status` — ComfyUI queue and 4090 VRAM before you queue image work.
- `comfy_outputs` / `comfy_fetch` — what the 4090 has drawn, and pulling it
  down. `comfy_fetch` takes a `set` prefix and returns the four views in
  front/back/left/right order, ready for `gen3d_generate`. There is no API key
  and no gallery login involved — ComfyUI is ours, over the tunnel.
- `remote_run` — a shell on `adler` or `specht` as user `end`.

## Things that will bite you

- **Never `ssh -L` to a server port.** It fails at the last hop and the audit
  log stays clean about it. Use `net/wgexpose.py` + a wireproxy
  `[TCPClientTunnel]`, or run the command server-side with `remote_run`.
- **`ConvertTo-Json` after a pipe mangles arrays.** Always
  `ConvertTo-Json -InputObject @($x)`.
- **The dashboard's listener is single-threaded.** Anything it does inline
  blocks every other panel; probe one endpoint per request, not all of them.
- The servers are shared with colleagues. Prefix heavy remote work with
  `chrt --idle 0 ionice -c3`, and check `nvidia-smi` before claiming the 4090.

## Verifying your work

There are no unit tests. Verify by running the thing: start the server, call
the endpoint, look at the page. `scripts/start-cluster.ps1 -Status` reports
every interface without changing anything.
