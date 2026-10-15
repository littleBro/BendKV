#!/bin/sh
# restore_mem.sh [SERVER]: resident memory before and after a restart from
# the append-only file. SERVER (build/bendkv) takes KEYS (1000000) SETs of
# 100-byte values on random keys (redis-benchmark -r), with the automatic
# rewrite off, and is started again from its file. Prints VmHWM and VmRSS
# after the load and after the restart, used_memory, the file's size and the
# time to the first PONG; fails when RSS after the restart is more than
# RATIO (1.3) times RSS before it. PCT=100 (Redis's default for
# auto-aof-rewrite-percentage) keeps the automatic rewrite on, so that the
# load's VmHWM shows what a rewrite during the load holds at its peak (the
# counts wait for the rewrite to end).
SERVER=${1:-build/bendkv}
KEYS=${KEYS:-1000000}; RATIO=${RATIO:-1.3}; PORT=${PORT:-6654}; PCT=${PCT:-0}
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
start() {
  "$SERVER" --port "$PORT" --dir "$D" --appendonly yes --appendfilename b.aof \
    --auto-aof-rewrite-percentage "$PCT" > "$D/$1.log" 2>&1 &
  pid=$!
  for i in $(seq 1 600); do redis-cli -p "$PORT" ping 2> /dev/null | grep -q PONG && return 0; sleep 0.1; done
  return 1
}
rss() { awk '/VmRSS/ {print $2}' "/proc/$1/status"; }
hwm() { awk '/VmHWM/ {print $2}' "/proc/$1/status"; }
used() { redis-cli -p "$PORT" info memory | tr -d '\r' | awk -F: '/^used_memory:/ {print $2}'; }
start load
redis-benchmark -p "$PORT" -t set -r "$KEYS" -n "$KEYS" -c 20 -P 64 -d 100 -q > /dev/null 2>&1
# a rewrite the load started (PCT) ends before the counts, in 60 s at most
for i in $(seq 1 600); do
  redis-cli -p "$PORT" info persistence | tr -d '\r' |
    grep -qE '^aof_rewrite_(in_progress|scheduled):1' || break
  sleep 0.1
done
sleep 1.5
r0=$(rss $pid)
echo "after the load:    VmRSS $r0 kB, VmHWM $(hwm $pid) kB, used_memory $(used), file $(wc -c < "$D/b.aof") bytes"
kill $pid; wait $pid 2> /dev/null
t0=$(date +%s%N)
start restart
t1=$(date +%s%N)
sleep 3
r1=$(rss $pid)
echo "after the restart: VmRSS $r1 kB, VmHWM $(hwm $pid) kB, used_memory $(used), $(( (t1 - t0) / 1000000 )) ms to PONG"
kill $pid; wait $pid 2> /dev/null
awk -v a="$r0" -v b="$r1" -v r="$RATIO" 'BEGIN {
  printf "RSS after the restart / before: %.2f (at most %s)\n", b / a, r
  exit (b > a * r) }'
