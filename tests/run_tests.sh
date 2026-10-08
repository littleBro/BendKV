#!/bin/sh
# Starts a reference Redis and BendKV on spare ports, with one shard, then
# with SHARDS (2) shards, sending their replies from their loops (send, the
# default for more than one shard), then posting them to writer threads
# (post), then with one shard and an append-only file, then with SHARDS
# shards and a file each, and runs against each BendKV the robustness
# checks, the differential test against Redis (a fresh Redis database for
# each run) and the consistency checks under concurrent clients; then
# stops them. Last, the append-only files, for one shard and for SHARDS: a
# random stream, a restart from the files, the keyspace compared; then a
# file's last entry cut short, as a crash in a write leaves it, a restart
# that cuts it back, and the keyspace compared again; and for the shards,
# a start with another shard count, which must be refused. Last, the disk
# failing under the files (tests/fail_io.c injects it): a file that is
# there but cannot be read must stop the start, and a failed fsync must
# stop the server, with everysec as with always.
set -e
cd "$(dirname "$0")/.."
PORT=${PORT:-6380}
REDIS_PORT=${REDIS_PORT:-6390}
ROUNDS=${ROUNDS:-1000}
SHARDS=${SHARDS:-2}
redis-server --port "$REDIS_PORT" --save '' --appendonly no > build/redis.log 2>&1 &
RDS=$!
BKV=
trap 'kill $BKV $RDS 2>/dev/null || true' EXIT
rm -f build/test.aof build/test.aof.* build/shard.aof.* build/aof_dump.txt
for n in 1 "$SHARDS" "$SHARDS post" "1 post build/test.aof everysec" "$SHARDS send build/shard.aof everysec"; do
  ./build/bendkv "$PORT" $n > build/server.log 2>&1 &
  BKV=$!
  sleep 0.5
  echo "== $n"
  python3 tests/robust_test.py --port "$PORT"
  for seed in 1 2 3; do
    redis-cli -p "$REDIS_PORT" flushall > /dev/null
    redis-cli -p "$PORT" flushall > /dev/null
    python3 tests/diff_test.py --bendkv "$PORT" --redis "$REDIS_PORT" --rounds "$ROUNDS" --seed "$seed"
  done
  python3 tests/concurrency_test.py --port "$PORT"
  kill "$BKV"
  wait "$BKV" 2>/dev/null || true
done
# restart: a stream and keys, the server restarted from its files, the
# keyspace compared; then CUT (a file) ends in an entry cut short, and the
# restart that cuts it back must give the same keyspace
restart() {
  k=$1; base=$2; cut=$3
  rm -f "$base" "$base".*
  ./build/bendkv "$PORT" $k send "$base" always > build/server.log 2>&1 &
  BKV=$!
  sleep 0.5
  python3 tests/aof_test.py --port "$PORT" --rounds "$ROUNDS" --write build/aof_dump.txt
  kill "$BKV"
  wait "$BKV" 2>/dev/null || true
  size=$(wc -c < "$cut")
  ./build/bendkv "$PORT" $k send "$base" always > build/server.log 2>&1 &
  BKV=$!
  sleep 0.5
  python3 tests/aof_test.py --port "$PORT" --check build/aof_dump.txt
  kill "$BKV"
  wait "$BKV" 2>/dev/null || true
  printf '*3\r\n$3\r\nSET\r\n$4\r\nlost\r\n$5\r\nhel' >> "$cut"
  ./build/bendkv "$PORT" $k send "$base" always > build/server.log 2>&1 &
  BKV=$!
  sleep 0.5
  python3 tests/aof_test.py --port "$PORT" --check build/aof_dump.txt
  kill "$BKV"
  wait "$BKV" 2>/dev/null || true
  grep -q "bytes of an entry cut short" build/server.log
  test "$(wc -c < "$cut")" -eq "$size"
  echo "OK: a cut entry is cut back, $cut is $size bytes again"
  if command -v redis-check-aof > /dev/null; then
    redis-check-aof "$cut" | tail -1
  fi
}
echo "== append-only file"
restart 1 build/test.aof build/test.aof
echo "== append-only files of $SHARDS shards"
restart "$SHARDS" build/shard.aof build/shard.aof.1
# another shard count on these files is refused, and leaves them be
for k in 1 $((SHARDS * 2)); do
  rc=0
  timeout 10 ./build/bendkv "$PORT" $k send build/shard.aof always > build/server.log 2>&1 || rc=$?
  if [ "$rc" -ne 1 ]; then
    echo "FAIL: $k shards on the files of $SHARDS: exit $rc"
    exit 1
  fi
  echo "OK: refused with $k shards: $(tail -1 build/server.log)"
done
echo "== append-only file failures"
${CC:-cc} -shared -fPIC -o build/fail_io.so tests/fail_io.c -ldl
python3 tests/aof_fail_test.py --port "$PORT" --shim build/fail_io.so
