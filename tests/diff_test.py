#!/usr/bin/env python3
"""Differential test: random command streams against BendKV and a real
Redis, replies compared one by one. Commands are pipelined in random
batch sizes, and arguments are random bytes, so framing, binary safety
and command semantics are all exercised.

    python3 tests/diff_test.py --bendkv 6380 --redis 6390 --rounds 2000

Known, documented divergence that the generator avoids: BendKV's
integers have at most 14 digits (Redis allows int64).
"""
import argparse
import random
import socket
import sys


class Conn:
    def __init__(self, port):
        self.sock = socket.create_connection(("127.0.0.1", port))
        self.buf = b""

    def send(self, cmds):
        out = b""
        for args in cmds:
            out += b"*%d\r\n" % len(args)
            for a in args:
                out += b"$%d\r\n%s\r\n" % (len(a), a)
        self.sock.sendall(out)

    def _fill(self):
        data = self.sock.recv(1 << 16)
        if not data:
            raise EOFError("connection closed")
        self.buf += data

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
        if kind in (b"+", b"-", b":"):
            return (kind, rest)
        if kind == b"$":
            n = int(rest)
            return (kind, None if n < 0 else self._exact(n))
        if kind == b"*":
            n = int(rest)
            return (kind, None if n < 0 else [self.reply() for _ in range(n)])
        raise ValueError("bad reply line %r" % line)


KEYS = [b"k%d" % i for i in range(8)] + [b"", b"user:1", b"user:2", "ключ".encode(), b"\x00\xff\r\n"]


def rnd_value(r):
    c = r.random()
    if c < 0.35:
        return str(r.randint(-10**6, 10**6)).encode()
    if c < 0.45:
        return r.choice([b"0", b"-0", b"007", b"+5", b" 1", b"1 ", b"", b"99999999999998", b"-99999999999998"])
    if c < 0.7:
        return bytes(r.randrange(256) for _ in range(r.randint(0, 12)))
    return r.choice([b"a", b"bar", b"hello world", "мир".encode(), b"x" * r.randint(0, 300)])


def rnd_pattern(r):
    return r.choice([b"*", b"k*", b"k?", b"user:*", b"*1", b"?", b"", b"k[", b"*:*"])


def rnd_cmd(r):
    k = lambda: r.choice(KEYS)
    ks = lambda: [k() for _ in range(r.randint(1, 4))]
    c = r.random()
    table = [
        (0.14, lambda: [b"SET", k(), rnd_value(r)]),
        (0.14, lambda: [b"GET", k()]),
        (0.06, lambda: [b"DEL"] + ks()),
        (0.05, lambda: [b"EXISTS"] + ks()),
        (0.07, lambda: [b"INCR", k()]),
        (0.04, lambda: [b"DECR", k()]),
        (0.05, lambda: [b"INCRBY", k(), rnd_value(r)]),
        (0.03, lambda: [b"DECRBY", k(), rnd_value(r)]),
        (0.06, lambda: [b"APPEND", k(), rnd_value(r)]),
        (0.04, lambda: [b"STRLEN", k()]),
        (0.05, lambda: [b"MGET"] + ks()),
        (0.04, lambda: [b"MSET"] + sum(([k(), rnd_value(r)] for _ in range(r.randint(1, 3))), [])),
        (0.04, lambda: [b"SETNX", k(), rnd_value(r)]),
        (0.04, lambda: [b"GETSET", k(), rnd_value(r)]),
        (0.03, lambda: [b"DBSIZE"]),
        (0.03, lambda: [b"KEYS", rnd_pattern(r)]),
        (0.02, lambda: [b"PING"]),
        (0.02, lambda: [b"ECHO", rnd_value(r)]),
        (0.02, lambda: [r.choice([b"get", b"Get", b"sEt", b"incr"]), k()] + ([rnd_value(r)] if r.random() < 0.5 else [])),
        (0.02, lambda: [r.choice([b"GET", b"SET", b"INCR", b"STRLEN", b"GETSET"])] + [k() for _ in range(r.choice([0, 3]))]),
        (0.01, lambda: [b"FLUSHALL"]),
    ]
    acc = 0.0
    for p, f in table:
        acc += p
        if c < acc:
            return f()
    return [b"PING"]


def normalize(cmd, rep):
    # KEYS answers in an unspecified order
    if cmd[0].upper() == b"KEYS" and rep[0] == b"*":
        return (rep[0], sorted(rep[1]))
    return rep


def known_divergence(got, want):
    # BendKV refuses integers past 14 digits, where Redis goes on to int64
    if got == (b"-", b"ERR increment or decrement would overflow") and want[0] == b":":
        return len(want[1].lstrip(b"-")) >= 15
    # a stored value of 15+ digits is no integer to BendKV; Redis then
    # answers a 15+ digit sum, or its own int64 overflow
    if got == (b"-", b"ERR value is not an integer or out of range"):
        if want[0] == b":":
            return len(want[1].lstrip(b"-")) >= 15
        return want == (b"-", b"ERR increment or decrement would overflow")
    return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bendkv", type=int, default=6380)
    ap.add_argument("--redis", type=int, default=6390)
    ap.add_argument("--rounds", type=int, default=1000)
    ap.add_argument("--seed", type=int, default=1)
    a = ap.parse_args()
    r = random.Random(a.seed)
    b, s = Conn(a.bendkv), Conn(a.redis)
    for c in (b, s):
        c.send([[b"FLUSHALL"]])
        c.reply()
    total = 0
    known = 0
    for rnd in range(a.rounds):
        batch = [rnd_cmd(r) for _ in range(r.choice([1, 1, 2, 5, 20]))]
        b.send(batch)
        s.send(batch)
        diverged = False
        for cmd in batch:
            got, want = normalize(cmd, b.reply()), normalize(cmd, s.reply())
            if diverged:
                continue
            total += 1
            if got != want:
                if known_divergence(got, want):
                    # the states now differ on one key: compare no more of
                    # this batch, and start the next from empty databases
                    known += 1
                    diverged = True
                    continue
                print("MISMATCH after %d commands (round %d)" % (total, rnd))
                print("  command:", cmd)
                print("  bendkv: ", got)
                print("  redis:  ", want)
                sys.exit(1)
        if diverged:
            for c in (b, s):
                c.send([[b"FLUSHALL"]])
                c.reply()
    print("OK: %d commands in %d pipelined batches, all replies identical"
          " (%d known 64-bit integer divergences skipped)" % (total, a.rounds, known))


if __name__ == "__main__":
    main()
