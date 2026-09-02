# Cluster status — 2026-09-02 12:20

A point-in-time inventory. Every line says whether it was **measured now** or is
the **last verified** value, because the site holding adler and specht has been
unreachable since 2026-09-01 ~13:30 and nothing there can be checked from here.

## The short answers

| Question | Answer |
|---|---|
| Is opencode still on the weaker 131k model? | **Yes.** Its default is `specht/glm-4.7-flash-131k`. The night coder exists as provider `specht-qwen` but was never made the default. |
| Is the 262k Qwen ready? | **Yes, and proven** — installed on specht, ran at 262,144, measured, drove opencode. It is unreachable right now only because the site is down. |
| What about Qwen3-Coder-Next? | **Not installed.** Download reached ~1.7 GB of 35.8 GB when the site dropped. Resumable; everything around it is prepared. |
| What is running on adler and specht? | **Unknown right now** — both boxes unreachable for ~23 hours, through a power cycle, with the admin on it. Last verified state is below. |

## Machines

### specht — 2× AMD (RX 9060 XT + RX 9070 XT, 32.5 GB VRAM), 45 GB RAM, i7-8700K

| | | Verified |
|---|---|---|
| Reachable | **no** — ssh banner-exchange timeout | now |
| GLM-4.7-Flash-UD-Q3_K_XL.gguf | installed, 13.8 GB. Serves port 8088 at 131k. The daytime worker. | file 08-28 |
| Qwen3.8-27B-UD-Q5_K_S.gguf | installed, 18.67 GB (size verified byte-exact). Serves port 8089 at **262,144**. The night coder. | 08-31 |
| Qwen3-Coder-Next-UD-IQ4_XS.gguf | **partial**, ~1.7 of 35.8 GB. Download interrupted by the outage. | 09-01 13:28 |
| llama.cpp | b10717 (Vulkan) alongside the older b10678; both support both Qwen architectures | 08-31 |
| Last known running | Qwen night coder at 262k, relays on 10.72.0.1:18088/18089, RAM guard (0 trips) | 09-01 ~13:20 |
| Also on the box | `ender`'s pong-server (7780) and fire-server (7781) with cloudflared tunnels — not ours, down with the site | 09-01 |

Night-coder measurements at 262,144 (specht alone, 09-01): 775 tok/s prompt
eval on a 24k prompt, 16.5 tok/s generation, tool calls correct, drove opencode
unaided to the right answer. Adding adler's 4090 over RPC made it *slower*
(401 / 14.2) and bought no usable context — llama-server caps the slot at the
model's trained 262,144 and says so in the log.

### adler — RTX 4090 (24 GB), 64 GB RAM, i9-12900K

| | | Verified |
|---|---|---|
| Reachable | **no** | now |
| LLM models | **none** — adler has no GGUF files; it is the art machine | 08-31 |
| ComfyUI 0.34.0 | our container `comfy`, port 8188 (→ 127.0.0.1:9188 here). 124 outputs, 8 complete four-view sets. No local checkpoints (0) — it generates through API nodes. | 09-01 |
| llama.cpp b10717 + `rpc-adler.sh` | present, so the 4090 can be lent to specht over the LAN. RPC server was **stopped** before the outage; the card was back with ComfyUI. | 09-01 |
| Not ours | a second image stack on port 8288 (jamie's) shares the 4090 | 08-31 |

### this machine — RTX 4080 (16 GB), 64 GB RAM

| | | Verified |
|---|---|---|
| llama-server, GLM-4.7-Flash Q3, port 8080, 32k | **up**, 13 GB resident | now |
| gen3d studio, port 8095 (Hunyuan3D-2 + 2mv cached) | **up** | now |
| opencode server, port 8096 | **up** | now |
| dashboard, port 8090 | was down; **restarted, up** | now |
| wireproxy tunnels (1080/1081 + 9088/9089/9188) | up locally, freshly restarted — but nothing answers through them | now |

### barza — RTX PRO 4500 (32 GB), off-site, someone else's box

| | | Verified |
|---|---|---|
| Reachable | **no** — TCP connect timeout (curl exit 28), not an auth or TLS failure | now |
| Qwen3.8-27B-UD-Q5_K_S | measured 51/51 on the executed benchmark vs the GLMs' 47 and 45 | 08-30 |
| Context | was 32,768 when I measured it. The config now says 262,144 — **that change was made by another session and I could not verify it before barza went dark.** | see below |

The connect timeout matches barza's own documentation exactly: the AzireVPN
port-forward expires, renewal assigns a **new port**, and the base URL has to be
updated. Most likely barza is fine and `185.41.242.227:53018` is stale. The
owner has the new port.

## What opencode is actually configured to use (live config, measured now)

| | Model | Reachable now |
|---|---|---|
| **default (`build`)** | `specht/glm-4.7-flash-131k` — the 131k GLM | no (site) |
| small model | `local4080/glm-4.7-flash` | yes |
| agent `ultra` (primary) | `barza/qwen3.8-27b` | no (port) |
| agent `drafter` | `barza/qwen3.8-27b` | no (port) |
| agent `auditor` | `specht/glm-4.7-flash-131k` | no (site) |
| agent `scout` | `local4080/glm-4.7-flash` | yes |
| provider `specht-qwen` (the night coder) | `qwen3.8-27b` @ 262,144 | no (site) — **and not the default** |

So at this moment opencode's default, its primary `ultra` agent, and two of its
three subagents all point at endpoints that do not answer. Only the local 4080
tier works.

**Provenance note.** The `ultra` agent, `drafter` moving to barza, and barza's
context being raised to 262,144 were not my edits. They arrived in commit
`9446fe0` on 09-01, which I made during the outage with `git add -A` to preserve
work — and it swept in changes another session had left on disk. The likely
author is the session "Connect Qwen Blackwell to OpenCode". A further session,
`ai-harness-3f`, is active on this repo as of 12:14 today. Two sessions editing
one config is how this happens; the config is internally consistent but I have
not measured what it claims about barza.

## What is blocked on whom

| Needs | From |
|---|---|
| Are adler and specht up, and were the WireGuard endpoints rotated when the admin fixed things? If the endpoints changed, both `~/.config/wireproxy-*.conf` files here are stale and I need the new `Endpoint` values. | admin / you |
| barza's current port after the forward renewal | barza's owner |
| Confirmation that `ultra` / barza-262k is intended, or it goes back to what was measured | you |
| Whether the night coder should become opencode's default once specht is back | you |

## When the site returns, in order

1. Confirm both boxes booted clean. ember-ae gets the first four minutes on
   specht for their v12 cutover — agreed, and they've waited long enough.
2. Restart the relays (`nohup`; `systemctl --user` is denied on these hosts for
   both accounts) and the RAM guard.
3. Resume the Coder-Next download: `curl -C -` continues from 1.7 GB.
4. Bring the night coder up at 262,144 and re-verify.
5. Load Coder-Next across specht + adler (36.6 GB needs both), verify tool
   calling, benchmark it against the 27B on the executed suite, and switch
   opencode's default to whichever wins.
6. Free hardware experiment worth doing before buying anything: move the 4080
   into adler → 40 GB of CUDA-only VRAM in one box, no Vulkan, no GTT spill.
