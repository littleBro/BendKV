#!/bin/sh
# First the float library (src/float.bend) against glibc, on random texts
# of numbers (tests/float_test.py). Then the start: the command line and
# the configuration file, each
# case on BendKV and on redis-server (tests/start_test.py). Then
# connections that end every way one can, many times, on a BendKV of
# their own, posting and sending, each closing the channel it opened
# (tests/conn_test.py). Then starts a reference Redis (on the loopback,
# as BendKV listens) and BendKV on spare ports: BendKV with its
# defaults, then posting its replies to its
# writer thread (post),
# then sending them from its loop (send), then with an append-only file,
# and runs against each the robustness checks, a client that stops
# reading (its replies must hold up no one else's, nor the loop), clients
# that wait in blocking commands (scenarios against Redis, and checks
# under load), transactions (scenarios against Redis, and checks under
# load), Pub/Sub and keyspace notifications (scenarios against Redis, and
# checks under load), CLIENT LIST, INFO and KILL (scenarios against Redis,
# and checks under load), MONITOR (scenarios against Redis, and a check
# under load), CLIENT PAUSE and UNPAUSE (scenarios against Redis, and
# checks of BendKV alone and under load), the administrative commands
# (LASTSAVE, ROLE, WAIT, MEMORY, LOLWUT and SHUTDOWN: scenarios against
# Redis, and, with the defaults, SHUTDOWN on servers of their own), AUTH
# (scenarios against Redis:
# when a client must authenticate, and what it is answered before), the
# differential test
# against Redis (a fresh
# Redis database for each run)
# and the consistency checks under concurrent clients, against the first
# and against send (which sends a protocol error's reply from its loop,
# where post hands it to the writer) the protocol's edge cases, and
# against the first the commands of a connection and CONFIG, byte
# for byte against Redis, INFO's sections and fields, its statistics per
# command, the timing of calls (SLOWLOG, LATENCY, latencystats), COMMAND,
# SCAN and RANDOMKEY, keys that expire, numbers at
# their edges in every argument that is one, BITFIELD's fields at
# random, hashes, lists, sets and sorted sets, SORT and SORT_RO,
# HyperLogLogs and GEO (each in RESP2 and RESP3), DUMP and RESTORE, and
# RESP3 (its
# scenarios, and the differential tests again in RESP3); then stops
# them. Then the append-only file: a
# random stream, a restart from the file, the keyspace compared; then
# the file's last entry cut short, as a crash in a write leaves it, a
# restart that cuts it back, and the keyspace compared again. Then 20
# rounds of the server killed (SIGKILL) at a random moment while clients
# write to it, then started again: each start must hold the databases
# after a prefix of the commands sent, every acknowledged one among them
# (tests/crash_test.py). Then the
# disk failing under the file (tests/fail_io.c injects it): a file that
# is there but cannot be read must stop the start, and a failed fsync
# must stop the server, with everysec as with always. Last, the files
# both ways: the same commands against BendKV and a redis-server that
# keeps its own file, then BendKV started from Redis's file and Redis
# from BendKV's, each holding the databases the other held. And the
# rewrite of the file (BGREWRITEAOF): its replies and INFO's account
# against Redis's, the rewritten file against Redis's base, command for
# command, writes while it runs (and a kill while it runs), BendKV and
# Redis started from the new file, the rewrite with appendonly no, the
# cron's rewrites as the file grows, and rewrites that fail. Then
# maxmemory and eviction: the refusals past maxmemory (OOM), OBJECT
# IDLETIME and FREQ and the evicted event against Redis's, Redis's own
# tests of the policies on both, and BendKV's warnings, an eviction that
# goes on alone, one with the append-only file on and one while a rewrite
# runs.
set -e
cd "$(dirname "$0")/.."
PORT=${PORT:-6380}
REDIS_PORT=${REDIS_PORT:-6390}
ROUNDS=${ROUNDS:-1000}
# The differential tests (tests/diff_test.py) run DIFF_ROUNDS (ROUNDS)
# rounds from seeds SEED, SEED+1 and SEED+2 against each server, and from
# SEED+3 in RESP3. SEED is 1 by default (seeds 1 to 4, as always); in CI
# it is 4 * GITHUB_RUN_ID + 1, so that each run sends commands no run sent
# before (a job run again sends the same ones). SEED=N, with the same
# DIFF_ROUNDS, sends them again.
SEED=${SEED:-$((4 * ${GITHUB_RUN_ID:-0} + 1))}
DIFF_ROUNDS=${DIFF_ROUNDS:-$ROUNDS}
echo "== seeds $SEED to $((SEED + 3)), $DIFF_ROUNDS rounds: SEED=$SEED DIFF_ROUNDS=$DIFF_ROUNDS make test repeats them"
echo "== the float library against glibc"
python3 tests/float_test.py --bend "${BEND:-bend}" --cc "${CC:-cc}" --seed 1 --n 1500
echo "== the start"
python3 tests/start_test.py --bin build/bendkv
echo "== connections that end"
python3 tests/conn_test.py --bin build/bendkv --port "$PORT"
# up PID PORT: waits until the server started as PID answers on PORT (its
# INFO names PID), so that no test starts before it listens, nor runs
# against another server that holds the port; fails when PID exits first
# or has not answered in 30 seconds
up() {
  i=0
  until redis-cli -p "$2" info server 2> /dev/null | tr -d '\r' | grep -qx "process_id:$1"; do
    if ! kill -0 "$1" 2> /dev/null; then
      echo "the server on port $2 (pid $1) exited before it answered" >&2
      return 1
    fi
    i=$((i + 1))
    if [ "$i" -ge 300 ]; then
      echo "the server on port $2 (pid $1) has not answered in 30 seconds" >&2
      return 1
    fi
    sleep 0.1
  done
}
# Redis collates SORT's ALPHA by the locale it starts in (strcoll),
# BendKV as the C locale does
LC_ALL=C redis-server --port "$REDIS_PORT" --save '' --appendonly no --bind 127.0.0.1 > build/redis.log 2>&1 &
RDS=$!
BKV=
trap 'kill $BKV $RDS 2>/dev/null || true' EXIT
up "$RDS" "$REDIS_PORT"
rm -f build/test.aof build/aof_dump.txt
for n in "" post send "post build/test.aof everysec"; do
  ./build/bendkv "$PORT" $n > build/server.log 2>&1 &
  BKV=$!
  up "$BKV" "$PORT"
  echo "== ${n:-defaults}"
  python3 tests/robust_test.py --port "$PORT"
  python3 tests/writer_test.py --port "$PORT"
  python3 tests/blocking_test.py --bendkv "$PORT" --redis "$REDIS_PORT"
  python3 tests/multi_test.py --bendkv "$PORT" --redis "$REDIS_PORT"
  python3 tests/pubsub_test.py --bendkv "$PORT" --redis "$REDIS_PORT"
  python3 tests/client_test.py --bendkv "$PORT" --redis "$REDIS_PORT"
  python3 tests/monitor_test.py --bendkv "$PORT" --redis "$REDIS_PORT"
  python3 tests/pause_test.py --bendkv "$PORT" --redis "$REDIS_PORT"
  if [ -z "$n" ]; then
    python3 tests/admin_test.py --bendkv "$PORT" --redis "$REDIS_PORT" --bin build/bendkv
  else
    python3 tests/admin_test.py --bendkv "$PORT" --redis "$REDIS_PORT"
  fi
  python3 tests/auth_test.py --bendkv "$PORT" --redis "$REDIS_PORT"
  if [ -z "$n" ]; then
    python3 tests/protocol_test.py --bendkv "$PORT" --redis "$REDIS_PORT"
    python3 tests/session_test.py --bendkv "$PORT" --redis "$REDIS_PORT"
    python3 tests/config_test.py --bendkv "$PORT" --redis "$REDIS_PORT" --rounds "$ROUNDS"
    python3 tests/info_test.py --bendkv "$PORT" --redis "$REDIS_PORT"
    python3 tests/stats_test.py --bendkv "$PORT" --redis "$REDIS_PORT"
    python3 tests/timing_test.py --bendkv "$PORT" --redis "$REDIS_PORT"
    python3 tests/command_test.py --bendkv "$PORT" --redis "$REDIS_PORT"
    python3 tests/keyspace_test.py --bendkv "$PORT" --redis "$REDIS_PORT"
    python3 tests/ttl_test.py --bendkv "$PORT" --redis "$REDIS_PORT"
    python3 tests/numbers_test.py --bendkv "$PORT" --redis "$REDIS_PORT"
    python3 tests/bitfield_test.py --bendkv "$PORT" --redis "$REDIS_PORT"
    python3 tests/hash_test.py --bendkv "$PORT" --redis "$REDIS_PORT"
    python3 tests/list_test.py --bendkv "$PORT" --redis "$REDIS_PORT"
    python3 tests/set_test.py --bendkv "$PORT" --redis "$REDIS_PORT"
    python3 tests/zset_test.py --bendkv "$PORT" --redis "$REDIS_PORT"
    python3 tests/sort_test.py --bendkv "$PORT" --redis "$REDIS_PORT"
    # each case in RESP2, then again in RESP3
    python3 tests/hll_test.py --bendkv "$PORT" --redis "$REDIS_PORT"
    python3 tests/geo_test.py --bendkv "$PORT" --redis "$REDIS_PORT"
    python3 tests/dump_test.py --bendkv "$PORT" --redis "$REDIS_PORT"
    # RESP3: its scenarios, then the differential tests again with each
    # connection in RESP3 (HELLO 3)
    python3 tests/resp3_test.py --bendkv "$PORT" --redis "$REDIS_PORT"
    for t in ttl numbers bitfield hash list set zset sort; do
      RESP=3 python3 "tests/${t}_test.py" --bendkv "$PORT" --redis "$REDIS_PORT"
    done
  fi
  if [ "$n" = send ]; then
    python3 tests/protocol_test.py --bendkv "$PORT" --redis "$REDIS_PORT"
  fi
  for seed in "$SEED" $((SEED + 1)) $((SEED + 2)); do
    redis-cli -p "$REDIS_PORT" flushall > /dev/null
    redis-cli -p "$PORT" flushall > /dev/null
    python3 tests/diff_test.py --bendkv "$PORT" --redis "$REDIS_PORT" --rounds "$DIFF_ROUNDS" --seed "$seed"
  done
  if [ -z "$n" ]; then
    redis-cli -p "$REDIS_PORT" flushall > /dev/null
    redis-cli -p "$PORT" flushall > /dev/null
    RESP=3 python3 tests/diff_test.py --bendkv "$PORT" --redis "$REDIS_PORT" --rounds "$DIFF_ROUNDS" --seed $((SEED + 3))
  fi
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
  up "$BKV" "$PORT"
  python3 tests/aof_test.py --port "$PORT" --rounds "$ROUNDS" --write build/aof_dump.txt
  kill "$BKV"
  wait "$BKV" 2>/dev/null || true
  size=$(wc -c < "$f")
  ./build/bendkv "$PORT" send "$f" always > build/server.log 2>&1 &
  BKV=$!
  up "$BKV" "$PORT"
  python3 tests/aof_test.py --port "$PORT" --check build/aof_dump.txt
  kill "$BKV"
  wait "$BKV" 2>/dev/null || true
  printf '*3\r\n$3\r\nSET\r\n$4\r\nlost\r\n$5\r\nhel' >> "$f"
  ./build/bendkv "$PORT" send "$f" always > build/server.log 2>&1 &
  BKV=$!
  up "$BKV" "$PORT"
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
python3 tests/crash_test.py --bin build/bendkv --port "$PORT" --dir build/crash --rounds 20
echo "== append-only file failures"
${CC:-cc} -shared -fPIC -o build/fail_io.so tests/fail_io.c -ldl
python3 tests/aof_fail_test.py --port "$PORT" --shim build/fail_io.so
echo "== append-only files of Redis and of BendKV"
python3 tests/aof_redis_test.py --bin build/bendkv --bendkv "$PORT" --redis "$((REDIS_PORT + 1))" --dir build/aofio
echo "== the rewrite of the append-only file"
python3 tests/rewrite_test.py --bin build/bendkv --bendkv "$PORT" --redis "$((REDIS_PORT + 1))" --dir build/rewrite
echo "== maxmemory and eviction"
python3 tests/maxmemory_test.py --bin build/bendkv --bendkv "$PORT" --redis "$((REDIS_PORT + 1))" --dir build/maxmemory
