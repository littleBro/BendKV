#!/bin/sh
# stream_waits_cg.sh NAME PORT MODE CMD...: the server's instructions a
# round of tools/stream_waits.py, one consumer, under callgrind. CMD (a
# server taking PORT, or redis-server --port PORT ...) runs under
# callgrind; 50 rounds warm it, its counters are zeroed, 200 rounds are
# counted and dumped to NAME.cg.N. MODE is xread or group (the read waits
# before the XADD), xread-nb or group-nb (--noblock: sent after it), or
# info (200 INFO clients alone, the cost a round's INFO adds). Prints the
# instructions of the 200 rounds (section 88 of PERFORMANCE.md).
NAME=$1; PORT=$2; MODE=$3; shift 3
here=$(cd "$(dirname "$0")" && pwd)
rm -f "$NAME".cg*
valgrind --tool=callgrind --callgrind-out-file="$NAME.cg" "$@" > "$NAME.log" 2>&1 &
VP=$!
for i in $(seq 1 120); do redis-cli -p "$PORT" ping > /dev/null 2>&1 && break; sleep 0.5; done
case $MODE in
  xread) f= ;; group) f=--group ;; xread-nb) f=--noblock ;; group-nb) f="--group --noblock" ;; info) f=info ;;
  *) echo "MODE: xread, group, xread-nb, group-nb or info"; kill $VP; exit 1 ;;
esac
if [ "$f" = info ]; then
  info() {
    python3 - "$PORT" "$1" <<'PY'
import socket, sys
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])))
for _ in range(int(sys.argv[2])):
    s.sendall(b"*2\r\n$4\r\nINFO\r\n$7\r\nclients\r\n")
    hdr = b""
    while not hdr.endswith(b"\r\n"):
        hdr += s.recv(1)
    n, got = int(hdr[1:-2]), 0
    while got < n + 2:
        got += len(s.recv(n + 2 - got))
PY
  }
  info 50
  callgrind_control -z $VP > /dev/null
  info 200
else
  python3 "$here/stream_waits.py" "$PORT" 50 $f --warm 10 > /dev/null
  callgrind_control -z $VP > /dev/null
  python3 "$here/stream_waits.py" "$PORT" 200 $f --warm 0
fi
callgrind_control -d $VP > /dev/null
kill $VP; wait $VP 2>/dev/null
for d in "$NAME".cg.*; do
  [ -f "$d" ] || continue
  callgrind_annotate --inclusive=no "$d" 2>/dev/null | grep 'PROGRAM TOTALS' | tr -d ',' | awk -v m="$MODE" '{printf "%s: %d instructions\n", m, $1}'
done
