#!/bin/sh
# script_cost.sh NAME PORT CMD...: instructions per request of scripts
# under callgrind (section 68 of PERFORMANCE.md). CMD (a server taking
# PORT, or redis-server --port PORT ...) runs under callgrind; KEYS
# (100000) random keys are set first. Then for each test, 30000 requests
# run, the counters are zeroed, and 20000 requests are counted and dumped
# to NAME.cg.N, from 20 clients (CLIENTS) at pipeline depth 16 (PIPE):
#   eval1     EVAL "return 1" 0
#   evalsha1  EVALSHA of it
#   evalget   EVAL of a script that calls GET on a random key
#   evalset   EVAL of a script that calls SET on a random key
#   get       GET of a random key, for scale
# Prints NAME, the test and its instructions per request.
NAME=$1; PORT=$2; shift 2
KEYS=${KEYS:-100000}; PIPE=${PIPE:-16}; CLIENTS=${CLIENTS:-20}
rm -f "$NAME".cg*
valgrind --tool=callgrind --callgrind-out-file="$NAME.cg" "$@" > "$NAME.log" 2>&1 &
VP=$!
for i in $(seq 1 60); do redis-cli -p "$PORT" ping > /dev/null 2>&1 && break; sleep 1; done
redis-benchmark -p "$PORT" -t set -r "$KEYS" -n $((KEYS * 2)) -P 16 -c "$CLIENTS" -q > /dev/null 2>&1
SHA=$(redis-cli -p "$PORT" script load "return 1")
run() {
  t=$1; shift
  redis-benchmark -p "$PORT" -r "$KEYS" -n 30000 -P "$PIPE" -c "$CLIENTS" -q "$@" > /dev/null 2>&1
  callgrind_control -z $VP > /dev/null
  redis-benchmark -p "$PORT" -r "$KEYS" -n 20000 -P "$PIPE" -c "$CLIENTS" -q "$@" > /dev/null 2>&1
  callgrind_control -d "$t" $VP > /dev/null
}
run eval1 eval "return 1" 0
run evalsha1 evalsha "$SHA" 0
run evalget eval "return redis.call('get', KEYS[1])" 1 key:__rand_int__
run evalset eval "return redis.call('set', KEYS[1], ARGV[1])" 1 key:__rand_int__ xyz
run get get key:__rand_int__
kill $VP; wait $VP 2> /dev/null
for f in "$NAME".cg.*; do
  [ -f "$f" ] || continue
  t=$(grep -m1 -oE 'dump [a-z_0-9]+' "$f" | cut -d' ' -f2)
  callgrind_annotate --inclusive=no --show=Ir "$f" 2> /dev/null | grep 'PROGRAM TOTALS' | tr -d ',' |
    awk -v n="$NAME" -v t="$t" '{printf "%s %-9s %7.0f instructions per request\n", n, t, $1/20000}'
done
