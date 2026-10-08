#!/bin/sh
# bench_pairs.sh KEYS TRIALS N TESTS VARIANT...: paired throughput runs.
# Each trial starts every VARIANT in turn as a fresh process (the server
# pinned to CPU 3, the client to CPU 1), sets KEYS random keys, then runs
# each test of TESTS (say "get set incr") as N requests over KEYS random
# keys from 20 clients at pipeline depth 16. A VARIANT is "redis" or a
# server binary that takes its port as its argument; a bare name is
# looked up in $SRV (./build). The environment can change the shape:
# PIPE (16) and CLIENTS (20) for the timed runs, SCPU (3) and CCPU (1)
# for the CPUs of the server and of redis-benchmark, SARGS for arguments
# after the port of every server that is not Redis. Each output line reads
#   NAME tTRIAL rps/user_ns+sys_ns ...
# one cell per test: throughput, and the server's CPU time per request in
# user mode and in the kernel. Compare variants within a trial
# (tools/pair_ratios.py): between trials, and more so between VMs, the
# machine drifts by more than most effects worth measuring.
KEYS=$1; TRIALS=$2; N=$3; TESTS=$4; shift 4
SRV=${SRV:-./build}; PORT=${PORT:-6651}
PIPE=${PIPE:-16}; CLIENTS=${CLIENTS:-20}; SCPU=${SCPU:-3}; CCPU=${CCPU:-1}
TCK=$(getconf CLK_TCK)
# field 14 of /proc/PID/stat is user time, 15 kernel time, in ticks
ticks() { awk -v f="$2" '{print $f}' "/proc/$1/stat"; }
per_req() { echo "($2 - $1) * 1000000000 / $TCK / $N" | bc -l; }
echo "keys $KEYS n $N: variant trial $TESTS (rps/user_ns+sys_ns)"
for trial in $(seq 1 "$TRIALS"); do
  for v in "$@"; do
    if [ "$v" = redis ]; then
      taskset -c "$SCPU" redis-server --port "$PORT" --save '' --appendonly no > /dev/null 2>&1 &
    else
      case $v in */*) bin=$v ;; *) bin=$SRV/$v ;; esac
      taskset -c "$SCPU" "$bin" "$PORT" $SARGS > /dev/null 2>&1 &
    fi
    PID=$!
    for i in $(seq 1 50); do redis-cli -p "$PORT" ping > /dev/null 2>&1 && break; sleep 0.1; done
    taskset -c "$CCPU" redis-benchmark -p "$PORT" -t set -r "$KEYS" -n $((KEYS * 3)) -c 20 -P 64 -q > /dev/null 2>&1
    out="$(basename "$v") t$trial"
    for t in $TESTS; do
      u0=$(ticks $PID 14); s0=$(ticks $PID 15)
      x=$(taskset -c "$CCPU" redis-benchmark -p "$PORT" -t "$t" -r "$KEYS" -n "$N" -c "$CLIENTS" -P "$PIPE" --csv 2>/dev/null | tail -1 | cut -d, -f2 | tr -d '"')
      u1=$(ticks $PID 14); s1=$(ticks $PID 15)
      out="$out $(printf "%8.0f/%4.0f+%3.0f" "$x" "$(per_req "$u0" "$u1")" "$(per_req "$s0" "$s1")")"
    done
    echo "$out"
    kill $PID; wait $PID 2>/dev/null; sleep 0.3
  done
done
