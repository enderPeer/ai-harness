#!/bin/bash
# The overnight coder. Serves whichever model NIGHT_MODEL points at on port
# 8089; memory constants for each known model are in the table below. Every
# host-specific value is an environment override, so moving to another box is a
# matter of NIGHT_* variables rather than an edit.
#
#   Qwen3-Coder-Next   80B MoE, ~3B active, coding-specialised, no thinking
#                      mode. 36.6 GB of weights: needs specht AND adler's 4090
#                      pooled over RPC. Cheap context (~12.75 KiB/token).
#   Qwen3.8-27B        dense, fits specht alone, ~34 KiB/token.
#
# The GLM on 8088 is left completely alone as a config, but the two cannot be
# *resident* at once: specht has 30 GB of VRAM and Qwen wants most of it. So
# `start` stops the GLM first and `glm` brings it back. Nothing is deleted
# either way — switching is a one-word command in both directions.
#
# Both models are hybrid-attention: only every 4th layer keeps a KV cache, the
# rest use gated DeltaNet, which is why a 262k window costs single-digit GB.
#
#   qwen-service.sh start [ctx]     # default 262144, native, no YaRN
#   qwen-service.sh stop | status | glm
#
# Do not bother asking for more than 262144. llama-server caps the slot at the
# model's trained context and logs "exceeds the training context - capping";
# a larger -c allocates the memory and gives you nothing back. Measured.

set -u
# Everything host-specific is overridable, so moving this stack to another box
# is a handful of environment variables rather than an edit. Defaults describe
# specht: two AMD cards on Vulkan1/Vulkan2 (Vulkan0 is an Intel iGPU) exposed
# as DRM card0 and card2.
LLAMA="${NIGHT_LLAMA:-$HOME/llama/b10717}"
MODEL="${NIGHT_MODEL:-$HOME/models/Qwen3.8-27B-UD-Q5_K_S.gguf}"
GLM_MODEL="${NIGHT_GLM_MODEL:-$HOME/models/GLM-4.7-Flash-UD-Q3_K_XL.gguf}"
PORT="${NIGHT_PORT:-8089}"
GLM_PORT="${NIGHT_GLM_PORT:-8088}"
NATIVE_CTX=262144                          # a property of the model, not the host
LOGDIR="${NIGHT_LOGDIR:-$HOME/logs}"
DEVICES="${NIGHT_DEVICES:-Vulkan1,Vulkan2}"
CARDS="${NIGHT_CARDS:-0 2}"                # DRM cards to total free VRAM over
ADLER_RPC="${NIGHT_RPC:-192.168.178.171:50052}"   # same LAN, not through a tunnel

# Per-model memory constants. KV bytes/token is read off each model's own GGUF
# metadata, not guessed: (layers / full_attention_interval) x 2 for K and V
# x head_count_kv x key_length, at ~1.0625 bytes per value for q8_0.
#
#   Qwen3-Coder-Next  48 layers, interval 4 => 12 keep KV, 2 kv heads, dim 256
#                     => 12*2*2*256*1.0625  = ~13056 B/token
#   Qwen3.8-27B       64 layers, interval 4 => 16 keep KV, 4 kv heads, dim 256
#                     => 16*2*4*256*1.0625  = ~34816 B/token
case "$(basename "$MODEL")" in
    *Coder-Next*)   DEF_WEIGHTS=36650; DEF_KV=13056 ;;
    *Qwen3.8-27B*)  DEF_WEIGHTS=18700; DEF_KV=34816 ;;
    *)              DEF_WEIGHTS=20000; DEF_KV=34816 ;;   # unknown: assume the costlier shape
esac
WEIGHTS_MIB="${NIGHT_WEIGHTS_MIB:-$DEF_WEIGHTS}"
KV_BYTES="${NIGHT_KV_BYTES:-$DEF_KV}"

mkdir -p "$LOGDIR"

running() { pgrep -f "llama-server.*--port $1" >/dev/null 2>&1; }

# Stop whatever serves $1 and do not return success until it is actually gone.
# SIGTERM first, then SIGKILL: a server unmapping 13 GB of VRAM can sit in
# TERM for a long time, and "I asked it to stop" is not the same as "it stopped".
stop_port() {
    local port="$1" pids
    running "$port" || return 0
    pkill -f "llama-server.*--port $port" >/dev/null 2>&1
    for _ in $(seq 60); do running "$port" || return 0; sleep 0.5; done

    pids=$(pgrep -f "llama-server.*--port $port")
    echo "[stop] port $port ignored SIGTERM for 30s; sending SIGKILL to: $pids"
    kill -9 $pids 2>/dev/null
    for _ in $(seq 20); do running "$port" || return 0; sleep 0.5; done

    echo "[stop] FAILED: something is still serving port $port"
    return 1
}

# Free VRAM across the two AMD cards, in MiB.
free_vram_mib() {
    local total=0 c t
    for c in $CARDS; do
        t=/sys/class/drm/card$c/device
        [ -f "$t/mem_info_vram_total" ] || continue
        total=$(( total + ($(cat "$t/mem_info_vram_total") - $(cat "$t/mem_info_vram_used")) / 1048576 ))
    done
    echo "$total"
}

case "${1:-status}" in

start|foreground)
    # `start` detaches (interactive use); `foreground` execs the server so
    # systemd can supervise it. Every check below runs identically in both.
    mode="$1"
    ctx="${2:-$NATIVE_CTX}"
    [ -f "$MODEL" ] || { echo "model not found: $MODEL"; exit 1; }

    # One model at a time on this card set. Loading a second one while the first
    # is still resident overcommits the cards, spills into system RAM, and takes
    # the whole box down to where sshd cannot fork — so this is a hard gate, not
    # a best effort. It has happened; do not soften it.
    if running "$GLM_PORT"; then
        echo "[qwen] stopping GLM on $GLM_PORT to free VRAM"
        if ! stop_port "$GLM_PORT"; then
            echo "[qwen] ABORTING: the GLM is still holding VRAM. Nothing was started."
            exit 1
        fi
    fi
    if ! stop_port "$PORT"; then
        echo "[qwen] ABORTING: port $PORT is still occupied. Nothing was started."
        exit 1
    fi

    # Decide about the RPC backend FIRST — the memory check below depends on
    # whether adler's 24 GB is in the pool, and the device list depends on it too.
    rpc_device=""
    if timeout 2 bash -c "</dev/tcp/${ADLER_RPC%%:*}/${ADLER_RPC##*:}" 2>/dev/null; then
        # Ask llama.cpp what it calls the remote card. Guessing the name is how
        # adler ended up idle while specht tried to hold the whole model alone:
        # naming only Vulkan1,Vulkan2 in --device silently EXCLUDES the RPC
        # device, so the backend connects, is never given work, and disconnects.
        rpc_device=$(cd "$LLAMA" && LD_LIBRARY_PATH="$LLAMA" ./llama-server --rpc "$ADLER_RPC" \
                     --list-devices 2>/dev/null | grep -oiE "^\s*(RPC[0-9]+)" | head -1 | tr -d ' ')
        if [ -n "$rpc_device" ]; then
            echo "[qwen] adler's 4090 joins the pool as device $rpc_device"
        else
            echo "[qwen] adler's rpc-server answers but llama.cpp lists no RPC device;"
            echo "[qwen] continuing on specht's cards alone rather than pretending it helps."
        fi
    else
        echo "[qwen] adler rpc-server not up; specht's two cards only"
    fi

    # Does the requested context actually FIT? This is the check whose absence
    # took the box down: "20 GB is free" says nothing about whether a 1M window
    # needs 52. llama.cpp will not refuse — it spills the overflow into system
    # RAM and the machine dies with sshd unable to fork.
    #
    # KV maths for this model: 16 of 64 layers keep a cache (the rest are gated
    # DeltaNet), 4 KV heads x 256 head_dim x 2 for K and V = 32768 values/token,
    # ~1.0625 bytes each at q8_0 => ~34 KiB per token.
    # Compute buffers scale with context and are allocated PER DEVICE, which a
    # flat allowance got badly wrong: a 1M attempt died on
    # "failed to allocate RPC0 buffer of size 4305584256" — 4.3 GB on one card,
    # after weights and KV had already filled it. Measured at ~4.4 GB per device
    # per 1M tokens; three devices in the pool.
    kv_mib=$(( ctx * KV_BYTES / 1048576 ))
    ndev=2; [ -n "${rpc_device:-}" ] && ndev=3
    compute_mib=$(( ctx * 4400 * ndev / 1000000 ))
    [ "$compute_mib" -lt 2000 ] && compute_mib=2000
    need=$(( WEIGHTS_MIB + kv_mib + compute_mib ))
    have=$(free_vram_mib)

    # An attached RPC backend adds its own VRAM to the pool — but only if the
    # device list below actually includes it.
    if [ -n "${rpc_device:-}" ]; then
        have=$(( have + ${RPC_VRAM_MIB:-23000} ))
    fi

    echo "[qwen] ctx $ctx needs ~${kv_mib} MiB KV + ${WEIGHTS_MIB} weights + ${compute_mib} compute = ~${need} MiB; ${have} MiB available"
    if [ "$need" -gt "$have" ]; then
        # Solve for the context where KV + per-device compute buffers exhaust
        # what is left after the weights.
        fits=$(awk "BEGIN{printf \"%d\", ($have - $WEIGHTS_MIB) / ($KV_BYTES/1048576.0 + 4400*$ndev/1000000.0)}")
        echo "[qwen] ABORTING: that does not fit. Nothing was started."
        echo "[qwen] the largest context this pool holds is about ${fits} tokens."
        [ -z "${rpc_device:-}" ] && echo "[qwen] (start adler's rpc-server to add its 4090 and try again)"
        exit 1
    fi

    # NIGHT_DEVICES excludes any integrated GPU on purpose. The RPC device is
    # appended only when llama.cpp actually reported one.
    devices="$DEVICES"
    [ -n "$rpc_device" ] && devices="$devices,$rpc_device"

    # --rpc MUST precede --device. Arguments are validated in order, so naming
    # RPC0 before the RPC backend is registered fails with "invalid device:
    # RPC0" and the server exits during startup.
    args=(-m "$MODEL" --host 127.0.0.1 --port "$PORT")
    [ -n "$rpc_device" ] && args+=(--rpc "$ADLER_RPC")
    args+=(--device "$devices"
           -ngl 999 -np 1                   # one slot: the whole window goes to one conversation
           -c "$ctx"
           -ctk q8_0 -ctv q8_0              # halves KV vs f16 at negligible quality cost
           --jinja                          # required for this model's tool-call template
           --no-mmap)
    echo "[qwen] devices: $devices"

    if [ "$ctx" -gt "$NATIVE_CTX" ]; then
        scale=$(awk "BEGIN{printf \"%.4f\", $ctx/$NATIVE_CTX}")
        echo "[qwen] ctx $ctx > native $NATIVE_CTX — enabling YaRN x$scale (costs short-prompt quality)"
        args+=(--rope-scaling yarn --rope-scale "$scale" --yarn-orig-ctx "$NATIVE_CTX")
    fi

    echo "[qwen] starting: ctx=$ctx (mode: $mode)"
    cd "$LLAMA" || exit 1

    if [ "$mode" = "foreground" ]; then
        # Under systemd: become the server, so the unit tracks the real process
        # and a crash is a unit failure rather than a silently missing daemon.
        export LD_LIBRARY_PATH="$LLAMA"
        exec ./llama-server "${args[@]}"
    fi

    LD_LIBRARY_PATH="$LLAMA" setsid nohup ./llama-server "${args[@]}" \
        >> "$LOGDIR/qwen-server.log" 2>&1 < /dev/null &
    child=$!

    # "launched" is not the same as "running". A bad argument makes llama-server
    # exit in under a second while this script cheerfully reports success — that
    # is how an "invalid device: RPC0" went unnoticed through a whole load wait.
    sleep 6
    if ! kill -0 "$child" 2>/dev/null && ! running "$PORT"; then
        echo "[qwen] FAILED: the server exited during startup. Last lines:"
        grep -iE "error|invalid|failed|unknown|usage" "$LOGDIR/qwen-server.log" | tail -5
        exit 1
    fi
    echo "[qwen] running (pid $child); loading — a large context takes minutes to allocate."
    echo "[qwen] watch: tail -f $LOGDIR/qwen-server.log"
    ;;

stop)
    stop_port "$PORT" && echo "[qwen] stopped"
    ;;

glm)
    stop_port "$PORT"
    if running "$GLM_PORT"; then echo "[glm] already running"; exit 0; fi
    cd "$LLAMA" || exit 1
    LD_LIBRARY_PATH="$LLAMA" setsid nohup ./llama-server -m "$GLM_MODEL" \
        --device "$DEVICES" -ngl 999 -c 131072 -np 1 -ctk q8_0 -ctv q8_0 \
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
