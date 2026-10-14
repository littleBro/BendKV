#!/bin/sh
# hllcost.sh NAME PORT SERVER: instructions per command of the HyperLogLog
# commands, under callgrind, as colls.sh counts those of collections.
# SERVER (a server taking --port PORT, started in a directory NAME.dir of
# its own) is loaded with sparse HyperLogLogs sp and sp2 of 100 elements
# each, dense ones dn and dn2 of 10,000 each (their counts kept), and an
# empty sp3; then each command runs N times from one client, one request
# at a time, the counters zeroed before and dumped to NAME.cg.N after. A
# new element or key takes a random one of 10^6 (redis-benchmark's
# __rand_int__); setr_count makes dn's count stale (byte 15 set to 0x80)
# before each PFCOUNT, setrange counts that SETRANGE alone. Prints, per
# command: instructions.
NAME=$1; PORT=$2; SERVER=$3
rm -f "$NAME".cg*
rm -rf "./${NAME:?}.dir"; mkdir "$NAME.dir"
OUT=$(pwd)
(cd "$NAME.dir" && exec valgrind --tool=callgrind --callgrind-out-file="$OUT/$NAME.cg" "$SERVER" --port "$PORT") > "$NAME.log" 2>&1 &
VP=$!
for i in $(seq 1 120); do redis-cli -p "$PORT" ping > /dev/null 2>&1 && break; sleep 1; done
python3 -c '
import sys
out = sys.stdout.buffer
def cmd(*a):
    out.write(b"*%d\r\n" % len(a) + b"".join(b"$%d\r\n%s\r\n" % (len(x), x) for x in a))
cmd(b"PFADD", b"sp", *[b"e%d" % i for i in range(100)])
cmd(b"PFADD", b"sp2", *[b"f%d" % i for i in range(100)])
for i in range(0, 10000, 500):
    cmd(b"PFADD", b"dn", *[b"e%d" % j for j in range(i, i + 500)])
    cmd(b"PFADD", b"dn2", *[b"f%d" % j for j in range(i, i + 500)])
cmd(b"PFADD", b"sp3")
for k in (b"sp", b"sp2", b"dn", b"dn2"):
    cmd(b"PFCOUNT", k)
' | redis-cli -p "$PORT" --pipe > /dev/null 2>&1
echo "encodings: $(redis-cli -p "$PORT" pfdebug encoding sp) $(redis-cli -p "$PORT" pfdebug encoding dn) $(redis-cli -p "$PORT" pfcount dn)"
run() {
  label=$1; n=$2; shift 2
  callgrind_control -z $VP > /dev/null
  redis-benchmark -p "$PORT" -n "$n" -c 1 -P 1 -r 1000000 -q "$@" > /dev/null 2>&1
  callgrind_control -d "$label.$n" $VP > /dev/null
}
# a request at a time from a client of its own: dn's count made stale
# before each PFCOUNT, or the SETRANGE alone
stale() {
  label=$1; n=$2; count=$3
  callgrind_control -z $VP > /dev/null
  python3 -c '
import socket, sys
port, n, count = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3] == "1"
s = socket.create_connection(("127.0.0.1", port))
def cmd(*a):
    s.sendall(b"*%d\r\n" % len(a) + b"".join(b"$%d\r\n%s\r\n" % (len(x), x) for x in a))
    d = b""
    while not d.endswith(b"\r\n"):
        d += s.recv(4096)
for i in range(n):
    cmd(b"SETRANGE", b"dn", b"15", b"\x80")
    if count:
        cmd(b"PFCOUNT", b"dn")
' "$PORT" "$n" "$count"
  callgrind_control -d "$label.$n" $VP > /dev/null
}
run pfadd_sp_old 2000 PFADD sp e5
run pfadd_dn_old 2000 PFADD dn e5
run pfadd_sp_new 500 PFADD sp3 n:__rand_int__
run pfadd_dn_new 2000 PFADD dn n:__rand_int__
run pfadd_key 2000 PFADD k:__rand_int__ a
run pfcount_kept 2000 PFCOUNT dn
stale setrange 200 0
stale setr_count 200 1
run pfcount_sp2 500 PFCOUNT sp sp2
run pfcount_dn2 200 PFCOUNT dn dn2
run pfmerge_sp 500 PFMERGE m1 sp sp2
run pfmerge_dn 200 PFMERGE m2 dn dn2
echo "after: $(redis-cli -p "$PORT" pfdebug encoding sp3) $(redis-cli -p "$PORT" pfdebug encoding m1) $(redis-cli -p "$PORT" pfcount m1) $(redis-cli -p "$PORT" pfcount m2)"
kill $VP; wait $VP 2>/dev/null
for f in $(ls "$NAME".cg.* | awk -F. '{print $NF, $0}' | sort -n | cut -d" " -f2-); do
  t=$(grep -m1 -oE 'dump [a-z_0-9]+\.[0-9]+' "$f" | cut -d' ' -f2)
  callgrind_annotate --inclusive=no "$f" 2>/dev/null | grep 'PROGRAM TOTALS' | tr -d ',' |
    awk -v t="${t%.*}" -v n="${t#*.}" '{printf "%-13s %12.0f instructions per command\n", t, $1/n}'
done
