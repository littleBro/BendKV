#!/bin/sh
# redis-benchmark against BendKV and a reference Redis, same settings:
# 20 clients, 100k requests, without and with 16-deep pipelining.
set -e
cd "$(dirname "$0")/.."
PORT=${PORT:-6380}
REDIS_PORT=${REDIS_PORT:-6390}
./build/bendkv "$PORT" > build/server.log 2>&1 &
BKV=$!
redis-server --port "$REDIS_PORT" --save '' --appendonly no > build/redis.log 2>&1 &
RDS=$!
trap 'kill $BKV $RDS 2>/dev/null || true' EXIT
sleep 0.5
printf "%-24s %12s %12s\n" "test" "redis" "bendkv"
for t in "ping_mbulk|" "set|" "get|" "set|-r 100000" "get|-r 100000" "incr|-r 100000"; do
  for P in 1 16; do
    name=${t%%|*}
    r=${t#*|}
    line=""
    for p in "$REDIS_PORT" "$PORT"; do
      redis-cli -p "$p" flushall > /dev/null
      v=$(redis-benchmark -p "$p" -t "$name" $r -n 100000 -c 20 -P "$P" --csv 2>/dev/null | tail -1 | cut -d, -f2 | tr -d '"')
      line="$line $(printf "%12s" "$v")"
    done
    printf "%-24s%s\n" "$name $r P=$P" "$line"
  done
done
