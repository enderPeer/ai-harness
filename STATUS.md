# Cluster status — 2026-09-02 13:10

Point-in-time inventory. Everything below was **measured now** unless marked.

## The short answers

| Question | Answer |
|---|---|
| Is opencode on the 262k model? | **Yes.** Default is `specht-qwen/qwen3.8-27b`. Verified end to end: with no `--model` flag it did multi-step tool work and answered correctly. `auditor` moved to it too (the 131k GLM is not resident while the night coder holds the cards). |
| Is the 262k Qwen running? | **Yes** — on specht alone, `n_ctx = 262144`, RAM guard armed, ~14 GB headroom. |
| Qwen3-Coder-Next? | **Downloading** — 14.12 GB of 35.79, curl running: 1. Everything around it is prepared; loading it needs both machines (36.6 GB) and is parked with the other experiments until the hardware upgrade. |
| barza? | **Unreachable — its own AzireVPN port-forward rotated** (TCP connect timeout on 53018, not auth/TLS). Wired for 262k in the config; needs its new port. |

## What happened to the site

The servers never went down. The **off-site WireGuard doors** did — a provider-side reset changed their public ports (same IPs, same keys). Both boxes were reachable on the LAN throughout; a power cycle changed nothing because the machines were never the fault. The admin restored the doors with new ports on 2026-09-01; updated here on 09-02 (ports live only in `~/.config/wireproxy-*.conf`, not in this repo). The reconnect succeeding is itself proof of identity — WireGuard authenticates by the pinned peer key, so a wrong port cannot reach an impostor.

The "recovery" files that appeared in Downloads during the outage were, per the user, the travelling admin's own attempt to regain access. They were declined at the time because their shape matched an attack and their author could not be verified — the right default, and moot now the proper doors are back. Servers were verified clean either way: one legit key per box, no foreign tunnels.

## Machines

### specht — 2× AMD (32.5 GB VRAM), 45 GB RAM
| | |
|---|---|
| Qwen3.8-27B Q5_K_S, port 8089, **262,144 ctx** | **up** (the night coder, opencode default) |
| GLM-4.7-Flash Q3, port 8088, 131k | installed, **not resident** (shares the cards; `night-coder.ps1 -Stop` swaps back) |
| Qwen3-Coder-Next IQ4_XS | downloading, see above |
| relays 10.72.0.1:18088/18089, RAM guard | up |
| Note | model is sitting in GTT (system RAM mapped for the GPU) rather than VRAM — runs fine, was 775 tok/s prompt / 16.5 gen last measured; a CUDA box would avoid it. One for the upgrade. |
| `ender`'s game servers (7780/7781) | not listening since the reboot — not ours to start |

### adler — RTX 4090 (24 GB), 64 GB RAM
| | |
|---|---|
| ComfyUI 0.34.0, port 8188 → 9188 here | **up** (container + relay restored after the reboot) |
| LLM models | none — the art machine |
| `rpc-adler.sh` | present, **stopped**; the 4090 stays on art until the experiments resume |

### this machine — RTX 4080
llama-server (GLM 32k, `:8080`), gen3d studio (`:8095`), dashboard (`:8090`), opencode server (`:8096`) — all up. wireproxy on the new doors, all five tunnel ports listening.

## opencode wiring (live == repo copy)

| | Model | Reachable |
|---|---|---|
| **default** | `specht-qwen/qwen3.8-27b` @ 262k | **yes** |
| `auditor` | `specht-qwen/qwen3.8-27b` | yes |
| `scout` | `local4080/glm-4.7-flash` | yes |
| `ultra` (primary), `drafter` | `barza/qwen3.8-27b` @ 262k | no — barza port rotated |

## Blocked on

| Needs | From |
|---|---|
| barza's current port (its forward renewed onto a new one) | barza's owner / you |
| Coder-Next load + benchmark, RPC/CUDA experiments | parked until the hardware upgrade, per user |

Other Claude sessions were asked to go dormant; this session owns the harness work.
