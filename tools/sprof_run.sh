#!/bin/sh
# sprof_run.sh SERVER OUT [TEST] [P]: samples a server under redis-benchmark
# load with sprof.so (no PMU needed). SERVER is a server binary taking its
# port as its argument, or "redis". The server runs pinned to CPU 3, the
# client to CPU 1; 100k keys are set first, unsampled, then TEST (get) runs
# 1.6M requests at pipeline depth P (16), sampled every SPROF_US us (500:
# at 50 the signals halve the server's speed, the shares stay). With WARM
# set, TEST runs once unsampled first (INCR then finds its counters).
# Report with
#   python3 tools/sprof_report.py OUT 40 <server file name>
# (build the server -no-pie so its own symbols resolve).
set -e
here=$(cd "$(dirname "$0")" && pwd)
SERVER=$1; OUT=$2; T=${3:-get}; P=${4:-16}; PORT=${PORT:-6399}
cc -O2 -shared -fPIC "$here/sprof.c" -o "$OUT.so"
if [ "$SERVER" = redis ]; then
  set -- redis-server --port "$PORT" --save '' --appendonly no
else
  set -- "$SERVER" "$PORT"
fi
SPROF_WAIT=1 SPROF_OUT="$OUT" SPROF_US=${SPROF_US:-500} LD_PRELOAD="$OUT.so" taskset -c 3 "$@" > /dev/null 2>&1 &
PID=$!
for i in $(seq 1 50); do redis-cli -p "$PORT" ping > /dev/null 2>&1 && break; sleep 0.1; done
taskset -c 1 redis-benchmark -p "$PORT" -t set -r 100000 -n 300000 -c 20 -P 64 -q > /dev/null 2>&1
if [ -n "$WARM" ]; then
  taskset -c 1 redis-benchmark -p "$PORT" -t "$T" -r 100000 -n 1600000 -c 20 -P "$P" -q > /dev/null 2>&1
fi
kill -USR1 $PID
taskset -c 1 redis-benchmark -p "$PORT" -t "$T" -r 100000 -n 1600000 -c 20 -P "$P" --csv 2>/dev/null | tail -1
kill $PID
wait $PID 2>/dev/null || true
rm -f "$OUT.so"
