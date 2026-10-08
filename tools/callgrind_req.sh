#!/bin/sh
# callgrind_req.sh NAME PORT CMD...: instructions, cache misses and branch
# mispredictions per request of a server under redis-benchmark. CMD (a
# server taking PORT, or redis-server --port PORT ...) runs under callgrind
# with a 2 MiB last-level cache (the L2 of the test machine) and branch
# simulation. KEYS (100000) random keys are set first. Then for each test
# of TESTS ("get incr"), 3*KEYS requests run and the counters are zeroed
# (so INCR finds its counters and the caches are warm), and 20k requests
# are counted and dumped to NAME.cg.N, all from 20 clients (CLIENTS) at
# pipeline depth 16 (PIPE), with values of DATA bytes (3, redis-benchmark's
# default). Prints, per request: instructions,
# last-level data read misses, mispredicted indirect and conditional
# branches. valgrind 3.22 cannot decode some code built with -march
# (a register-to-register vmovq, for one).
NAME=$1; PORT=$2; shift 2
KEYS=${KEYS:-100000}; TESTS=${TESTS:-get incr}; PIPE=${PIPE:-16}; CLIENTS=${CLIENTS:-20}; DATA=${DATA:-3}
rm -f "$NAME".cg*
valgrind --tool=callgrind --cache-sim=yes --branch-sim=yes --LL=2097152,16,64 \
  --callgrind-out-file="$NAME.cg" "$@" > "$NAME.log" 2>&1 &
VP=$!
for i in $(seq 1 60); do redis-cli -p "$PORT" ping > /dev/null 2>&1 && break; sleep 1; done
redis-benchmark -p "$PORT" -t set -r "$KEYS" -n $((KEYS * 2)) -d "$DATA" -P "$PIPE" -c "$CLIENTS" -q > /dev/null 2>&1
for t in $TESTS; do
  redis-benchmark -p "$PORT" -t "$t" -r "$KEYS" -n $((KEYS * 3)) -d "$DATA" -P "$PIPE" -c "$CLIENTS" -q > /dev/null 2>&1
  callgrind_control -z $VP > /dev/null
  redis-benchmark -p "$PORT" -t "$t" -r "$KEYS" -n 20000 -d "$DATA" -P "$PIPE" -c "$CLIENTS" -q > /dev/null 2>&1
  callgrind_control -d "$t" $VP > /dev/null
done
kill $VP; wait $VP 2>/dev/null
for f in "$NAME".cg.*; do
  [ -f "$f" ] || continue
  t=$(grep -m1 -oE 'dump [a-z_]+' "$f" | cut -d' ' -f2)
  callgrind_annotate --inclusive=no --show=Ir,DLmr,Bim,Bcm "$f" 2>/dev/null | grep 'PROGRAM TOTALS' | tr -d ',' |
    awk -v t="$t" '{printf "%-6s Ir %5.0f  LL data misses %.2f  indirect mispredicts %.2f  conditional mispredicts %.2f\n", t, $1/20000, $3/20000, $5/20000, $7/20000}'
done
