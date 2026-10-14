#!/bin/sh
# colls.sh NAME PORT SERVER: instructions per command of reads and writes
# of large collections, under callgrind. SERVER (a server taking --port
# PORT) is loaded with a list l, a hash h, a set s and a sorted set z of
# 100000 members each (e0.., f0.. with values v, m0.., m0.. of scores
# 0..), and a string key k; then each command runs N times from one
# client, one request at a time, the counters zeroed before and dumped to
# NAME.cg.N after. A write of a new member takes a random one of 10^6
# (redis-benchmark's __rand_int__). Prints, per command: instructions.
NAME=$1; PORT=$2; SERVER=$3
rm -f "$NAME".cg*
valgrind --tool=callgrind --callgrind-out-file="$NAME.cg" "$SERVER" --port "$PORT" > "$NAME.log" 2>&1 &
VP=$!
for i in $(seq 1 120); do redis-cli -p "$PORT" ping > /dev/null 2>&1 && break; sleep 1; done
python3 -c '
import sys
out = sys.stdout.buffer
def cmd(*a):
    out.write(b"*%d\r\n" % len(a) + b"".join(b"$%d\r\n%s\r\n" % (len(x), x) for x in a))
for i in range(0, 100000, 100):
    js = range(i, i + 100)
    cmd(b"RPUSH", b"l", *[b"e%d" % j for j in js])
    cmd(b"HSET", b"h", *[x for j in js for x in (b"f%d" % j, b"v")])
    cmd(b"SADD", b"s", *[b"m%d" % j for j in js])
    cmd(b"ZADD", b"z", *[x for j in js for x in (b"%d" % j, b"m%d" % j)])
cmd(b"SET", b"k", b"v")
' | redis-cli -p "$PORT" --pipe > /dev/null 2>&1
run() {
  label=$1; n=$2; shift 2
  callgrind_control -z $VP > /dev/null
  redis-benchmark -p "$PORT" -n "$n" -c 1 -P 1 -r 1000000 -q "$@" > /dev/null 2>&1
  callgrind_control -d "$label.$n" $VP > /dev/null
}
run get 2000 GET k
run set 2000 SET k w
run llen 2000 LLEN l
run lindex 2000 LINDEX l 0
run lpush 2000 LPUSH l x
run lpop 2000 LPOP l
run hget 2000 HGET h f50000
run hset_old 2000 HSET h f50000 w
run hset_new 2000 HSET h g:__rand_int__ v
run hincrby 2000 HINCRBY h c 1
run sismember 2000 SISMEMBER s m50000
run sadd_new 2000 SADD s n:__rand_int__
run spop 2000 SPOP s
run zscore 2000 ZSCORE z m50000
run zadd_old 2000 ZADD z 1 m50000
run zincrby 2000 ZINCRBY z 1 m50000
echo "members: $(redis-cli -p "$PORT" llen l) $(redis-cli -p "$PORT" hlen h) $(redis-cli -p "$PORT" scard s) $(redis-cli -p "$PORT" zcard z)"
kill $VP; wait $VP 2>/dev/null
for f in $(ls "$NAME".cg.* | awk -F. '{print $NF, $0}' | sort -n | cut -d" " -f2-); do
  t=$(grep -m1 -oE 'dump [a-z_]+\.[0-9]+' "$f" | cut -d' ' -f2)
  callgrind_annotate --inclusive=no "$f" 2>/dev/null | grep 'PROGRAM TOTALS' | tr -d ',' |
    awk -v t="${t%.*}" -v n="${t#*.}" '{printf "%-10s %12.0f instructions per command\n", t, $1/n}'
done
