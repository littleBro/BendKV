#!/bin/sh
# memtier_hits.sh TRIALS CPUS PIPE SERVER...: GETs that all hit. The 1Mkeys
# GET specs of memtier_specs.py load 1M keys and then read from 10M, so 90%
# of their GETs miss; here each SERVER (a binary taking its port, or
# "redis") gets KEYS (1000000) keys with 100-byte values, then memtier reads
# random keys of the same range for 8 seconds: 2 threads of 50 connections
# at pipeline depth PIPE, on CPUs 0 and 1, the server pinned to CPUS.
# Servers take turns within each trial, each on a fresh process. The
# output reads as bench_pairs.sh's, for pair_ratios.py: per run, ops/s and
# the server's CPU time per GET in user mode and in the kernel (ns).
# MEMTIER names the memtier_benchmark binary.
TR=$1; CPUS=$2; PIPE=$3; shift 3
MT=${MEMTIER:-memtier_benchmark}; KEYS=${KEYS:-1000000}
PORT=${PORT:-6907}; TCK=$(getconf CLK_TCK)
ticks() { awk -v f="$2" '{print $f}' "/proc/$1/stat"; }
per_op() { echo "($2 - $1) * 1000000000 / $TCK / $3" | bc -l; }
echo "keys $KEYS pipeline $PIPE cpus $CPUS: variant trial get (rps/user_ns+sys_ns)"
for t in $(seq 1 "$TR"); do
  for b in "$@"; do
    if [ "$b" = redis ]; then
      taskset -c "$CPUS" redis-server --port "$PORT" --save '' --appendonly no > /dev/null 2>&1 &
    else
      taskset -c "$CPUS" "$b" "$PORT" > /dev/null 2>&1 &
    fi
    P=$!
    for i in $(seq 1 50); do redis-cli -p "$PORT" ping > /dev/null 2>&1 && break; sleep 0.1; done
    taskset -c 0,1 "$MT" -s 127.0.0.1 -p "$PORT" --key-minimum 1 --key-maximum "$KEYS" -n allkeys \
      --data-size 100 --ratio 1:0 --key-pattern P:P -c 50 -t 2 --pipeline 50 --hide-histogram > /dev/null 2>&1
    u0=$(ticks $P 14); s0=$(ticks $P 15)
    r=$(taskset -c 0,1 "$MT" -s 127.0.0.1 -p "$PORT" --key-minimum 1 --key-maximum "$KEYS" \
      --data-size 100 --ratio 0:1 --key-pattern R:R -c 50 -t 2 --pipeline "$PIPE" --test-time 8 \
      --hide-histogram 2>/dev/null | awk '/^Totals/ {print $2, $3}')
    u1=$(ticks $P 14); s1=$(ticks $P 15)
    ops=${r% *}; hits=${r#* }
    n=$(echo "$ops * 8" | bc -l)
    printf "%s t%s %8.0f/%4.0f+%3.0f  # hits %.0f/s\n" "$(basename "$b")" "$t" "$ops" \
      "$(per_op "$u0" "$u1" "$n")" "$(per_op "$s0" "$s1" "$n")" "$hits"
    kill $P; wait $P 2>/dev/null
  done
done
