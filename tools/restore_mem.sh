#!/bin/sh
# restore_mem.sh [SERVER]: resident memory before and after a restart from
# the append-only file. SERVER (build/bendkv) takes KEYS (1000000) SETs of
# 100-byte values on random keys (redis-benchmark -r), with the automatic
# rewrite off, and is started again from its files (appendonlydir, which
# the first start makes). Prints VmHWM and VmRSS after the load and after
# the restart, used_memory, the files' size and the
# time to the first PONG; fails when RSS after the restart is more than
# RATIO (1.3) times RSS before it. PCT=100 (Redis's default for
# auto-aof-rewrite-percentage) keeps the automatic rewrite on, so that the
# load's VmHWM shows what a rewrite during the load holds at its peak (the
# counts wait for the rewrite to end). It fails too when a start or the
# load fails, when a server is gone before its RSS is read, and when the
# restart does not hold the keys the load left: a guard that cannot read
# what it compares does not pass.
SERVER=${1:-build/bendkv}
KEYS=${KEYS:-1000000}; RATIO=${RATIO:-1.3}; PORT=${PORT:-6654}; PCT=${PCT:-0}
D=$(mktemp -d)
pid=
trap 'rm -rf "$D"' EXIT
fail() {
  echo "restore_mem.sh: $*" >&2
  [ -n "$pid" ] && kill "$pid" 2> /dev/null
  exit 1
}
command -v redis-benchmark > /dev/null || fail "redis-benchmark is not on the PATH"
start() {
  "$SERVER" --port "$PORT" --dir "$D" --appendonly yes --appendfilename b.aof \
    --auto-aof-rewrite-percentage "$PCT" > "$D/$1.log" 2>&1 &
  pid=$!
  for i in $(seq 1 600); do redis-cli -p "$PORT" ping 2> /dev/null | grep -q PONG && return 0; sleep 0.1; done
  return 1
}
rss() {
  kill -0 "$1" 2> /dev/null || fail "the server ($2) is gone; its log: $(tail -3 "$D/$2.log")"
  r=$(awk '/VmRSS/ {print $2}' "/proc/$1/status")
  [ -n "$r" ] || fail "no VmRSS for the server ($2)"
  echo "$r"
}
keys() { redis-cli -p "$PORT" dbsize; }
hwm() { awk '/VmHWM/ {print $2}' "/proc/$1/status"; }
used() { redis-cli -p "$PORT" info memory | tr -d '\r' | awk -F: '/^used_memory:/ {print $2}'; }
start load || fail "the server did not start; its log: $(tail -3 "$D/load.log")"
redis-benchmark -p "$PORT" -t set -r "$KEYS" -n "$KEYS" -c 20 -P 64 -d 100 -q > /dev/null 2>&1 ||
  fail "redis-benchmark failed"
# a rewrite the load started (PCT) ends before the counts, in 60 s at most
for i in $(seq 1 600); do
  redis-cli -p "$PORT" info persistence | tr -d '\r' |
    grep -qE '^aof_rewrite_(in_progress|scheduled):1' || break
  sleep 0.1
done
sleep 1.5
r0=$(rss $pid load) || exit 1
n0=$(keys)
[ "${n0:-0}" -gt 0 ] || fail "no keys after the load"
echo "after the load:    VmRSS $r0 kB, VmHWM $(hwm $pid) kB, used_memory $(used), $n0 keys, files $(cat "$D"/appendonlydir/b.aof.*.aof | wc -c) bytes"
kill $pid; wait $pid 2> /dev/null
pid=
t0=$(date +%s%N)
start restart || fail "the restart did not answer; its log: $(tail -3 "$D/restart.log")"
t1=$(date +%s%N)
sleep 3
r1=$(rss $pid restart) || exit 1
n1=$(keys)
[ "$n1" = "$n0" ] || fail "the restart holds $n1 keys, the load left $n0"
echo "after the restart: VmRSS $r1 kB, VmHWM $(hwm $pid) kB, used_memory $(used), $n1 keys, $(( (t1 - t0) / 1000000 )) ms to PONG"
kill $pid; wait $pid 2> /dev/null
pid=
awk -v a="$r0" -v b="$r1" -v r="$RATIO" 'BEGIN {
  printf "RSS after the restart / before: %.2f (at most %s)\n", b / a, r
  exit (b > a * r) }'
