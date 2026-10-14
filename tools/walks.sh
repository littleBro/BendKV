#!/bin/sh
# walks.sh NAME PORT SERVER: instructions per command of the walks of the
# keyspace's trie (KEYS, SCAN, RANDOMKEY) and of a sorted set's tree
# (ZRANGE and ZREVRANGE, and ZRANK, ZSCORE, ZINCRBY and ZADD beside them),
# under callgrind. SERVER (a server taking --port PORT) is loaded with
# 10000 string keys (redis-benchmark's, so about 9,800 distinct) and a
# sorted set z of 100000 members (m0 to m99999, of scores 0 to 99999);
# then each command runs N times from one client, the counters zeroed
# before and dumped to NAME.cg.N after. Prints, per command: instructions.
NAME=$1; PORT=$2; SERVER=$3
rm -f "$NAME".cg*
valgrind --tool=callgrind --callgrind-out-file="$NAME.cg" "$SERVER" --port "$PORT" > "$NAME.log" 2>&1 &
VP=$!
for i in $(seq 1 120); do redis-cli -p "$PORT" ping > /dev/null 2>&1 && break; sleep 1; done
redis-benchmark -p "$PORT" -t set -r 10000 -n 40000 -P 16 -q > /dev/null 2>&1
python3 -c '
import sys
out = sys.stdout.buffer
for i in range(100000):
    a = [b"ZADD", b"z", str(i).encode(), b"m%d" % i]
    out.write(b"*4\r\n" + b"".join(b"$%d\r\n%s\r\n" % (len(x), x) for x in a))
' | redis-cli -p "$PORT" --pipe > /dev/null 2>&1
run() {
  label=$1; n=$2; shift 2
  callgrind_control -z $VP > /dev/null
  redis-benchmark -p "$PORT" -n "$n" -c 1 -P 1 -q "$@" > /dev/null 2>&1
  callgrind_control -d "$label.$n" $VP > /dev/null
}
run keys 10 KEYS '*'
run scan 200 SCAN 0 COUNT 1000
run randomkey 2000 RANDOMKEY
run zrange 2000 ZRANGE z 50000 50009 WITHSCORES
run zrevrange 2000 ZREVRANGE z 50000 50009
run zrangeall 5 ZRANGE z 0 -1
run zrank 2000 ZRANK z m50000
run zscore 2000 ZSCORE z m50000
run zincrby 2000 ZINCRBY z 0 m50000
run zadd 1000 ZADD z 1 m50000
echo "keys in the database: $(redis-cli -p "$PORT" dbsize)"
kill $VP; wait $VP 2>/dev/null
for f in "$NAME".cg.*; do
  [ -f "$f" ] || continue
  t=$(grep -m1 -oE 'dump [a-z_]+\.[0-9]+' "$f" | cut -d' ' -f2)
  callgrind_annotate --inclusive=no "$f" 2>/dev/null | grep 'PROGRAM TOTALS' | tr -d ',' |
    awk -v t="${t%.*}" -v n="${t#*.}" '{printf "%-10s %12.0f instructions per command\n", t, $1/n}'
done
