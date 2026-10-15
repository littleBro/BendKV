#!/bin/sh
# sanitize.sh: BendKV under the sanitizers, CI's sanitize job
# (.github/workflows/ci.yml) as one script, run here as it runs there.
# The generated C (make build/bendkv.c) is built twice more as
# tools/pgo_build.sh builds it (-std=c11 ... -lpthread -lm), at -O1 with
# frame pointers and line tables: with AddressSanitizer and
# UndefinedBehaviorSanitizer, and with ThreadSanitizer. Under ASan the
# runtime also poisons the free nodes of the Bend heap and holds each freed
# node in a quarantine before it is handed out again (the thirty-fourth
# patch, bend-patches/heap-asan.patch): the heap is one mapping, all of it
# addressable to ASan, and its free chains hand a node out again at once,
# so without the patch a node used after its free goes unseen.
#
# Each build serves, with its replies posted to the writer thread (post)
# and sent from its loop (send), the tests most likely to meet what the
# compiler's reference counts, borrowing and reuse of nodes and the writer
# thread can get wrong: a client that stops reading, clients that wait,
# transactions, Pub/Sub, the protocol's edge cases, the statistics per
# command (commands run with their replies held back by CLIENT REPLY OFF,
# then the statistics read: the crash patch 26 fixed), RESP3 (a client
# subscribed to keyspace events that runs commands: without patch 26 ASan
# reports a node used after its free there), Lua scripts (the engine's C
# stack, switched to and from at each call and tick, with the fiber
# annotations the sanitizers follow), the differential test (three
# seeds), the concurrency checks, and a load from redis-benchmark like
# tools/pgo_build.sh's (50 clients pipelined, then 100 not), under which
# the loop falls behind and posts to its writer; connections that end come
# first (conn_test.py starts its servers itself, in both modes). The tests
# that compare do so with a Redis 7.0.15 the script starts. A sanitizer's
# report, a test that fails or a server that dies fails the run. The
# reports stay in build/sanitize/reports, one file per process, the
# servers' logs in build/sanitize.
#
# ASan leaves out one check: a stack frame used after its function returns
# (-fsanitize-address-use-after-return=never). It moves the frames of the
# functions it instruments to a heap of its own, and LLVM 19 cannot lay out
# such a frame under the runtime's preserve_none and preserve_most calling
# conventions ("Stack realignment in presence of dynamic allocas is not
# supported with this calling convention"). UBSan and TSan run whole, with
# no check left out and nothing suppressed: neither reports anything here.
#
#   BEND="bun ../bend-patched/bend2/main.ts" PORT=6380 REDIS_PORT=6390 sh tools/sanitize.sh
#
# Needs clang 19 with its sanitizers' runtimes (libclang-rt-19-dev on
# Ubuntu), llvm-symbolizer for the reports' stacks, redis-server, redis-cli
# and redis-benchmark 7.0.15, and python3. CC is split into words, so it
# may name a wrapper before the compiler.
set -e
cd "$(dirname "$0")/.."
CC=${CC:-clang-19}
PORT=${PORT:-6380}
REDIS_PORT=${REDIS_PORT:-6390}
ROUNDS=${ROUNDS:-1000}
OUT=build/sanitize
REP=$PWD/$OUT/reports
rm -rf "$OUT"
mkdir -p "$REP"

make build/bendkv.c BEND="${BEND:-bend}"
if ! grep -q "define HEAP_ASAN" build/bendkv.c; then
  echo "FAIL: build/bendkv.c has no HEAP_ASAN: build it again with Bend patched by bend-patches/heap-asan.patch"
  exit 1
fi

# each process writes its reports to a file of its own (the ASan build's
# UBSan reports with its ASan ones), with symbols; a fault gets ASan's
# report and stack, not the one line of the runtime's own handler
# (allow_user_segv_handler=0)
sym=
for s in llvm-symbolizer-19 llvm-symbolizer /usr/lib/llvm-*/bin/llvm-symbolizer; do
  if [ -z "$sym" ] && command -v "$s" > /dev/null; then
    sym=":external_symbolizer_path=$(readlink -f "$(command -v "$s")")"
  fi
done
export ASAN_OPTIONS="log_path=$REP/asan:allow_user_segv_handler=0$sym"
export UBSAN_OPTIONS="log_path=$REP/asan:print_stacktrace=1:report_error_type=1$sym"
export TSAN_OPTIONS="log_path=$REP/tsan$sym"

RDS=
BKV=
# the server of the mode that runs, stopped
stop() {
  if [ -n "$BKV" ]; then
    kill "$BKV" 2> /dev/null || true
    wait "$BKV" 2> /dev/null || true
    BKV=
  fi
}
# fails if a sanitizer reported, and shows what it reported
reports() {
  if [ -n "$(ls "$REP")" ]; then
    for f in "$REP"/*; do
      echo "== $f"
      cat "$f"
    done
    echo "FAIL: the sanitizers reported (build/sanitize/reports)"
    return 1
  fi
}
finish() {
  stop
  kill "$RDS" 2> /dev/null || true
  reports || exit 1
}
trap finish EXIT

LC_ALL=C redis-server --port "$REDIS_PORT" --save '' --appendonly no --bind 127.0.0.1 > "$OUT/redis.log" 2>&1 &
RDS=$!

# a test against the server BKV, which must still serve after it
t() {
  echo "-- $*"
  "$@"
  if ! kill -0 "$BKV" 2> /dev/null; then
    echo "FAIL: the server died ($log)"
    tail -n 20 "$log"
    exit 1
  fi
}

FLAGS="-std=c11 -O1 -gline-tables-only -fno-omit-frame-pointer"
# the Lua engine's sources and flags beside the emitted C (as the
# Makefile builds it); the engine's stack switches carry the sanitizers'
# fiber annotations (src/lua/engine.c)
DEPS_SRC="deps/redis/deps/lua/src/*.c deps/redis/src/*.c"
DEPS_FLAGS="-I deps/redis/deps/lua/src -I deps/redis/src -DENABLE_CJSON_GLOBAL -DREDIS_STATIC= -DLUA_USE_MKSTEMP -D_GNU_SOURCE"
for san in asan tsan; do
  echo "== $san: the build"
  if [ "$san" = asan ]; then
    $CC $FLAGS -fsanitize=address,undefined -fsanitize-address-use-after-return=never \
      build/bendkv.c $DEPS_SRC $DEPS_FLAGS -lpthread -lm -o "$OUT/bendkv-$san"
  else
    $CC $FLAGS -fsanitize=thread build/bendkv.c $DEPS_SRC $DEPS_FLAGS -lpthread -lm -o "$OUT/bendkv-$san"
  fi
  echo "== $san: connections that end"
  python3 tests/conn_test.py --bin "$OUT/bendkv-$san" --port "$PORT"
  for mode in post send; do
    echo "== $san, $mode"
    log=$OUT/$san-$mode.log
    "$OUT/bendkv-$san" "$PORT" "$mode" > "$log" 2>&1 &
    BKV=$!
    for i in $(seq 1 100); do
      redis-cli -p "$PORT" ping > /dev/null 2>&1 && break
      sleep 0.2
    done
    t python3 tests/writer_test.py --port "$PORT"
    t python3 tests/blocking_test.py --bendkv "$PORT" --redis "$REDIS_PORT"
    t python3 tests/multi_test.py --bendkv "$PORT" --redis "$REDIS_PORT"
    t python3 tests/pubsub_test.py --bendkv "$PORT" --redis "$REDIS_PORT"
    t python3 tests/protocol_test.py --bendkv "$PORT" --redis "$REDIS_PORT"
    t python3 tests/stats_test.py --bendkv "$PORT" --redis "$REDIS_PORT"
    t python3 tests/resp3_test.py --bendkv "$PORT" --redis "$REDIS_PORT"
    t python3 tests/script_test.py --bendkv "$PORT" --redis "$REDIS_PORT"
    for seed in 1 2 3; do
      redis-cli -p "$REDIS_PORT" flushall > /dev/null
      redis-cli -p "$PORT" flushall > /dev/null
      t python3 tests/diff_test.py --bendkv "$PORT" --redis "$REDIS_PORT" --rounds "$ROUNDS" --seed "$seed"
    done
    t python3 tests/concurrency_test.py --port "$PORT"
    t redis-benchmark -p "$PORT" --csv -t set,get,incr,lpush,lpop,mset -r 10000 -n 50000 -c 50 -P 10 -d 100
    t redis-benchmark -p "$PORT" --csv -t get,set -r 10000 -n 20000 -c 100 -d 100
    stop
  done
done
trap - EXIT
finish
echo "OK: no sanitizer reported"
