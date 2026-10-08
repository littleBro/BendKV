#!/bin/sh
# scale_bench.sh OUT TRIALS SERVER...: throughput as a server gets more
# cores. Each SERVER (a binary that takes its port as its first argument,
# its extra arguments after commas, as memtier_specs.py takes them; or
# "redis" and "redis,N" for N io-threads) runs on CPUS (default 1-3), and
# tools/loadgen (built here) loads it from LOADCPU (default 0): one
# preload of KEYS keys of VAL bytes, then for each of the load shapes in
# SHAPES (pipeline depth and GET share, "10:1.0 1:1.0 10:0.5" by default)
# SECS seconds after a second of warm-up, CONNS connections. Interleaved:
# every trial runs every server on a fresh process. One line per run in
# OUT: trial, server, shape, ops/s.
set -e
here=$(cd "$(dirname "$0")" && pwd)
OUT=$1
TRIALS=$2
shift 2
CPUS=${CPUS:-1-3}
LOADCPU=${LOADCPU:-0}
KEYS=${KEYS:-1000000}
VAL=${VAL:-100}
SECS=${SECS:-10}
CONNS=${CONNS:-100}
SHAPES=${SHAPES:-"10:1.0 1:1.0 10:0.5"}
PORT=${PORT:-6493}
LG=$(mktemp -d)/loadgen
cc -O2 -o "$LG" "$here/loadgen.c"

start() {
  srv=$1
  bin=${srv%%,*}
  rest=$(echo "$srv" | sed -n 's/^[^,]*,//p' | tr ',' ' ')
  if [ "$bin" = "redis" ]; then
    io=""
    [ -n "$rest" ] && io="--io-threads $rest --io-threads-do-reads yes"
    taskset -c "$CPUS" redis-server --port "$PORT" --save '' --appendonly no $io > /dev/null 2>&1 &
  else
    taskset -c "$CPUS" "$bin" "$PORT" $rest > /dev/null 2>&1 &
  fi
  PID=$!
  for i in $(seq 1 100); do
    redis-cli -p "$PORT" ping > /dev/null 2>&1 && return 0
    sleep 0.1
  done
  echo "server $srv did not start" >&2
  exit 1
}

for t in $(seq 1 "$TRIALS"); do
  for srv in "$@"; do
    start "$srv"
    taskset -c "$LOADCPU" "$LG" -p "$PORT" -r "$KEYS" -d "$VAL" -s 1 -c 1 -P 1 > /dev/null
    for shape in $SHAPES; do
      p=${shape%%:*}
      g=${shape##*:}
      ops=$(taskset -c "$LOADCPU" "$LG" -p "$PORT" -L 0 -r "$KEYS" -d "$VAL" -s "$SECS" -c "$CONNS" -P "$p" -g "$g")
      tag=$(basename "$srv")
      echo "$t	$tag	P$p get$g	$ops" | tee -a "$OUT"
    done
    kill "$PID"
    wait "$PID" 2> /dev/null || true
  done
done
