#!/usr/bin/env python3
"""Holds N idle connections to a server until killed, for
tools/waiters_bench.sh: in mode blpop each waits in BLPOP on a key of its
own (a worker of a job queue), in mode watch each has sent WATCH on a key
of its own and nothing since. Prints READY once all are in place.

    python3 tools/idle_clients.py PORT blpop|watch N
"""
import socket
import sys
import time


def resp(*args):
    out = b"*%d\r\n" % len(args)
    for a in args:
        a = a if isinstance(a, bytes) else str(a).encode()
        out += b"$%d\r\n%s\r\n" % (len(a), a)
    return out


def main():
    port, mode, n = int(sys.argv[1]), sys.argv[2], int(sys.argv[3])
    socks = []
    for i in range(n):
        s = socket.create_connection(("127.0.0.1", port))
        if mode == "blpop":
            s.sendall(resp("BLPOP", "idle:q:%d" % i, "0"))
        else:
            s.sendall(resp("WATCH", "idle:w:%d" % i))
            s.settimeout(5)
            s.recv(64)
        socks.append(s)
    time.sleep(0.5)
    print("READY", flush=True)
    while True:
        time.sleep(3600)


if __name__ == "__main__":
    main()
