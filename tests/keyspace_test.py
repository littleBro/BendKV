#!/usr/bin/env python3
"""SCAN and RANDOMKEY, BendKV against Redis. Their replies are not the
same as Redis's (a cursor is BendKV's own, and so is the order of the
keys and RANDOMKEY's pick), so what is compared is what Redis promises:

- SCAN's arguments: cursors as Redis 7.0.15 reads them (strtoul: a sign,
  digits up to the end or a NUL, no blank first, 2^64 - 1 at most, the
  empty string), MATCH, COUNT and TYPE in any order, a later one over an
  earlier one, and their errors, byte for byte; a valid call answers a
  cursor and an array of keys;
- full iterations, with COUNT from 1 to more than the keys, MATCH and
  TYPE: the keys found are the keys Redis finds, each once, the last
  cursor is 0, and each call but the last finds COUNT keys at least
  (before MATCH and TYPE filter them), so an iteration takes at most
  keys / COUNT + 1 calls;
- an iteration while other clients add and delete keys: each key there
  from the start to the end is found;
- RANDOMKEY: nil on an empty database, a key of the database otherwise,
  every key of a small database in a few hundred calls, many keys each
  about as often as another; its errors byte for byte.

    python3 tests/keyspace_test.py --bendkv 6380 --redis 6390
"""
import argparse
import collections
import random
import socket


class Client:
    def __init__(self, port):
        self.s = socket.create_connection(("127.0.0.1", port), timeout=10)
        self.buf = b""

    def fill(self):
        chunk = self.s.recv(1 << 16)
        if not chunk:
            raise ConnectionError("closed")
        self.buf += chunk

    def line(self):
        while b"\r\n" not in self.buf:
            self.fill()
        i = self.buf.index(b"\r\n")
        line, self.buf = self.buf[:i], self.buf[i + 2:]
        return line

    # a reply, and the bytes it came in; a status is ("+", s) and an error
    # ("-", s), so that neither reads as a bulk string
    def read(self):
        raw = []

        def one():
            line = self.line()
            raw.append(line + b"\r\n")
            kind, rest = line[:1], line[1:]
            if kind == b"+":
                return ("+", rest)
            if kind == b"-":
                return ("-", rest)
            if kind == b":":
                return int(rest)
            if kind == b"$":
                n = int(rest)
                if n < 0:
                    return None
                while len(self.buf) < n + 2:
                    self.fill()
                v, self.buf = self.buf[:n], self.buf[n + 2:]
                raw.append(v + b"\r\n")
                return v
            if kind == b"*":
                n = int(rest)
                return None if n < 0 else [one() for _ in range(n)]
            raise ValueError(line)
        v = one()
        return v, b"".join(raw)

    def send(self, cmds):
        out = b""
        for args in cmds:
            out += b"*%d\r\n" % len(args)
            for a in args:
                a = a if isinstance(a, bytes) else a.encode()
                out += b"$%d\r\n%s\r\n" % (len(a), a)
        self.s.sendall(out)

    def ask(self, *args):
        self.send([args])
        return self.read()

    def pipe(self, cmds):
        self.send(cmds)
        return [self.read()[0] for _ in cmds]


ok = True
checks = 0


def check(name, good, why=""):
    global ok, checks
    ok &= good
    checks += 1
    if not good:
        print("FAIL: " + name + "\n      " + why[:3000])
    return good


def is_scan_reply(v):
    return (isinstance(v, list) and len(v) == 2 and isinstance(v[0], bytes) and v[0].isdigit()
            and isinstance(v[1], list) and all(isinstance(k, bytes) for k in v[1]))


# keys of a test: names of Redis's tests, numbers, binary and empty ones
def key_set(n, rnd):
    ks = {b"", b"\x00", b"\xff\r\n", b"\xd0\xba\xd0\xbb\xd1\x8e\xd1\x87", b"key:1", b"key:10", b"other"}
    while len(ks) < n:
        c = rnd.random()
        if c < 0.6:
            ks.add(b"key:%d" % rnd.randrange(10 * n + 10))
        elif c < 0.8:
            ks.add(bytes(rnd.randrange(256) for _ in range(rnd.randint(1, 8))))
        else:
            ks.add(b"user:%d:%s" % (rnd.randrange(1000), rnd.choice([b"a", b"bb", b"c?d", b"[x]"])))
    return sorted(ks)[:n]


def fill(c, ks):
    c.ask("FLUSHALL")
    for i in range(0, len(ks), 500):
        c.pipe([["SET", k, b"v"] for k in ks[i:i + 500]])


# a whole iteration: the keys of each call, and the calls
def iterate(c, opts, limit=1000000):
    cur, calls, found = b"0", 0, []
    while True:
        v, raw = c.ask("SCAN", cur, *opts)
        if not is_scan_reply(v):
            return v, calls
        cur, ks = v
        found.append(ks)
        calls += 1
        if cur == b"0" or calls > limit:
            return found, calls


def arguments(b, r):
    curs = [b"0", b"", b" 0", b"0 ", b"+0", b"-0", b"+", b"-", b"00", b"007", b"-1", b"18446744073709551615",
            b"18446744073709551616", b"-18446744073709551615", b"-18446744073709551616", b"99999999999999999999",
            b"1e3", b"0x10", b"\t5", b"\n5", b"\x0b5", b"\x0c5", b"\r5", b"5\x00abc", b"\x00", b"\x00x", b"abc",
            b"1048575", b"1048576", b"4294967296", b"+-1", b"--1", b"0" * 40 + b"1", b"-" + b"0" * 30 + b"5",
            b"1" * 21, b"5 ", "５".encode()]
    for cur in curs:
        (bv, braw), (rv, rraw) = b.ask("SCAN", cur, "COUNT", "1"), r.ask("SCAN", cur, "COUNT", "1")
        if isinstance(rv, tuple):
            check("SCAN %r: the error" % cur, braw == rraw, "bendkv %r\n      redis  %r" % (braw, rraw))
        else:
            check("SCAN %r: a cursor and keys" % cur, is_scan_reply(bv), "bendkv %r" % (braw[:200],))
    calls = [["SCAN"], ["scan"], ["SCAN", "0", "COUNT"], ["SCAN", "0", "COUNT", "0"], ["SCAN", "0", "COUNT", "-1"],
             ["SCAN", "0", "COUNT", "x"], ["SCAN", "0", "COUNT", "-0"], ["SCAN", "0", "COUNT", "01"],
             ["SCAN", "0", "COUNT", " 1"], ["SCAN", "0", "COUNT", "1 "], ["SCAN", "0", "COUNT", "+1"],
             ["SCAN", "0", "COUNT", "9223372036854775807"], ["SCAN", "0", "COUNT", "9223372036854775808"],
             ["SCAN", "0", "COUNT", "-9223372036854775808"], ["SCAN", "0", "COUNT", "-9223372036854775809"],
             ["SCAN", "0", "COUNT", "1.5"], ["SCAN", "0", "COUNT", ""], ["SCAN", "0", "MATCH"], ["SCAN", "0", "TYPE"],
             ["SCAN", "0", "FOO", "bar"], ["SCAN", "0", "COUNT", "x", "MATCH"], ["SCAN", "0", "MATCH", "a", "COUNT", "0"],
             ["SCAN", "x", "COUNT", "x"], ["SCAN", "x", "FOO"], ["SCAN", "0", "COUNT", "1", "COUNT", "x"],
             ["SCAN", "0", "count", "1", "match", "*", "type", "string", "x"], ["SCAN", "0", "Count", "2"],
             ["SCAN", "0", "MATCH", "*", "MATCH", "nomatch"], ["SCAN", "0", "TYPE", "list", "TYPE", "string"],
             ["SCAN", "0", "COUNTS", "1"], ["SCAN", "0", "COUNT", "1", "MATCH", "a", "TYPE", "x", "COUNT", "0"],
             ["SCAN", "0", "TYPE", "string", "FOO"], ["RANDOMKEY", "x"], ["randomkey", "x", "y"]]
    for args in calls:
        (bv, braw), (rv, rraw) = b.ask(*args), r.ask(*args)
        if isinstance(rv, tuple) or isinstance(bv, tuple):
            check(" ".join(args), braw == rraw, "bendkv %r\n      redis  %r" % (braw, rraw))
        else:
            check(" ".join(args) + ": a cursor and keys", is_scan_reply(bv), "bendkv %r" % (braw[:200],))


def iterations(b, r, rnd):
    for n in (0, 1, 7, 100, 1000, 5000):
        ks = key_set(n, rnd)
        for c in (b, r):
            fill(c, ks)
        counts = [1, 3, 10, 100, 10000] if n <= 1000 else [10, 1000]
        for count in counts:
            for opts in ([], ["MATCH", "*"], ["MATCH", "key:1*"], ["MATCH", "user:*:[ab]*"], ["MATCH", "nomatch"],
                         ["TYPE", "string"], ["TYPE", "STRING"], ["TYPE", "list"], ["TYPE", "none"],
                         ["MATCH", "*1*", "TYPE", "string"], ["MATCH", "\\[x]"]):
                if count < 10 and n > 100 and opts:
                    continue
                o = ["COUNT", str(count)] + opts
                name = "%d keys, SCAN ... %s" % (n, " ".join(o))
                bf, bcalls = iterate(b, o)
                rf, _ = iterate(r, o)
                if not check(name + ": an iteration", isinstance(bf, list), repr(bf)):
                    continue
                got = [k for ks_ in bf for k in ks_]
                want = sorted(set(k for ks_ in rf for k in ks_))
                check(name + ": the keys Redis finds", sorted(got) == want,
                      "bendkv %d keys, redis %d; missing %r, extra %r" % (len(got), len(want),
                      sorted(set(want) - set(got))[:5], sorted(set(got) - set(want))[:5]))
                check(name + ": each key once", len(got) == len(set(got)), "%d of %d" % (len(set(got)), len(got)))
                if not opts:
                    short = [len(x) for x in bf[:-1] if len(x) < count]
                    check(name + ": each call but the last finds COUNT keys", not short, repr(short[:10]))
                    check(name + ": at most keys / COUNT + 1 calls", bcalls <= n // count + 1,
                          "%d calls" % bcalls)
        # a cursor past the last bucket, and one from a SCAN, go on
        v, _ = b.ask("SCAN", "18446744073709551615")
        check("%d keys, SCAN 2^64 - 1: the end" % n, v == [b"0", []], repr(v))


# an iteration while another client changes the database: the keys there
# all along are found
def guarantee(port, rnd, rounds):
    c, w = Client(port), Client(port)
    for t in range(rounds):
        stay = [b"stay:%d:%d" % (t, i) for i in range(rnd.choice([10, 200, 2000]))]
        gone = [b"gone:%d:%d" % (t, i) for i in range(300)]
        fill(c, stay + gone)
        count = rnd.choice([1, 5, 20, 100])
        cur, found, calls = b"0", set(), 0
        while True:
            v, _ = c.ask("SCAN", cur, "COUNT", str(count))
            cur, ks = v
            found |= set(ks)
            calls += 1
            # between calls: some keys go, new ones come
            w.pipe([["DEL", rnd.choice(gone)] for _ in range(5)] +
                   [["SET", b"new:%d:%d:%d" % (t, calls, i), b"x"] for i in range(5)])
            if cur == b"0":
                break
        missing = set(stay) - found
        check("an iteration under changes (%d keys, COUNT %d)" % (len(stay), count), not missing,
              "%d missing, e.g. %r" % (len(missing), sorted(missing)[:3]))
        extra = {k for k in found if not k.startswith((b"stay:", b"gone:", b"new:"))}
        check("an iteration under changes: only the database's keys", not extra, repr(sorted(extra)[:3]))


def randomkey(b, r, rnd):
    for c in (b, r):
        c.ask("FLUSHALL")
    (bv, braw), (rv, rraw) = b.ask("RANDOMKEY"), r.ask("RANDOMKEY")
    check("RANDOMKEY on an empty database", braw == rraw, "bendkv %r\n      redis  %r" % (braw, rraw))
    b.ask("SET", "only", "1")
    got = set(b.pipe([["RANDOMKEY"]] * 50))
    check("RANDOMKEY of one key", got == {b"only"}, repr(got))
    for n in (2, 3, 10):
        ks = key_set(n, rnd)
        fill(b, ks)
        got = collections.Counter(b.pipe([["RANDOMKEY"]] * (100 * n)))
        check("RANDOMKEY of %d keys: every key, and only them" % n, set(got) == set(ks),
              "missing %r, extra %r" % (sorted(set(ks) - set(got)), sorted(set(got) - set(ks))))
    # many keys: each about as often as another, as Redis picks them
    ks = key_set(1000, rnd)
    fill(b, ks)
    got = collections.Counter()
    for _ in range(20):
        got.update(b.pipe([["RANDOMKEY"]] * 1000))
    check("RANDOMKEY of 1000 keys: only the database's keys", set(got) <= set(ks), "")
    check("RANDOMKEY of 1000 keys: nearly all of them in 20000 picks", len(got) >= 990, "%d keys" % len(got))
    check("RANDOMKEY of 1000 keys: none more than 4 times as often as the mean", max(got.values()) <= 80,
          "most %d" % max(got.values()))
    # after FLUSHALL, nil again, in one pipeline with the keys before it
    v = b.pipe([["RANDOMKEY"], ["FLUSHALL"], ["RANDOMKEY"], ["SET", "a", "1"], ["RANDOMKEY"], ["DEL", "a"], ["RANDOMKEY"]])
    check("RANDOMKEY in a pipeline that empties and fills the database",
          v[1:] == [("+", b"OK"), None, ("+", b"OK"), b"a", 1, None] and v[0] in ks, repr(v))
    # inline
    s = socket.create_connection(("127.0.0.1", b.s.getpeername()[1]), timeout=10)
    s.sendall(b"RANDOMKEY\r\nSCAN 0 COUNT 10 MATCH a\r\n")
    data = b""
    while data.count(b"\r\n") < 5:
        data += s.recv(4096)
    s.close()
    check("RANDOMKEY and SCAN inline", data == b"$-1\r\n*2\r\n$1\r\n0\r\n*0\r\n", repr(data))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bendkv", type=int, default=6380)
    ap.add_argument("--redis", type=int, default=6390)
    ap.add_argument("--rounds", type=int, default=20)
    ap.add_argument("--seed", type=int, default=1)
    a = ap.parse_args()
    rnd = random.Random(a.seed)
    b, r = Client(a.bendkv), Client(a.redis)
    for c in (b, r):
        c.ask("FLUSHALL")
        c.ask("SET", "k", "v")
    arguments(b, r)
    iterations(b, r, rnd)
    guarantee(a.bendkv, rnd, a.rounds)
    randomkey(b, r, rnd)
    for c in (b, r):
        c.ask("FLUSHALL")
    print("%d checks; " % checks + ("ALL OK" if ok else "SOME CHECKS FAILED"))
    return ok


if __name__ == "__main__":
    raise SystemExit(0 if main() else 1)
