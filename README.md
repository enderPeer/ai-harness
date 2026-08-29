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
| Reserve | 64GB DDR5 / 45GB RAM boxes | RAM+CPU hybrid (gpt-oss-120b class), on demand | slow, smarter, 24/7-tolerant jobs |
| Art | RTX 4090 24GB (remote) | Ideogram 4 / Qwen Edit / Z-Image server | free textures, concepts, key art |
| 3D | RTX 4080 (swapped) | Hunyuan3D-2 shape gen | concept image → GLB mesh |

The insight behind the deep tier: the model file (~14 GB) splits across two
16 GB cards at ~7 GB each, so the ~18 GB of *leftover* combined VRAM becomes
KV cache — a 131,072-token context at GPU speed, from cards that individually
max out around 16k.

## Components

- `worker/glm.ps1` — the worker client. Streams responses (SSE), logs every
  call (prompt, live thinking, answer, token usage) to JSONL, supports
  `-NoThink` (disables reasoning via `chat_template_kwargs`), `-File`
  attachments, and `-SshWorker` for remote workers.
- `dashboard/` — self-hosted live dashboard (PowerShell HttpListener + vanilla
  JS): active workers with streaming thought view, token totals by label,
  expandable call history, GPU stats, and the orchestrator's own token usage
  parsed from session transcripts.
- `gen3d/` — image→3D: pauses the local LLM worker to free VRAM, runs
  Hunyuan3D-2 shape generation, exports GLB, restarts the worker.
- `scripts/worker-queue.ps1` — idle production: queues drafting tasks
  (code modules, level layouts, shader upgrades, code reviews) across workers,
  outputs to a review folder — nothing enters a repo unreviewed.
- `scripts/codemap-run.ps1` — fans per-file code-map summarization across
  workers (30 files in 56 s) to build a cheap codebase reference.
- `scripts/apply-edits.ps1` — applies model-generated FIND/REPLACE edit
  scripts with byte-exact verification (and taught us that models can't quote
  verbatim — see lessons).

## Transport (the interesting failure)

Remote workers sit behind WireGuard tunnels (userspace `wireproxy` → SOCKS →
ssh). On the SELinux-confined hosts, `ssh -L` port forwarding is denied for
sshd while *user-context* processes connect freely — so the harness POSTs
via `ssh host "curl -d @- ..."` instead: the request runs server-side in
user context. Streaming is lost for remote workers; logging is not.

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

## What got produced with it (so far)

Engine features (hot-reloadable WGSL shaders, per-mesh texture system,
animated humanoid characters), a three-set armor art collection, a coherent
environment texture set, concept art for 3D conversion, six reviewed
production drafts (hitbox colliders, arena layouts, lighting shader, overlay
plan, determinism review, props plan), and a full-codebase 128k-context
audit — at a marginal LLM cost of $0.
