#!/usr/bin/env python3
"""long_requests.py PORT LABEL: long requests timed on a server already
listening on PORT, each from its send to its reply's end, one client, the
server emptied (FLUSHALL) before each; each case twice, the better time
kept. A request longer than a read (64 KB) comes in many reads: one MSET
of 30,000, 100,000 and 300,000 keys sent at once; the last again in
pieces of 64 KB a millisecond apart; one SADD of 300,000 members; one
RPUSH of 64 values of 512 KB; and, beside them, the 300,000 keys set by as
many SETs in one pipeline (section 75 of PERFORMANCE.md)."""
import socket
import sys
import time

port, label = int(sys.argv[1]), sys.argv[2]


def bulk(x):
    return b"$%d\r\n%s\r\n" % (len(x), x)


def req(args):
    return b"*%d\r\n" % len(args) + b"".join(bulk(a) for a in args)


def ask(data):
    s = socket.create_connection(("127.0.0.1", port), timeout=120)
    s.sendall(data)
    s.recv(100)
    s.close()


# seconds from the first byte sent to the last reply's LF (each reply here
# is one line)
def timed(data, replies, piece=0):
    s = socket.create_connection(("127.0.0.1", port), timeout=300)
    t0 = time.time()
    if piece:
        for i in range(0, len(data), piece):
            s.sendall(data[i:i + piece])
            time.sleep(0.001)
    else:
        s.sendall(data)
    got = 0
    while got < replies:
        c = s.recv(1 << 20)
        if not c:
            break
        got += c.count(b"\n")
    s.close()
    return time.time() - t0


def mset(n):
    return b"*%d\r\n$4\r\nMSET\r\n" % (1 + 2 * n) + b"".join(bulk(b"key:%d" % i) + b"$1\r\nv\r\n" for i in range(n))


def sadd(n):
    return b"*%d\r\n$4\r\nSADD\r\n$1\r\ns\r\n" % (2 + n) + b"".join(bulk(b"m%d" % i) for i in range(n))


CASES = [
    ("MSET of 30,000 keys", mset(30000), 1, 0),
    ("MSET of 100,000 keys", mset(100000), 1, 0),
    ("MSET of 300,000 keys", mset(300000), 1, 0),
    ("the same, in pieces of 64 KB 1 ms apart", mset(300000), 1, 65536),
    ("SADD of 300,000 members", sadd(300000), 1, 0),
    ("RPUSH of 64 values of 512 KB", req([b"RPUSH", b"l"] + [b"%07d" % i * 74898 for i in range(64)]), 1, 0),
    ("300,000 SETs, pipelined", b"".join(req([b"SET", b"key:%d" % i, b"v"]) for i in range(300000)), 300000, 0),
]
for name, data, replies, piece in CASES:
    t = []
    for _ in range(2):
        ask(req([b"FLUSHALL"]))
        t.append(timed(data, replies, piece))
    print("%-8s %-42s %6.2f s" % (label, name, min(t)), flush=True)
