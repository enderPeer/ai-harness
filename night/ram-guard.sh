#!/bin/bash
# Kill the model server before it takes the machine down.
#
# The precheck in qwen-service.sh reasons about VRAM, and that turned out not to
# be the binding constraint: with an RPC backend attached, llama.cpp put specht's
# share of the model in GTT — system RAM mapped for the GPU — rather than in the
# cards' own VRAM. Free VRAM therefore says nothing about whether the machine is
# about to run out of memory.
#
# This watchdog watches the thing that actually kills the box. When a machine
# starves this badly, sshd can no longer fork, so there is no way in to fix it
# by hand: the last process able to act is one that was already running. That is
# this.
#
#   ram-guard.sh start [floor_mib]   # default 4096
#   ram-guard.sh stop | status
#
# On trip it SIGKILLs llama-server — not TERM. A server unmapping tens of GB
# takes far too long to honour TERM, and by then the box is unreachable.

set -u
FLOOR="${2:-4096}"
PIDFILE=~/.ram-guard.pid
LOG=~/logs/ram-guard.log
mkdir -p ~/logs

case "${1:-status}" in

start)
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        echo "[guard] already running (pid $(cat "$PIDFILE"), floor ${FLOOR} MiB)"; exit 0
    fi
    setsid nohup bash -c '
        floor='"$FLOOR"'
        while true; do
            avail=$(awk "/MemAvailable/ {print int(\$2/1024)}" /proc/meminfo)
            if [ "${avail:-999999}" -lt "$floor" ]; then
                pids=$(pgrep -f "llama-server")
                echo "[$(date "+%F %T")] TRIPPED: ${avail} MiB available < ${floor} MiB floor; SIGKILL to: ${pids:-none}"
                [ -n "$pids" ] && kill -9 $pids
                sleep 30
            fi
            sleep 5
        done' >> "$LOG" 2>&1 < /dev/null &
    echo $! > "$PIDFILE"
    sleep 1
    echo "[guard] watching MemAvailable, floor ${FLOOR} MiB (pid $(cat "$PIDFILE"))"
    echo "[guard] log: $LOG"
    ;;

stop)
    [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null
    rm -f "$PIDFILE"
    echo "[guard] stopped"
    ;;

status)
    avail=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        echo "up    ram-guard (pid $(cat "$PIDFILE"))   MemAvailable: ${avail} MiB"
    else
        echo "down  ram-guard                  MemAvailable: ${avail} MiB"
    fi
    [ -s "$LOG" ] && { echo "--- trips so far ---"; grep -c TRIPPED "$LOG"; tail -2 "$LOG"; }
    ;;

*)
    echo "usage: $0 {start [floor_mib]|stop|status}"; exit 2 ;;
esac
