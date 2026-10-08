#!/bin/sh
# pgo_build.sh FILE.c OUT: builds BendKV's generated C (bend src/server.bend -o
# FILE.c) with profile-guided optimization, as `make pgo` does. An
# instrumented build serves a training load from redis-benchmark (SET, GET,
# INCR and MSET, pipelined and not, with replies posted and sent), and OUT is
# built again with its profile. The flags are bend's own (-std=c11 -O3).
# Needs clang and the llvm-profdata of the same version, redis-benchmark
# and redis-cli. Retrain after any change to the C: a stale profile only
# loses its gains.
set -e
here=$(cd "$(dirname "$0")" && pwd)
C=$1
OUT=$2
CC=${CC:-clang-19}
ver=$($CC --version | sed -n 's/.*clang version \([0-9]*\).*/\1/p' | head -n 1)
PROFDATA=${PROFDATA:-$(command -v "llvm-profdata-$ver" || command -v llvm-profdata)}
PORT=${PORT:-6697}
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
cc -O2 -shared -fPIC "$here/pgo_exit.c" -o "$W/pgo_exit.so"
$CC -std=c11 -O3 -w -fprofile-instr-generate "$C" -lpthread -lm -o "$W/gen"

bench() {
  redis-benchmark -p "$PORT" -q "$@" > /dev/null 2>&1
}

# serves the training load, its replies posted or sent ($1)
train() {
  LLVM_PROFILE_FILE="$W/run-%p.profraw" LD_PRELOAD="$W/pgo_exit.so" \
    "$W/gen" "$PORT" "$1" > /dev/null 2>&1 &
  pid=$!
  for i in $(seq 1 100); do
    redis-cli -p "$PORT" ping > /dev/null 2>&1 && break
    sleep 0.1
  done
  bench -t set -r 100000 -n 200000 -c 20 -P 64 -d 100
  bench -t get,set,incr,mset -r 100000 -n 300000 -c 50 -P 10 -d 100
  bench -t get,set -r 100000 -n 100000 -c 50 -d 100
  bench -t get -r 100000 -n 100000 -c 10 -P 100 -d 10
  kill -USR2 "$pid"
  wait "$pid" 2> /dev/null || true
}

train post
train send
"$PROFDATA" merge -o "$W/pgo.profdata" "$W"/run-*.profraw
$CC -std=c11 -O3 -w -fprofile-instr-use="$W/pgo.profdata" "$C" -lpthread -lm -o "$OUT"
