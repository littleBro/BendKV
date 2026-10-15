#!/usr/bin/env python3
"""Holds N idle connections to a server until killed, for
tools/waiters_bench.sh: in mode blpop each waits in BLPOP on a key of its
own (a worker of a job queue), in mode watch each has sent WATCH on a key
of its own and nothing since; in mode track each tracks keys (CLIENT
TRACKING, in RESP3) and has read a key of its own, in mode bcast each
tracks in BCAST mode a prefix of its own, which no other key has, in mode
bcastkeys each tracks in BCAST mode the prefix of redis-benchmark's keys
("key:"), and reads the invalidations of every key written; in mode
events the first sets notify-keyspace-events to KEA and each subscribes
to a channel of its own, which no event names, so that every batch runs
a command at a time (the general way) and a write's events go to no one.
Prints READY once all are in place.

    python3 tools/idle_clients.py PORT blpop|watch|track|bcast|bcastkeys|events N
"""
import select
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
        elif mode == "watch":
            s.sendall(resp("WATCH", "idle:w:%d" % i))
            s.settimeout(5)
            s.recv(64)
        elif mode == "events":
            s.settimeout(5)
            if i == 0:
                s.sendall(resp("CONFIG", "SET", "notify-keyspace-events", "KEA"))
                s.recv(64)
            s.sendall(resp("SUBSCRIBE", "idle:e:%d" % i))
            s.recv(1 << 12)
        else:
            s.settimeout(5)
            s.sendall(resp("HELLO", "3"))
            time.sleep(0.05)
            s.recv(1 << 12)
            if mode == "track":
                s.sendall(resp("CLIENT", "TRACKING", "on") + resp("GET", "idle:t:%d" % i))
            elif mode == "bcast":
                s.sendall(resp("CLIENT", "TRACKING", "on", "BCAST", "PREFIX", "idle:b:%d:" % i))
            else:
                s.sendall(resp("CLIENT", "TRACKING", "on", "BCAST", "PREFIX", "key:"))
            time.sleep(0.05)
            s.recv(1 << 12)
        socks.append(s)
    time.sleep(0.5)
    print("READY", flush=True)
    while True:
        if mode == "bcastkeys":
            for s in select.select(socks, [], [], 3600)[0]:
                s.recv(1 << 16)
        else:
            time.sleep(3600)


if __name__ == "__main__":
    main()
