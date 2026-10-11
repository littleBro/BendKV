#!/bin/sh
# First the start: the command line and the configuration file, each
# case on BendKV and on redis-server (tests/start_test.py). Then starts a
# reference Redis (with one database, as BendKV has, and on the
# loopback, as BendKV listens) and BendKV
# on spare ports: BendKV with its defaults, then posting its replies to
# its writer thread (post), then sending them from its loop (send), then
# with an append-only file, and runs against each the robustness checks,
# the differential test against Redis (a fresh Redis database for each
# run) and the consistency checks under concurrent clients, and against
# the first the protocol's edge cases, the commands of a connection and
# CONFIG, byte for byte against Redis, and INFO's sections and fields;
# then stops them. Then the append-only file: a
# random stream, a restart from the file, the keyspace compared; then the
# file's last entry cut short, as a crash in a write leaves it, a restart
# that cuts it back, and the keyspace compared again. Last, the disk
# failing under the file (tests/fail_io.c injects it): a file that is
# there but cannot be read must stop the start, and a failed fsync must
# stop the server, with everysec as with always.
set -e
cd "$(dirname "$0")/.."
PORT=${PORT:-6380}
REDIS_PORT=${REDIS_PORT:-6390}
ROUNDS=${ROUNDS:-1000}
echo "== the start"
python3 tests/start_test.py --bin build/bendkv
redis-server --port "$REDIS_PORT" --save '' --appendonly no --databases 1 --bind 127.0.0.1 > build/redis.log 2>&1 &
RDS=$!
BKV=
trap 'kill $BKV $RDS 2>/dev/null || true' EXIT
rm -f build/test.aof build/aof_dump.txt
for n in "" post send "post build/test.aof everysec"; do
  ./build/bendkv "$PORT" $n > build/server.log 2>&1 &
  BKV=$!
  sleep 0.5
  echo "== ${n:-defaults}"
  python3 tests/robust_test.py --port "$PORT"
  if [ -z "$n" ]; then
    python3 tests/protocol_test.py --bendkv "$PORT" --redis "$REDIS_PORT"
    python3 tests/session_test.py --bendkv "$PORT" --redis "$REDIS_PORT"
    python3 tests/config_test.py --bendkv "$PORT" --redis "$REDIS_PORT" --rounds "$ROUNDS"
    python3 tests/info_test.py --bendkv "$PORT" --redis "$REDIS_PORT"
  fi
  for seed in 1 2 3; do
    redis-cli -p "$REDIS_PORT" flushall > /dev/null
    redis-cli -p "$PORT" flushall > /dev/null
    python3 tests/diff_test.py --bendkv "$PORT" --redis "$REDIS_PORT" --rounds "$ROUNDS" --seed "$seed"
  done
  python3 tests/concurrency_test.py --port "$PORT"
  kill "$BKV"
  wait "$BKV" 2>/dev/null || true
done
# restart: a stream and keys, the server restarted from its file, the
# keyspace compared; then the file ends in an entry cut short, and the
# restart that cuts it back must give the same keyspace
restart() {
  f=$1
  rm -f "$f"
  ./build/bendkv "$PORT" send "$f" always > build/server.log 2>&1 &
  BKV=$!
  sleep 0.5
  python3 tests/aof_test.py --port "$PORT" --rounds "$ROUNDS" --write build/aof_dump.txt
  kill "$BKV"
  wait "$BKV" 2>/dev/null || true
  size=$(wc -c < "$f")
  ./build/bendkv "$PORT" send "$f" always > build/server.log 2>&1 &
  BKV=$!
  sleep 0.5
  python3 tests/aof_test.py --port "$PORT" --check build/aof_dump.txt
  kill "$BKV"
  wait "$BKV" 2>/dev/null || true
  printf '*3\r\n$3\r\nSET\r\n$4\r\nlost\r\n$5\r\nhel' >> "$f"
  ./build/bendkv "$PORT" send "$f" always > build/server.log 2>&1 &
  BKV=$!
  sleep 0.5
  python3 tests/aof_test.py --port "$PORT" --check build/aof_dump.txt
  kill "$BKV"
  wait "$BKV" 2>/dev/null || true
  grep -q "bytes of an entry cut short" build/server.log
  test "$(wc -c < "$f")" -eq "$size"
  echo "OK: a cut entry is cut back, $f is $size bytes again"
  if command -v redis-check-aof > /dev/null; then
    redis-check-aof "$f" | tail -1
  fi
}
echo "== append-only file"
restart build/test.aof
echo "== append-only file failures"
${CC:-cc} -shared -fPIC -o build/fail_io.so tests/fail_io.c -ldl
python3 tests/aof_fail_test.py --port "$PORT" --shim build/fail_io.so
