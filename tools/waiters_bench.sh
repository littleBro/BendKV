#!/bin/sh
# waiters_bench.sh [SERVER]: GET throughput while other clients wait in
# BLPOP or hold a WATCH, on SERVER (build/bendkv) and on redis-server. Each
# server runs on CPU 3, redis-benchmark on CPU 1 and the idle clients
# (tools/idle_clients.py) on CPU 0, as bench_pairs.sh pins them. KEYS
# (100000) keys are set first, then N (200000) GETs run from 20 clients at
# pipeline depth 16, with 0, 1, 100 and 1000 idle clients in BLPOP on keys
# of their own, with one idle client after WATCH, one that tracks keys
# (CLIENT TRACKING) and one in BCAST mode; TRIALS (2) rounds, interleaved.
# A waiting or watching client should cost other keys' commands nothing,
# as in Redis; so should a client that tracks, but one in BCAST mode sends
# every batch the general way (FINDINGS.md 3zzzb). TEST (get) is the
# command measured, MODES the idle clients of each run, as mode:count
# (tools/idle_clients.py's modes; none:0 for none).
here=$(cd "$(dirname "$0")" && pwd)
SERVER=${1:-build/bendkv}
KEYS=${KEYS:-100000}; N=${N:-200000}; TRIALS=${TRIALS:-2}; PORT=${PORT:-6653}; TEST=${TEST:-get}
MODES=${MODES:-none:0 blpop:1 blpop:100 blpop:1000 watch:1 track:1 bcast:1}
up() {
  for i in $(seq 1 50); do redis-cli -p "$PORT" ping > /dev/null 2>&1 && return 0; sleep 0.1; done
  return 1
}
one() { # server mode count
  if [ "$1" = redis ]; then
    taskset -c 3 redis-server --port "$PORT" --save '' --appendonly no > /dev/null 2>&1 &
  else
    taskset -c 3 "$SERVER" "$PORT" > /dev/null 2>&1 &
  fi
  sp=$!
  up
  taskset -c 1 redis-benchmark -p "$PORT" -t set -r "$KEYS" -n $((KEYS * 3)) -c 20 -P 64 -q > /dev/null 2>&1
  ip=
  if [ "$2" != none ]; then
    out=$(mktemp)
    taskset -c 0 python3 "$here/idle_clients.py" "$PORT" "$2" "$3" > "$out" 2>&1 &
    ip=$!
    for i in $(seq 1 100); do grep -q READY "$out" && break; sleep 0.1; done
    rm -f "$out"
  fi
  rps=$(taskset -c 1 redis-benchmark -p "$PORT" -t "$TEST" -r "$KEYS" -n "$N" -c 20 -P 16 --csv 2>/dev/null | tail -1 | cut -d, -f2 | tr -d '"')
  printf "%-7s %-9s %5s  %12s %s/s\n" "$1" "$2" "$3" "$rps" "$TEST"
  [ -n "$ip" ] && kill "$ip" 2> /dev/null
  kill "$sp"; wait "$sp" 2> /dev/null; sleep 0.3
}
for t in $(seq 1 "$TRIALS"); do
  for s in bendkv redis; do
    for m in $MODES; do
      one $s "${m%:*}" "${m#*:}"
    done
  done
done
