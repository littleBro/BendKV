#!/usr/bin/env python3
"""Consistency under concurrent clients: what one thread of command
execution guarantees must hold however the clients' batches interleave
on their way to it.

  1. No lost update: clients INCR shared keys concurrently, pipelined; each
     key ends at the number of INCRs sent to it.
  2. A command on several keys is one step: writers MSET keys spread over
     the trie to one value each time; a reader's MGET of them always sees
     one value.
  3. Order across keys: a writer SETs x then y to the same counter, in
     one pipeline or one at a time; a reader that GETs y and then, in a
     later round trip, x never sees x behind y.

    python3 tests/concurrency_test.py --port 6380 [--seconds 3]
"""
import argparse
import socket
import threading
import time


def resp(*args):
    out = b"*%d\r\n" % len(args)
    for a in args:
        a = a if isinstance(a, bytes) else str(a).encode()
        out += b"$%d\r\n%s\r\n" % (len(a), a)
    return out


class Conn:
    def __init__(self, port):
        self.s = socket.create_connection(("127.0.0.1", port))
        self.s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.buf = b""

    def send(self, cmds):
        self.s.sendall(b"".join(resp(*c) for c in cmds))
        return [self.reply() for _ in cmds]

    def _fill(self):
        chunk = self.s.recv(1 << 16)
        if not chunk:
            raise EOFError("connection closed")
        self.buf += chunk

    def _line(self):
        while b"\r\n" not in self.buf:
            self._fill()
        line, self.buf = self.buf.split(b"\r\n", 1)
        return line

    def _exact(self, n):
        while len(self.buf) < n + 2:
            self._fill()
        data, self.buf = self.buf[:n], self.buf[n + 2:]
        return data

    def reply(self):
        line = self._line()
        kind, rest = line[:1], line[1:]
        if kind in (b"+", b"-"):
            return line.decode()
        if kind == b":":
            return int(rest)
        if kind == b"$":
            n = int(rest)
            return None if n < 0 else self._exact(n)
        if kind == b"*":
            return [self.reply() for _ in range(int(rest))]
        raise ValueError("bad reply %r" % line)


def spread_keys(prefix, n):
    return [("%s:%d" % (prefix, i)).encode() for i in range(n)]


def no_lost_update(port, clients, rounds, keys):
    c = Conn(port)
    c.send([("DEL", *keys)])

    def work(seed):
        cc = Conn(port)
        for r in range(rounds):
            cc.send([("INCR", keys[(seed + r + j) % len(keys)]) for j in range(10)])

    ts = [threading.Thread(target=work, args=(i,)) for i in range(clients)]
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    got = c.send([("MGET", *keys)])[0]
    total = sum(int(v) for v in got)
    want = clients * rounds * 10
    ok = total == want
    print("%s no lost update: %d INCRs from %d clients, keys sum to %d"
          % ("ok  " if ok else "FAIL", want, clients, total))
    return ok


def mset_is_one_step(port, seconds, keys):
    stop = time.time() + seconds
    bad = []
    seen = [0]

    def writer(w):
        c = Conn(port)
        v = 0
        while time.time() < stop:
            v += 1
            val = b"%d-%d" % (w, v)
            c.send([("MSET", *[x for k in keys for x in (k, val)])])

    def reader():
        c = Conn(port)
        while time.time() < stop:
            vals = c.send([("MGET", *keys)])[0]
            seen[0] += 1
            if len(set(vals)) != 1:
                bad.append(vals)

    Conn(port).send([("MSET", *[x for k in keys for x in (k, b"0-0")])])
    ts = [threading.Thread(target=writer, args=(w,)) for w in range(3)]
    ts += [threading.Thread(target=reader) for _ in range(3)]
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    ok = not bad
    print("%s MSET is one step: %d MGETs of %d keys during MSETs, %d torn"
          % ("ok  " if ok else "FAIL", seen[0], len(keys), len(bad)))
    if bad:
        print("     e.g. %r" % bad[0])
    return ok


def order_across_keys(port, seconds, x, y):
    stop = time.time() + seconds
    bad = []
    seen = [0]
    Conn(port).send([("SET", x, 0), ("SET", y, 0)])

    def writer():
        c = Conn(port)
        i = 0
        while time.time() < stop:
            i += 1
            if i % 2:
                c.send([("SET", x, i), ("SET", y, i)])
            else:
                c.send([("SET", x, i)])
                c.send([("SET", y, i)])

    def reader():
        c = Conn(port)
        while time.time() < stop:
            vy = int(c.send([("GET", y)])[0])
            vx = int(c.send([("GET", x)])[0])
            seen[0] += 1
            if vx < vy:
                bad.append((vx, vy))

    ts = [threading.Thread(target=writer)] + [threading.Thread(target=reader) for _ in range(3)]
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    ok = not bad
    print("%s order across keys: %d reads of y then x, %d saw x behind y"
          % ("ok  " if ok else "FAIL", seen[0], len(bad)))
    return ok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=6380)
    ap.add_argument("--seconds", type=float, default=3)
    o = ap.parse_args()
    keys = spread_keys("ck", 16)
    oks = [
        no_lost_update(o.port, 8, 300, keys),
        mset_is_one_step(o.port, o.seconds, keys),
        order_across_keys(o.port, o.seconds, b"cx", b"cy"),
    ]
    print("ALL OK" if all(oks) else "SOME FAILED")
    raise SystemExit(0 if all(oks) else 1)


if __name__ == "__main__":
    main()
