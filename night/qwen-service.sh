#!/bin/bash
# Qwen3.8-27B — the overnight coder. Runs on specht, port 8089.
#
# The GLM on 8088 is left completely alone as a config, but the two cannot be
# *resident* at once: specht has 30 GB of VRAM and Qwen wants most of it. So
# `start` stops the GLM first and `glm` brings it back. Nothing is deleted
# either way — switching is a one-word command in both directions.
#
# Why this model: 64 layers but only 16 keep a KV cache (the other 48 use gated
# DeltaNet linear attention), so context is roughly 4x cheaper than a normal
# 27B. 262,144 is the native window and needs no rope scaling.
#
#   qwen-service.sh start [ctx]     # default 262144, native, no YaRN
#   qwen-service.sh start 1000000   # YaRN-scaled — see the warning below
#   qwen-service.sh stop | status | glm
#
# A ctx above 262144 switches on static YaRN, which stretches position encoding
# for every prompt, including short ones. It buys context by making the model
# slightly worse at everything else. Only ask for it if you need it.

set -u
LLAMA=~/llama/b10717
MODEL=~/models/Qwen3.8-27B-UD-Q5_K_S.gguf
GLM_MODEL=~/models/GLM-4.7-Flash-UD-Q3_K_XL.gguf
PORT=8089
GLM_PORT=8088
NATIVE_CTX=262144
LOGDIR=~/logs
ADLER_RPC="192.168.178.171:50052"   # same LAN, not through a tunnel

mkdir -p "$LOGDIR"

running() { pgrep -f "llama-server.*--port $1" >/dev/null 2>&1; }

stop_port() {
    pkill -f "llama-server.*--port $1" >/dev/null 2>&1
    for _ in $(seq 20); do running "$1" || return 0; sleep 0.5; done
}

case "${1:-status}" in

start)
    ctx="${2:-$NATIVE_CTX}"
    [ -f "$MODEL" ] || { echo "model not found: $MODEL"; exit 1; }

    # One model at a time on this card set.
    if running "$GLM_PORT"; then
        echo "[qwen] stopping GLM on $GLM_PORT to free VRAM"
        stop_port "$GLM_PORT"
    fi
    stop_port "$PORT"

    args=(-m "$MODEL" --host 127.0.0.1 --port "$PORT"
          --device Vulkan1,Vulkan2          # the two AMD cards; Vulkan0 is the Intel iGPU
          -ngl 999 -np 1                    # one slot: the whole window goes to one conversation
          -c "$ctx"
          -ctk q8_0 -ctv q8_0               # halves KV vs f16 at negligible quality cost
          --jinja                           # required for this model's tool-call template
          --no-mmap)

    # Borrow adler's 4090 over the LAN when its rpc-server is up. That is what
    # makes contexts past ~300k possible at all.
    if timeout 2 bash -c "</dev/tcp/${ADLER_RPC%%:*}/${ADLER_RPC##*:}" 2>/dev/null; then
        echo "[qwen] adler rpc-server reachable — adding its 4090 to the pool"
        args+=(--rpc "$ADLER_RPC")
    else
        echo "[qwen] adler rpc-server not up; running on specht's two cards only"
    fi

    if [ "$ctx" -gt "$NATIVE_CTX" ]; then
        scale=$(awk "BEGIN{printf \"%.4f\", $ctx/$NATIVE_CTX}")
        echo "[qwen] ctx $ctx > native $NATIVE_CTX — enabling YaRN x$scale (costs short-prompt quality)"
        args+=(--rope-scaling yarn --rope-scale "$scale" --yarn-orig-ctx "$NATIVE_CTX")
    fi

    echo "[qwen] starting: ctx=$ctx"
    cd "$LLAMA" || exit 1
    LD_LIBRARY_PATH="$LLAMA" setsid nohup ./llama-server "${args[@]}" \
        >> "$LOGDIR/qwen-server.log" 2>&1 < /dev/null &
    echo "[qwen] launched; watch $LOGDIR/qwen-server.log (a 262k context takes a while to allocate)"
    ;;

stop)
    stop_port "$PORT" && echo "[qwen] stopped"
    ;;

glm)
    stop_port "$PORT"
    if running "$GLM_PORT"; then echo "[glm] already running"; exit 0; fi
    cd "$LLAMA" || exit 1
    LD_LIBRARY_PATH="$LLAMA" setsid nohup ./llama-server -m "$GLM_MODEL" \
        --device Vulkan1,Vulkan2 -ngl 999 -c 131072 -np 1 -ctk q8_0 -ctv q8_0 \
        --host 127.0.0.1 --port "$GLM_PORT" \
        >> "$LOGDIR/glm-server.log" 2>&1 < /dev/null &
    echo "[glm] restored on $GLM_PORT (131k)"
    ;;

status)
    for p in "$PORT:qwen3.8-27b" "$GLM_PORT:glm-4.7-flash"; do
        port="${p%%:*}"; name="${p##*:}"
        if running "$port"; then
            ctx=$(curl -s --max-time 3 "http://127.0.0.1:$port/props" \
                  | grep -o '"n_ctx":[0-9]*' | head -1 | cut -d: -f2)
            echo "up    $name  port $port  ctx ${ctx:-?}"
        else
            echo "down  $name  port $port"
        fi
    done
    ;;

*)
    echo "usage: $0 {start [ctx]|stop|glm|status}"; exit 2 ;;
esac
