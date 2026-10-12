#!/usr/bin/env python3
"""Hashes against Redis: a script of hash commands at their edges, then
random ones on a few keys, replies compared one by one. A hash Redis
keeps as a listpack (at most 512 fields, each field and value of at most
64 bytes) answers its fields in the order they came, on both servers;
one it keeps as a hashtable answers them in the order of each server's
own table, so HGETALL, HKEYS, HVALS and a whole HSCAN of it are compared
as sets (OBJECT ENCODING, compared as it is, says which). HRANDFIELD
picks at random on each server: its errors are compared as they are,
its picks by what they must be (how many, from the hash, different ones
for a positive count, each field with its value). MEMORY USAGE is an
estimate on each server: compared by kind (a number, a nil, an error).
A hash whose key's time has passed is made anew by a write, as in Redis.

    python3 tests/hash_test.py --bendkv 6380 --redis 6390 [--rounds 3000] [--seed 1]
"""
import argparse
import random
import sys
import time

from diff_test import Conn

bad = 0
n = 0


def run(c, cmd):
    c.send([cmd])
    return c.reply()


def is_table(c, key):
    return run(c, [b"OBJECT", b"ENCODING", key]) == (b"$", b"hashtable")


def pairs(x):
    xs = [v for _, v in x[1]]
    return sorted(zip(xs[0::2], xs[1::2]))


def norm(cmd, x, table):
    name = cmd[0].upper()
    if not table or x[0] != b"*":
        return x
    if name == b"HGETALL":
        return (b"*", pairs(x))
    if name in (b"HKEYS", b"HVALS"):
        return (b"*", sorted(x[1]))
    return x


def fail(cmd, x, y):
    global bad
    bad += 1
    if bad <= 20:
        print("FAIL: %r: BendKV %r, Redis %r" % (b" ".join(cmd)[:200], x, y))


def same(b, r, cmd):
    global n
    n += 1
    key = cmd[1] if len(cmd) > 1 else b""
    x, y = run(b, cmd), run(r, cmd)
    name = cmd[0].upper()
    if name == b"HRANDFIELD":
        return rand_ok(b, r, cmd, x, y)
    if name == b"MEMORY":
        if x[0] != y[0] or (x[0] != b":" and x != y):
            fail(cmd, x, y)
        return
    if name == b"HSCAN" and y[0] == b"*" and is_table(r, key):
        return scan_all(b, r, cmd)
    t = name in (b"HGETALL", b"HKEYS", b"HVALS") and is_table(r, key)
    if norm(cmd, x, t) != norm(cmd, y, t):
        fail(cmd, x, y)


# a whole HSCAN of a hashtable from cursor 0, the pairs as a set
def scan_all(b, r, cmd):
    got = []
    for c in (b, r):
        cur, seen = b"0", set()
        for _ in range(100000):
            x = run(c, [cmd[0], cmd[1], cur] + cmd[3:])
            cur = x[1][0][1]
            xs = [v for _, v in x[1][1][1]]
            seen |= set(zip(xs[0::2], xs[1::2]))
            if cur == b"0":
                break
        got.append(seen)
    if got[0] != got[1]:
        fail(cmd, sorted(got[0])[:5], sorted(got[1])[:5])


def rand_ok(b, r, cmd, x, y):
    if y[0] != b"*" or x[0] != b"*":
        if x != y and not (x[0] == y[0] == b"$" and x[1] is not None and y[1] is not None):
            fail(cmd, x, y)
        return
    h = dict(pairs(run(r, [b"HGETALL", cmd[1]])))
    if not h:
        if x != y:
            fail(cmd, x, y)
        return
    wv = len(cmd) > 3
    cnt = int(cmd[2])
    xs = [v for _, v in x[1]]
    fields = xs[0::2] if wv else xs
    ok = len(fields) == (abs(cnt) if cnt < 0 else min(cnt, len(h))) and all(f in h for f in fields)
    if cnt >= 0:
        ok = ok and len(set(fields)) == len(fields)
    if wv:
        ok = ok and all(h[f] == v for f, v in zip(xs[0::2], xs[1::2]))
    if not ok or len(x[1]) != len(y[1]):
        fail(cmd, x, y)


def big(i):
    return b"v" * (60 + i)


SCRIPT = [
    [b"HSET", b"h"], [b"HSET", b"h", b"a"], [b"HSET", b"h", b"a", b"1", b"b"], [b"HSET", b"h", b"a", b"1", b"b", b"2"],
    [b"HSET", b"h", b"a", b"3", b"c", b"4", b"a", b"5"], [b"HGETALL", b"h"], [b"HMSET", b"h", b"d", b"6"],
    [b"HMSET", b"h"], [b"HMSET", b"h", b"x"], [b"HGET", b"h", b"a"], [b"HGET", b"h", b"zz"], [b"HGET", b"nope", b"a"],
    [b"HGET", b"h"], [b"HMGET", b"h", b"a", b"zz", b"d"], [b"HMGET", b"nope", b"a", b"b"], [b"HMGET", b"h"],
    [b"HLEN", b"h"], [b"HLEN", b"nope"], [b"HSTRLEN", b"h", b"a"], [b"HSTRLEN", b"h", b"zz"], [b"HSTRLEN", b"nope", b"a"],
    [b"HEXISTS", b"h", b"a"], [b"HEXISTS", b"h", b"zz"], [b"HEXISTS", b"nope", b"a"], [b"HKEYS", b"h"], [b"HVALS", b"h"],
    [b"HKEYS", b"nope"], [b"HVALS", b"nope"], [b"HGETALL", b"nope"], [b"HSETNX", b"h", b"a", b"9"],
    [b"HSETNX", b"h", b"e", b"9"], [b"HSETNX", b"n1", b"f", b"v"], [b"HSETNX", b"h", b"a"],
    [b"HINCRBY", b"h", b"a", b"10"], [b"HINCRBY", b"h", b"a", b"-100"], [b"HINCRBY", b"h", b"zz", b"7"],
    [b"HINCRBY", b"n2", b"f", b"-3"], [b"HINCRBY", b"h", b"a", b"x"], [b"HINCRBY", b"h", b"a", b"1.5"],
    [b"HINCRBY", b"h", b"a", b""], [b"HSET", b"h", b"s", b"abc"], [b"HINCRBY", b"h", b"s", b"1"],
    [b"HSET", b"h", b"sp", b" 1"], [b"HINCRBY", b"h", b"sp", b"1"], [b"HSET", b"h", b"big", b"9999999999999"],
    [b"HINCRBY", b"h", b"big", b"1"], [b"HINCRBY", b"h", b"a"], [b"HDEL", b"h", b"zz"], [b"HDEL", b"h", b"a", b"a", b"b"],
    [b"HDEL", b"nope", b"a"], [b"HDEL", b"h"], [b"HGETALL", b"h"], [b"TYPE", b"h"], [b"OBJECT", b"ENCODING", b"h"],
    [b"SET", b"s", b"str"], [b"HSET", b"s", b"f", b"v"], [b"HGET", b"s", b"f"], [b"HMGET", b"s", b"f"],
    [b"HLEN", b"s"], [b"HSTRLEN", b"s", b"f"], [b"HEXISTS", b"s", b"f"], [b"HKEYS", b"s"], [b"HVALS", b"s"],
    [b"HGETALL", b"s"], [b"HSETNX", b"s", b"f", b"v"], [b"HINCRBY", b"s", b"f", b"1"], [b"HDEL", b"s", b"f"],
    [b"HSCAN", b"s", b"0"], [b"HRANDFIELD", b"s"], [b"HMSET", b"s", b"f", b"v"], [b"GET", b"h"], [b"APPEND", b"h", b"x"],
    [b"INCR", b"h"], [b"SETRANGE", b"h", b"0", b"x"], [b"GETRANGE", b"h", b"0", b"1"], [b"STRLEN", b"h"],
    [b"BITCOUNT", b"h"], [b"GETBIT", b"h", b"0"], [b"SETBIT", b"h", b"0", b"1"], [b"GETSET", b"h", b"x"],
    [b"GETDEL", b"h"], [b"GETEX", b"h"], [b"SETNX", b"h", b"x"], [b"MSETNX", b"h", b"x"], [b"LCS", b"h", b"s"],
    [b"BITOP", b"AND", b"d", b"h"], [b"BITFIELD", b"h", b"GET", b"u8", b"0"], [b"EXISTS", b"h"],
    [b"HSCAN", b"h", b"0"], [b"HSCAN", b"h", b"0", b"COUNT", b"1"], [b"HSCAN", b"h", b"0", b"MATCH", b"e*"],
    [b"HSCAN", b"h", b"0", b"MATCH", b"*"], [b"HSCAN", b"h", b"0", b"TYPE", b"string"], [b"HSCAN", b"h", b"0", b"COUNT"],
    [b"HSCAN", b"h", b"0", b"COUNT", b"0"], [b"HSCAN", b"h", b"0", b"COUNT", b"x"], [b"HSCAN", b"h", b"x"],
    [b"HSCAN", b"h", b"-1"], [b"HSCAN", b"nope", b"0"], [b"HSCAN", b"nope", b"0", b"BAD"], [b"HSCAN", b"h", b"0", b"BAD"],
    [b"HSCAN", b"h", b"7"], [b"HSCAN", b"h"], [b"HRANDFIELD", b"h"], [b"HRANDFIELD", b"h", b"2"],
    [b"HRANDFIELD", b"h", b"100"], [b"HRANDFIELD", b"h", b"-7"], [b"HRANDFIELD", b"h", b"-7", b"WITHVALUES"],
    [b"HRANDFIELD", b"h", b"3", b"WITHVALUES"], [b"HRANDFIELD", b"h", b"0"], [b"HRANDFIELD", b"h", b"x"],
    [b"HRANDFIELD", b"h", b"1", b"bad"], [b"HRANDFIELD", b"h", b"1", b"WITHVALUES", b"x"],
    [b"HRANDFIELD", b"nope"], [b"HRANDFIELD", b"nope", b"3"], [b"HRANDFIELD", b"nope", b"x"],
    [b"HRANDFIELD", b"h", b"-9223372036854775808"],
    [b"HRANDFIELD", b"h", b"4611686018427387904", b"WITHVALUES"],
    [b"HRANDFIELD", b"h", b"-4611686018427387904", b"WITHVALUES"], [b"HRANDFIELD", b"h", b"9223372036854775808"],
    [b"MEMORY", b"USAGE", b"h"], [b"MEMORY", b"USAGE", b"s"], [b"MEMORY", b"USAGE", b"nope"],
    [b"MEMORY", b"USAGE", b"h", b"SAMPLES", b"0"], [b"MEMORY", b"USAGE", b"h", b"SAMPLES", b"-1"],
    [b"MEMORY", b"USAGE", b"h", b"SAMPLES"], [b"MEMORY", b"USAGE", b"h", b"BAD", b"1"], [b"MEMORY", b"USAGE"],
    [b"MEMORY", b"HELP"], [b"MEMORY", b"NOPE"], [b"MEMORY"],
    [b"EXPIRE", b"h", b"100"], [b"TTL", b"h"], [b"HSET", b"h", b"q", b"1"], [b"TTL", b"h"], [b"PERSIST", b"h"],
    [b"TTL", b"h"], [b"RENAME", b"h", b"h2"], [b"HGETALL", b"h2"], [b"COPY", b"h2", b"h3"], [b"HGETALL", b"h3"],
    [b"MOVE", b"h3", b"1"], [b"SELECT", b"1"], [b"HGETALL", b"h3"], [b"SELECT", b"0"], [b"SET", b"h2", b"x"],
    [b"TYPE", b"h2"], [b"HSET", b"h2", b"a", b"1"], [b"DEL", b"h2"], [b"HSET", b"h2", b"a", b"1"], [b"TYPE", b"h2"],
    [b"OBJECT", b"ENCODING", b"h2"], [b"HSET", b"h2", b"long", big(5)], [b"OBJECT", b"ENCODING", b"h2"],
    [b"HDEL", b"h2", b"long"], [b"OBJECT", b"ENCODING", b"h2"], [b"HGETALL", b"h2"],
    [b"HSET", b"h4", big(4), b"x"], [b"OBJECT", b"ENCODING", b"h4"], [b"HSET", b"h5", b"f", big(4)],
    [b"OBJECT", b"ENCODING", b"h5"], [b"HSET", b"h6", b"f", big(5)[:64]], [b"OBJECT", b"ENCODING", b"h6"],
    [b"HSET", b"\x00k", b"\x00f", b"\r\n\x00"], [b"HGETALL", b"\x00k"], [b"HSET", b"e", b"", b""], [b"HGETALL", b"e"],
    [b"HSTRLEN", b"e", b""], [b"HEXISTS", b"e", b""], [b"HDEL", b"e", b""], [b"EXISTS", b"e"],
]


# a hash of size n, made by HSET (one call, or one field a call)
def fill(key, nf, one):
    ps = []
    for i in range(nf):
        ps += [b"f%d" % i, b"%d" % i]
    if one:
        return [[b"HSET", key] + ps]
    return [[b"HSET", key, ps[2 * i], ps[2 * i + 1]] for i in range(nf)]


def sizes(b, r):
    for nf in (511, 512, 513, 1200):
        key = b"z%d" % nf
        for cmd in fill(key, nf, nf != 513):
            same(b, r, cmd)
        for cmd in ([b"OBJECT", b"ENCODING", key], [b"HLEN", key], [b"HGETALL", key], [b"HKEYS", key],
                    [b"HVALS", key], [b"HSCAN", key, b"0"], [b"HSCAN", key, b"0", b"COUNT", b"100"],
                    [b"HSCAN", key, b"0", b"MATCH", b"f1*"], [b"HRANDFIELD", key, b"5"],
                    [b"HRANDFIELD", key, b"-5", b"WITHVALUES"], [b"HRANDFIELD", key, b"2000"],
                    [b"HGET", key, b"f500"], [b"HDEL", key, b"f0", b"f1"], [b"OBJECT", b"ENCODING", key],
                    [b"HLEN", key], [b"HINCRBY", key, b"f7", b"3"], [b"HMGET", key, b"f7", b"f8", b"x"]):
            same(b, r, cmd)


# a hash whose time passed: a read finds nothing, a write makes it anew
def expired(b, r):
    for c in (b, r):
        for cmd in ([b"HSET", b"x1", b"a", b"1", b"b", b"2"], [b"PEXPIRE", b"x1", b"50"],
                    [b"SET", b"x2", b"str", b"PX", b"50"], [b"HSET", b"x3", b"a", b"1"], [b"PEXPIRE", b"x3", b"50"],
                    [b"HSET", b"x4", b"a", b"1"], [b"PEXPIRE", b"x4", b"50"]):
            run(c, cmd)
    time.sleep(0.2)
    for cmd in ([b"HGET", b"x1", b"a"], [b"HSET", b"x1", b"c", b"3"], [b"HGETALL", b"x1"], [b"TTL", b"x1"],
                [b"HSET", b"x2", b"f", b"v"], [b"HGETALL", b"x2"], [b"TYPE", b"x2"], [b"HINCRBY", b"x3", b"a", b"5"],
                [b"HGETALL", b"x3"], [b"HSETNX", b"x4", b"a", b"9"], [b"HGETALL", b"x4"], [b"HDEL", b"x4", b"a"],
                [b"EXISTS", b"x4"]):
        same(b, r, cmd)


def rand_cmd(r):
    key = r.choice([b"r1", b"r2", b"r3", b"rs"])
    f = lambda: r.choice([b"a", b"b", b"c", b"d", b"e", b"f", b"g", b""]) if r.random() < 0.9 else b"x" * r.randint(1, 80)
    v = lambda: r.choice([b"1", b"-2", b"10", b"x", b"", b"999999999999"]) if r.random() < 0.9 else b"y" * r.randint(60, 70)
    k = r.random()
    if k < 0.2:
        return [b"HSET", key] + [x for _ in range(r.randint(1, 4)) for x in (f(), v())]
    if k < 0.25:
        return [b"HMSET", key] + [x for _ in range(r.randint(1, 3)) for x in (f(), v())]
    if k < 0.3:
        return [b"HSETNX", key, f(), v()]
    if k < 0.4:
        return [b"HDEL", key] + [f() for _ in range(r.randint(1, 3))]
    if k < 0.5:
        return [b"HINCRBY", key, f(), r.choice([b"1", b"-1", b"100", b"x", b"999999999999"])]
    if k < 0.55:
        return [r.choice([b"SET", b"DEL", b"EXPIRE"]), key] + ([b"str"] if r.random() < 0.5 else [b"1000"])
    if k < 0.6:
        return [b"HMGET", key, f(), f()]
    if k < 0.65:
        return [b"HRANDFIELD", key] + r.choice([[], [b"3"], [b"-3", b"WITHVALUES"], [b"9"]])
    return r.choice([[b"HGET", key, f()], [b"HLEN", key], [b"HSTRLEN", key, f()], [b"HEXISTS", key, f()],
                     [b"HKEYS", key], [b"HVALS", key], [b"HGETALL", key], [b"HSCAN", key, b"0"],
                     [b"TYPE", key], [b"OBJECT", b"ENCODING", key]])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bendkv", type=int, default=6380)
    ap.add_argument("--redis", type=int, default=6390)
    ap.add_argument("--rounds", type=int, default=3000)
    ap.add_argument("--seed", type=int, default=1)
    a = ap.parse_args()
    b, rd = Conn(a.bendkv), Conn(a.redis)
    for c in (b, rd):
        run(c, [b"FLUSHALL"])
    for cmd in SCRIPT:
        same(b, rd, cmd)
    sizes(b, rd)
    expired(b, rd)
    r = random.Random(a.seed)
    for _ in range(a.rounds):
        same(b, rd, rand_cmd(r))
    for c in (b, rd):
        run(c, [b"FLUSHALL"])
    if bad:
        sys.exit("FAIL: %d of %d" % (bad, n))
    print("OK: %d hash commands, each answered as Redis answers it" % n)


if __name__ == "__main__":
    main()
