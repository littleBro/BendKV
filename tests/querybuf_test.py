#!/usr/bin/env python3
"""A client's query buffer against Redis 7.2.16: the bytes it holds and
the room left in it, as CLIENT LIST and CLIENT INFO show them (qbuf and
qbuf-free: server.bend, Query buffers), scenarios run on BendKV and on
Redis with clients of their own, side by side, and their transcripts
compared line by line: the pair of a client's line, its idle time left
aside.

A client watched (A) is seen by another (B): a new client's buffer (4
bytes of room, before it sends anything); a buffer read into once
(20,474), after a command, an inline one and a pipeline of 1,000 PINGs;
the client that asks, its own line in CLIENT INFO and CLIENT LIST, alone
and with a PING after it in the same write; the buffers big arguments
leave, of SET with values of 400,000, 40,000 (read whole with its line),
70,000 and 100,000 bytes (with EX after the value): sized to the
argument, then taken back two of the cron's looks later (hz 10: after
350 ms), and read into again by a PING; an argument's line of 1,000,000
bytes sent alone, then half the bytes, then the rest: the buffer sized to
it from the line on, holding the bytes as they come, then empty, then
taken back; and a buffer taken back once its client is idle 3 s. Last,
unit/querybuf's first test as Redis's suite runs it, with hz 100: a new
client's buffer of 16 KB to 32 KB after CLIENT SETNAME, none 3 s later.

    python3 tests/querybuf_test.py --bendkv 6380 --redis 6390
"""
import argparse
import re
import sys
import threading
import time

from blocking_test import Client, enc


def pair(b, name):
    """the (qbuf, qbuf-free) of the client named name in CLIENT LIST"""
    for line in b.cmd("CLIENT", "LIST").split("\n"):
        if " name=%s " % name in line:
            m = re.search(r" qbuf=(\d+) qbuf-free=(\d+) ", line)
            return (int(m.group(1)), int(m.group(2)))
    return None


def own(c, *cmd):
    m = re.search(r" qbuf=(\d+) qbuf-free=(\d+) ", c.cmd(*cmd))
    return (int(m.group(1)), int(m.group(2)))


def scenarios(port, log):
    b = Client(port, db=None)
    b.cmd("CLIENT", "SETNAME", "watcher")
    fresh = Client(port, db=None)
    lines = [l for l in b.cmd("CLIENT", "LIST").split("\n") if " name= " in l and "cmd=NULL" in l]
    log("new client", [re.search(r" qbuf=(\d+) qbuf-free=(\d+) ", l).groups() for l in lines])
    fresh.close()
    a = Client(port, db=None)
    log("after a command", a.cmd("CLIENT", "SETNAME", "A"), pair(b, "A"))
    log("own CLIENT INFO", own(b, "CLIENT", "INFO"))
    mine = [l for l in b.cmd("CLIENT", "LIST").split("\n") if " name=watcher " in l][0]
    log("own CLIENT LIST", re.search(r" qbuf=(\d+) qbuf-free=(\d+) ", mine).groups())
    b.raw(enc(("CLIENT", "INFO")) + enc(("PING",)))
    info = b.read()
    log("own CLIENT INFO before a PING", re.search(r" qbuf=(\d+) qbuf-free=(\d+) ", info).groups(), b.read())
    a.raw(b"PING\r\n")
    log("inline", a.read(), pair(b, "A"))
    a.raw(enc(("PING",)) * 1000)
    log("1000 PINGs", [a.read() for _ in range(1000)].count("+PONG"), pair(b, "A"))
    for n, extra in ((400000, ()), (40000, ()), (70000, ()), (100000, ("EX", "100"))):
        log("SET of %d" % n, a.cmd("SET", "k", "v" * n, *extra), pair(b, "A"))
        time.sleep(0.35)
        log("two looks later", pair(b, "A"))
        log("a PING after", a.cmd("PING"), pair(b, "A"))
    a.raw(b"*3\r\n$3\r\nset\r\n$1\r\na\r\n$1000000\r\n")
    time.sleep(0.05)
    log("the line of an argument of 1000000", pair(b, "A"))
    a.raw(b"y" * 500000)
    time.sleep(0.05)
    log("half of it", pair(b, "A"))
    a.raw(b"y" * 500000 + b"\r\n")
    log("all of it", a.read(), pair(b, "A"))
    time.sleep(0.35)
    log("two looks later", pair(b, "A"))
    log("a PING", a.cmd("PING"), pair(b, "A"))
    time.sleep(3.3)
    log("idle 3 s", pair(b, "A"))
    log("a PING after", a.cmd("PING"), pair(b, "A"))
    a.close()
    # unit/querybuf: "query buffer resized correctly"
    log("hz 100", b.cmd("CONFIG", "SET", "hz", "100"))
    t = Client(port, db=None)
    t.cmd("CLIENT", "SETNAME", "test_client")
    q, f = pair(b, "test_client")
    log("a new client's buffer, 16 KB to 32 KB", 16384 <= q + f < 32768)
    end = time.time() + 10
    while time.time() < end and sum(pair(b, "test_client")) != 0:
        time.sleep(0.1)
    log("none once idle", pair(b, "test_client"))
    t.close()
    log("hz 10", b.cmd("CONFIG", "SET", "hz", "10"))
    b.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bendkv", type=int, required=True)
    ap.add_argument("--redis", type=int, required=True)
    args = ap.parse_args()
    outs = [[], []]

    def run(i, port):
        try:
            scenarios(port, lambda *x: outs[i].append(" ".join(repr(v) for v in x)))
        except Exception as e:
            outs[i].append("EXCEPTION %r" % (e,))

    ts = [threading.Thread(target=run, args=(i, p)) for i, p in enumerate((args.bendkv, args.redis))]
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    bad = 0
    for i in range(max(len(outs[0]), len(outs[1]))):
        x = outs[0][i] if i < len(outs[0]) else "<none>"
        y = outs[1][i] if i < len(outs[1]) else "<none>"
        if x != y:
            bad += 1
            print("FAIL: BendKV %s\n      Redis  %s" % (x, y))
    if bad:
        print("FAIL: %d of %d lines of the query buffer's scenarios differ" % (bad, len(outs[1])))
        sys.exit(1)
    print("OK: %d lines of the query buffer's scenarios as Redis answers them" % len(outs[1]))


if __name__ == "__main__":
    main()
