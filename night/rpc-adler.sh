#!/bin/bash
# Lend adler's RTX 4090 to specht's llama-server over the LAN.
#
# adler and specht sit on the same 192.168.178.0/24 segment, so this is a direct
# gigabit hop — not one of the WireGuard tunnels, which only exist so the
# workstation can reach either box from outside.
#
# The 4090 cannot serve ComfyUI and the night coder at the same time: image work
# holds ~23 of its 24 GB. `start` therefore refuses to run while ComfyUI has the
# card unless you pass --force, so a night job can never quietly kill a running
# batch of art.
#
#   rpc-adler.sh start [--force] | stop | status

set -u
LLAMA=~/llama/b10717
PORT=50052
BIND=192.168.178.171          # LAN address; specht dials this directly
DEVICE=Vulkan0                # the 4090. Vulkan1 is the Intel iGPU — never expose that.
LOGDIR=~/logs
mkdir -p "$LOGDIR"

running() { pgrep -f "ggml-rpc-server.*--port $PORT" >/dev/null 2>&1; }

vram_used() { nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -1; }

case "${1:-status}" in

start)
    if running; then echo "[rpc] already running on $BIND:$PORT"; exit 0; fi
    used=$(vram_used)
    if [ "${used:-0}" -gt 2000 ] && [ "${2:-}" != "--force" ]; then
        echo "[rpc] refusing: ${used} MiB of the 4090 is in use (ComfyUI?)."
        echo "[rpc] stop the image stack first, or re-run with --force to share a crowded card."
        exit 1
    fi
    cd "$LLAMA" || exit 1
    LD_LIBRARY_PATH="$LLAMA" setsid nohup ./ggml-rpc-server \
        --host "$BIND" --port "$PORT" --device "$DEVICE" --cache \
        >> "$LOGDIR/rpc-server.log" 2>&1 < /dev/null &
    sleep 2
    running && echo "[rpc] 4090 offered at $BIND:$PORT" || { echo "[rpc] failed to start — see $LOGDIR/rpc-server.log"; exit 1; }
    ;;

stop)
    pkill -f "ggml-rpc-server.*--port $PORT" >/dev/null 2>&1
    sleep 1
    running && echo "[rpc] still running" || echo "[rpc] stopped; the 4090 is free for image work again"
    ;;

status)
    if running; then echo "up    rpc-server $BIND:$PORT   4090 used: $(vram_used) MiB"
    else echo "down  rpc-server            4090 used: $(vram_used) MiB"; fi
    ;;

*)
    echo "usage: $0 {start [--force]|stop|status}"; exit 2 ;;
esac
