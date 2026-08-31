# AI Harness

A self-built, multi-machine AI production cluster: free local LLM workers, an
image-generation pipeline, an image-to-3D pipeline, and a live dashboard —
orchestrated by a Claude (Fable 5) session acting as cluster head, built for
developing the [ember](https://github.com/enderPeer/ember) game engine.

Everything here was designed, written, debugged, and verified by the AI
orchestrator itself during two working days; a human approved downloads,
clicked UAC prompts, and made the calls the permission system reserves for
people.

## The tier model

| Tier | Hardware | Config | Role |
|---|---|---|---|
| Fast | RTX 4080 16GB (local) | GLM-4.7-Flash Q3, 1×32k ctx, ~136 tok/s | interactive drafting; hosts the 3D swap |
| Deep | 2× AMD RX 9070XT/9060XT (remote) | one llama.cpp Vulkan server across **both** cards, **131k context** | whole-codebase audits, long documents |
| Night | the same two AMD cards, optionally + adler's 4090 over LAN RPC | Qwen3.8-27B Q5_K_S, **262k native context** | the overnight coder: slow, capable, unattended |
| Reserve | 64GB DDR5 / 45GB RAM boxes | RAM+CPU hybrid (gpt-oss-120b class), on demand | slow, smarter, 24/7-tolerant jobs |
| Accurate | RTX PRO 4500 (off-site, barza) | Qwen3.8-27B **Q5_K_S**, 32k ctx, ~35 tok/s | drafting where correctness beats speed |
| Art | RTX 4090 24GB (remote) | Ideogram 4 / Qwen Edit / Z-Image server | free textures, concepts, key art |
| 3D | RTX 4080 (swapped) | Hunyuan3D-2 shape gen | concept image → GLB mesh |

The insight behind the deep tier: the model file (~14 GB) splits across two
16 GB cards at ~7 GB each, so the ~18 GB of *leftover* combined VRAM becomes
KV cache — a 131,072-token context at GPU speed, from cards that individually
max out around 16k.

## User interfaces

Everything is a localhost link. The two remote UIs ride the WireGuard tunnels
(see *Transport* below), so the browser needs no proxy settings — start the
cluster and open them:

```powershell
pwsh -File scripts\start-cluster.ps1        # starts what is missing, prints the links
```

| Interface | URL | Runs on |
|---|---|---|
| Dashboard — workers, tokens, live index of these links | <http://127.0.0.1:8090/> | local |
| gen3d studio — image → GLB, preview, gallery | <http://127.0.0.1:8095/> | local RTX 4080 |
| GLM-4.7-Flash chat (llama.cpp web UI) | <http://127.0.0.1:8080/> | local RTX 4080 |
| GLM-4.7-Flash 131k chat (llama.cpp web UI) | <http://127.0.0.1:9088/> | specht, 2× AMD |
| ComfyUI — image generation | <http://127.0.0.1:9188/> | adler, RTX 4090 |
| opencode — coding agent driving all of the above | <http://127.0.0.1:8096/> | agent, all tiers |


## The agent layer

[opencode](https://opencode.ai) is wired to the cluster's own models — no
hosted API, no key, no per-token cost. `agent/opencode.json` (deployed to
`~/.config/opencode/opencode.json`) declares both llama.cpp servers as
OpenAI-compatible providers and adds three subagents that match the measured
division of labour:

| Agent | Model | Job |
|---|---|---|
| `build` (default) | specht 131k | drives the work, makes the byte-exact edits |
| `scout` | local 4080 | fast search; reports `file:line`, cannot edit |
| `auditor` | specht 131k | reads whole files end to end, cannot edit |
| `drafter` | barza Qwen3.8-27B | self-contained new modules and plans, cannot edit |

`mcp/cluster_mcp.py` is a dependency-free MCP server that hands the agent the
rest of the cluster: `cluster_status`, `worker_ask` (delegate to a free worker),
`gen3d_generate` / `gen3d_job` / `gen3d_gallery`, `comfy_status` /
`comfy_outputs` / `comfy_fetch`, and `remote_run` (a shell on either server).
So the agent can list the art the 4090 has made, pull a four-view set down, mesh
it, and check a GPU on specht without leaving the session.

barza needs two things that deliberately live outside this repo, because one of
them is a secret and the other is machine-local:

| | |
|---|---|
| `~/.config/barza-llama.key` | the bearer token — referenced from the config as `{file:...}`, never inlined |
| `~/.config/barza-llama.crt` | its self-signed CA; no public CA can issue for a bare IP |

The certificate has to be pinned via `NODE_EXTRA_CA_CERTS` or the provider fails
to connect with no useful error — `start-cluster.ps1` sets it, and it is a user
environment variable so the TUI picks it up too. Verify a cert you were handed
before trusting it: `openssl x509 -in barza-llama.crt -noout -fingerprint -sha256`
should match the fingerprint in the endpoint's own documentation.

### The night coder

The day job and the night job want opposite things. Daytime work is
interactive — you want tokens now, and a human is reading them. Overnight work
is the reverse: nobody is watching, so throughput barely matters and capability
is everything.

`scripts/night-coder.ps1` flips the text tier between the two:

```powershell
night-coder.ps1 -Start                  # Qwen3.8-27B at 262k on specht
night-coder.ps1 -Start -WithAdler       # + the 4090 over LAN RPC, for bigger contexts
night-coder.ps1 -Stop                   # back to the GLM; the 4090 returns to ComfyUI
night-coder.ps1 -Status
```

Nothing is uninstalled in either direction — the GLM keeps port 8088 and its
config, Qwen gets 8089, and only one is resident because specht's 30 GB of VRAM
cannot hold both.

Why this model is the one worth running overnight: of its 64 layers only **16
keep a KV cache** — the other 48 use gated DeltaNet linear attention, which
holds a fixed-size recurrent state instead. Context costs roughly a quarter of
what a conventional 27B charges:

| Context | KV at q8_0 | A conventional 27B would want |
|---|---|---|
| 262,144 (native) | ~8.9 GB | ~34 GB |
| 1,000,000 | ~34 GB | ~131 GB |

**On chasing 1M.** It is reachable — adler and specht share a LAN, so
llama.cpp RPC can pool 54 GB of VRAM across three cards. But past 262,144 the
model needs static YaRN, which stretches position encoding on *every* prompt,
short ones included, and it costs a weaker quant and a coarser KV cache to fit.
Three quality penalties, paid on every request, to buy headroom that most agent
turns never touch. 262k native is already 2× the GLM and 8× what barza serves.
Reach for 1M deliberately, not by default.

### Which worker is actually best

Measured, not assumed — three tasks with traps, three trials each, every answer
**executed** against hidden cases rather than eyeballed:

| Worker | Score | merge_intervals | roman | word wrap | Speed |
|---|---|---|---|---|---|
| barza Qwen3.8-27B Q5 | **51/51** | 15/15 | 21/21 | 15/15 | 35 tok/s |
| local GLM-4.7-Flash Q3 | 47/51 | 12/15 | 21/21 | 14/15 | 100 tok/s |
| specht GLM-4.7-Flash Q3 | 45/51 | 12/15 | 21/21 | 12/15 | 38 tok/s, erratic |

The interesting part is *how* the GLMs fail: both missed the same
`merge_intervals` case in every single trial — the one where `[1,2]` and `[3,4]`
must merge because endpoints are inclusive. They drop that instruction detail
and never recover it; barza never missed it. An easier benchmark
(ISO-8601 durations) scored all three 16/16 and told us nothing, which is the
lesson: a benchmark everything passes is not a measurement.

So `drafter` runs on barza — self-contained artifacts are exactly what it wins
at — while the primary agent stays on specht for the 131k context, and `scout`
stays local because search wants speed, not depth.

Two commands encode the way this cluster is meant to be worked:

| Command | What it does |
|---|---|
| `/ultra <task>` | map with `scout`, fan out to `drafter` / `auditor` / `worker_ask`, verify every claim adversarially, then land the edits itself |
| `/clusterreview [scope]` | review the diff with independent auditors and keep only findings that survive a refutation pass |

```bash
opencode                                    # TUI in the current repo
opencode run "summarise the transport fix"  # headless
opencode run --command ultra "port the queue to SSE"
```

Subagents are reached through the task tool (`--agent` only selects primary
agents).

This agent runs **unattended**: `edit`, `bash`, `webfetch` and
`external_directory` are all `allow`, so `/ultra` completes its verification
pass and can work on the deployed copies under `C:\llama.cpp` and `C:\hy3d`
without stopping. That is a deliberate choice, not a default — a 30B model has
a shell on this machine and the file tools reach anywhere the account does.
Tighten `permission` in `agent/opencode.json` if you want it back on a leash.

Two things learned while getting there, both of which look like the tool being
broken when they are not:

- **A headless `opencode run` has nobody to ask**, so a permission set to
  `"ask"` is an auto-*reject*. `/ultra` delegated to scout correctly and then
  died on its own verification pass because of it.
- **The last matching rule wins, so pattern order is the reverse of the
  intuition.** A catch-all `"*": "ask"` written at the end of an allowlist
  overrides every allow above it, and `opencode debug agent build` still lists
  all the rules as registered — it looks configured and denies everything. Put
  the catch-all first, the specific rules after.

Note also that gating `external_directory` while `bash` is open buys nothing:
the agent reads outside the project with `type` or `cat` regardless. The file
tools were the only thing being stopped.

## Components

- `worker/glm.ps1` — the worker client. Streams responses (SSE), logs every
  call (prompt, live thinking, answer, token usage) to JSONL, supports
  `-NoThink` (disables reasoning via `chat_template_kwargs`), `-File`
  attachments, and `-SshWorker` for remote workers.
- `dashboard/` — self-hosted live dashboard (PowerShell HttpListener + vanilla
  JS): active workers with streaming thought view, token totals by label,
  expandable call history, GPU stats, and the orchestrator's own token usage
  parsed from session transcripts.
- `gen3d/asset-pipeline.ps1` — art → game-ready GLB in one call: pulls the
  views from our own ComfyUI, meshes them, polishes in Blender. `-List` shows
  what ComfyUI has made. No credentials: it is our instance on adler, reached
  through the tunnel, so `/view` serves the outputs directly.
- `gen3d/` — image→3D: pauses the local LLM worker to free VRAM, runs
  Hunyuan3D-2 shape generation, exports GLB, restarts the worker.
  `gen3d-ui.py` is the browser front end for it (queue, live pipeline log,
  in-page 3D preview, gallery): drop one concept image, or drop the
  front/back/left/right set and it switches to the multi-view model
  automatically. One job at a time — two shape models on one card is an
  out-of-memory error, not a speedup.
- `net/wgexpose.py` — the user-context relay that puts a remote loopback
  service on the WireGuard address for one allowlisted peer.
- `mcp/cluster_mcp.py` — MCP server exposing the cluster (status, workers,
  3D pipeline, ComfyUI, remote shell) to any MCP-speaking agent. Stdlib only.
- `agent/opencode.json` — the opencode configuration: all three providers,
  the subagents, and the MCP wiring. `AGENTS.md` is the project brief the
  agent reads on entry.
- `scripts/start-cluster.ps1` — idempotent bring-up of tunnels, relays and
  local servers; prints every UI link with a live up/down check.
- `scripts/worker-queue.ps1` — idle production: queues drafting tasks
  (code modules, level layouts, shader upgrades, code reviews) across workers,
  outputs to a review folder — nothing enters a repo unreviewed.
- `scripts/codemap-run.ps1` — fans per-file code-map summarization across
  workers (30 files in 56 s) to build a cheap codebase reference.
- `scripts/apply-edits.ps1` — applies model-generated FIND/REPLACE edit
  scripts with byte-exact verification (and taught us that models can't quote
  verbatim — see lessons).

## Transport (the interesting failure, now solved)

Remote workers sit behind WireGuard tunnels (userspace `wireproxy`). `ssh -L`
into them fails — and the reason took a while to pin down, because it is not
where it looks. The forward is set up fine; the *server side* refuses:

```
debug1: Connection to port 19089 forwarding to 127.0.0.1 port 8088 requested.
channel 1: open failed: connect failed: open failed
```

sshd's own SELinux domain may not connect to a staff user's ports, and the
denial is `dontaudit`-suppressed — which is why the admins, checking the audit
log and the sshd config, correctly reported no policy and no denials. The
harness used to route around it by POSTing through `ssh host "curl -d @- ..."`,
which runs in *user* context and works — at the cost of streaming.

The current fix keeps everything in user context but restores streaming:

1. `net/wgexpose.py` runs as the user on the server and relays its own
   `10.7x.0.1:1xxxx` → `127.0.0.1:<service>`, refusing every peer except the
   workstation's tunnel address.
2. `wireproxy`'s `[TCPClientTunnel]` maps that to a local port, so
   `http://127.0.0.1:9088/` *is* specht's llama.cpp and `:9188` *is* adler's
   ComfyUI — in the browser, with SSE token streaming and ComfyUI's websockets
   intact, and no proxy configuration anywhere.

The dashboard's slot polling dropped its 20-second ssh-and-cache hop for a
plain HTTP call as a result.

## Lessons learned (measured, not vibes)

1. **Workers scaffold, the orchestrator finishes.** Free 30B-MoE workers
   reliably produce self-contained artifacts (pages, modules, plans, JSON,
   reviews) and reliably fail at: quoting existing code verbatim, whole-file
   surgery on complex sources, and geometry math. Split the work that way and
   ~370k free tokens/day of drafts arrive with orchestrator tokens spent only
   on correctness.
2. **Thinking mode is a budget hazard.** Reasoning models burn their entire
   token budget "thinking" on mechanical tasks; `-NoThink` turned dead tasks
   into deliverables.
3. **Queue everything.** The art server accepts a full backlog of jobs and
   grinds unattended; the worker queue does the same for text. Idle hardware
   is a scheduling bug.
4. **PowerShell pipelines mangle arrays.** `ConvertTo-Json` after a pipe
   double- or zero-wraps arrays; always `ConvertTo-Json -InputObject @($x)`.
5. **"No denials in the audit log" is not "no denial."** SELinux `dontaudit`
   rules suppress exactly the entry you are looking for, so a policy check can
   come back clean while the operation keeps failing. The client-side
   `ssh -vv` channel error located it in one run; two days of asking the wrong
   side did not.
6. **A single-threaded listener must never probe the network inline.** The
   dashboard's link panel checked four endpoints per request and stalled every
   other panel on the page; probing one endpoint per request, oldest first,
   made it free.

## What got produced with it (so far)

Engine features (hot-reloadable WGSL shaders, per-mesh texture system,
animated humanoid characters), a three-set armor art collection, a coherent
environment texture set, concept art for 3D conversion, six reviewed
production drafts (hitbox colliders, arena layouts, lighting shader, overlay
plan, determinism review, props plan), and a full-codebase 128k-context
audit — at a marginal LLM cost of $0.
