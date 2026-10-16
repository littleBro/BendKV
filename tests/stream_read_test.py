#!/usr/bin/env python3
"""The reads of a stream against Redis 7.0.15: XLEN, XRANGE, XREVRANGE,
XREAD of one key and of several, XINFO (STREAM, its FULL form, GROUPS,
CONSUMERS, HELP) and XPENDING. BendKV has no command that writes a
stream yet, so Redis makes the streams, the shapes of
stream_dump_test.py, and BendKV RESTOREs each one's payload; then both
servers answer the same reads, in RESP2 and in RESP3, each reply
compared whole.

- The IDs read are those of the stream (its entries, the last ID, the
  greatest deleted, the first, the groups' last IDs, the pending IDs),
  their neighbours, and the edges (0-0, 2^64 - 1, "-", "+"), each as an
  ID, without its sequence, and after "(" (a bound left out).
- XRANGE and XREVRANGE of pairs of them, with COUNT of none, 0, 1, 2, 7,
  -1 and 2^63 - 1; XREAD after each, with "$", and with COUNT; XREAD of
  the stream with another stream, a key not there and the stream again.
- XINFO STREAM, FULL with COUNT none, 0, 1, 3 and -1; GROUPS; CONSUMERS
  of each group and of one not there; XPENDING's summary of each group,
  and its entries over ranges, counts, consumers and IDLE times.
- The errors: arity, syntax, IDs that are none, an interval past its
  edge, WRONGTYPE, a key or a group not there, XREAD's options, XINFO's
  subcommands.

An idle time (XINFO CONSUMERS, XPENDING) is now less a time, read by
each server at its own now: two that differ by less than 2 s count as
the same.

XREAD with BLOCK is served when an entry is there; BendKV blocks on no
stream yet, so where Redis would wait it answers an error, which the
test checks on BendKV alone. In MULTI, where Redis does not wait, both
answer a null array.

    python3 tests/stream_read_test.py --bendkv 6380 --redis 6390 [--seed 1]
"""
import argparse
import random
import sys
import time

from diff_test import Conn
from dump_test import cmd, flat, run
from stream_dump_test import big_shape, make, pipe, shapes

bad = 0
n = 0
U64 = 2 ** 64 - 1
LOOSE = 2000


def fail(what, x, y):
    global bad
    bad += 1
    if bad <= 40:
        print("FAIL: %s: BendKV %s, Redis %s" % (str(what)[:300], str(x)[:400], str(y)[:400]))


# whether two replies are the same, an idle time within LOOSE ms (one
# after a bulk "idle", and an XPENDING entry's third item)
def alike(x, y, xpend=False):
    if x == y:
        return True
    kx, vx = x
    ky, vy = y
    if kx != ky or not isinstance(vx, list) or not isinstance(vy, list) or len(vx) != len(vy):
        return False
    if xpend and len(vx) == 4 and all(not isinstance(e[1], list) for e in vx):
        for i in range(4):
            if i == 2:
                if vx[i][0] != b":" or vy[i][0] != b":" or abs(int(vx[i][1]) - int(vy[i][1])) > LOOSE:
                    return False
            elif vx[i] != vy[i]:
                return False
        return True
    i = 0
    while i < len(vx):
        if vx[i] == vy[i] == (b"$", b"idle") and i + 1 < len(vx):
            a, b = vx[i + 1], vy[i + 1]
            if a[0] != b":" or b[0] != b":" or abs(int(a[1]) - int(b[1])) > LOOSE:
                return False
            i += 2
            continue
        if not alike(vx[i], vy[i], xpend):
            return False
        i += 1
    return True


# each command to both servers, pipelined, the replies compared
def batch(b, r, cmds, loose=False, xpend=False):
    global n
    xs, ys = pipe(b, cmds), pipe(r, cmds)
    for c, x, y in zip(cmds, xs, ys):
        n += 1
        if not (alike(x, y, xpend) if loose else x == y):
            fail(b" ".join(c)[:200], x, y)


# The IDs of a stream
# -------------------

def ids_of(r):
    out = set()
    rep = run(r, cmd("XRANGE", "s", "-", "+"))
    if rep[1]:
        for e in rep[1]:
            out.add(e[1][0][1].decode())
    info = run(r, cmd("XINFO", "STREAM", "s", "FULL", "COUNT", 0))
    if info[0] in (b"*", b"%") and info[1]:
        kv = info[1]
        for i in range(0, len(kv) - 1, 2):
            k, v = kv[i][1], kv[i + 1]
            if k in (b"last-generated-id", b"max-deleted-entry-id", b"recorded-first-entry-id"):
                out.add(v[1].decode())
            if k == b"groups":
                for g in v[1]:
                    gkv = g[1]
                    for j in range(0, len(gkv) - 1, 2):
                        if gkv[j][1] == b"last-delivered-id":
                            out.add(gkv[j + 1][1].decode())
                        if gkv[j][1] == b"pending":
                            for p in gkv[j + 1][1]:
                                out.add(p[1][0][1].decode())
    return out


def near(i):
    ms, sq = (int(x) for x in i.split("-"))
    out = {i}
    for d in (-1, 1):
        if 0 <= sq + d <= U64:
            out.add("%d-%d" % (ms, sq + d))
        if 0 <= ms + d <= U64:
            out.add("%d-%d" % (ms + d, sq))
    out.add(str(ms))
    return out


def bounds(ids, rnd, k):
    base = set()
    for i in ids:
        base |= near(i)
    base |= {"0-0", "0", "0-1", "%d-%d" % (U64, U64), str(U64), "%d-0" % U64, "1-0"}
    base = sorted(base, key=lambda s: tuple(int(x) for x in (s.split("-") + ["0"])[:2]))
    if len(base) > k:
        base = sorted(rnd.sample(base, k), key=lambda s: tuple(int(x) for x in (s.split("-") + ["0"])[:2]))
    out = list(base) + ["-", "+"]
    out += ["(" + x for x in rnd.sample(base, min(len(base), 6))]
    return out


# The reads
# ---------

COUNTS = [None, 0, 1, 2, 7, -1, 2 ** 63 - 1]


def ranges(bs, rnd, k):
    out = []
    for _ in range(k):
        a, z = rnd.choice(bs), rnd.choice(bs)
        c = rnd.choice(COUNTS)
        tail = [] if c is None else ["COUNT", c]
        out.append(cmd("XRANGE", "s", a, z, *tail))
        out.append(cmd("XREVRANGE", "s", z, a, *tail))
    out.append(cmd("XRANGE", "s", "-", "+"))
    out.append(cmd("XREVRANGE", "s", "+", "-"))
    return out


def reads(bs, rnd, live):
    out = []
    for i in bs + ["$"]:
        if i.startswith("(") or i in ("-", "+"):
            continue
        c = rnd.choice(COUNTS[:5])
        tail = [] if c is None else ["COUNT", c]
        out.append(cmd("XREAD", *tail, "STREAMS", "s", i))
    out.append(cmd("XREAD", "STREAMS", "s", "nokey", "0", "0"))
    out.append(cmd("XREAD", "COUNT", 2, "STREAMS", "s", "s", "0", "$"))
    out.append(cmd("XREAD", "COUNT", 3, "STREAMS", "s", "s2", "s", "0-0", "0", "0"))
    if live:
        out.append(cmd("XREAD", "BLOCK", 0, "STREAMS", "s", "0"))
        out.append(cmd("XREAD", "BLOCK", 10, "COUNT", 1, "STREAMS", "nokey", "s", "0", "0"))
    # in MULTI a BLOCK does not wait
    out += [cmd("MULTI"), cmd("XREAD", "BLOCK", 0, "STREAMS", "s", "$"),
            cmd("XREAD", "BLOCK", 10, "COUNT", 1, "STREAMS", "nokey", "s", "$", "0"),
            cmd("XREAD", "BLOCK", 0, "STREAMS", "s", "0"), cmd("XREAD", "BLOCK", 0, "STREAMS", "s", "nokey", "$", "$"),
            cmd("XREAD", "BLOCK", 0, "STREAMS", "s", "str", "0", "0"), cmd("EXEC")]
    return out


def groups_of(r):
    rep = run(r, cmd("XINFO", "GROUPS", "s"))
    out = []
    if rep[0] == b"*":
        for g in rep[1]:
            kv = g[1]
            out.append(kv[1][1])
    return out


def consumers_of(r, g):
    rep = run(r, cmd("XINFO", "CONSUMERS", "s", g))
    out = []
    if rep[0] == b"*":
        for c in rep[1]:
            out.append(c[1][1][1])
    return out


def infos(gs, r):
    out = [cmd("XINFO", "STREAM", "s"), cmd("XINFO", "STREAM", "s", "FULL"), cmd("XINFO", "GROUPS", "s"),
           cmd("XINFO", "STREAM", "s", "full", "count", 1), cmd("XINFO", "STREAM", "s", "FULL", "COUNT", 3),
           cmd("XINFO", "STREAM", "s", "FULL", "COUNT", -1), cmd("XINFO", "STREAM", "s", "FULL", "COUNT", 0),
           cmd("XLEN", "s"), cmd("XINFO", "CONSUMERS", "s", "nogroup")]
    for g in gs:
        out.append(cmd("XINFO", "CONSUMERS", "s", g))
    return out


def pendings(gs, r, bs, rnd):
    out = []
    for g in gs + [b"nogroup"]:
        out.append(cmd("XPENDING", "s", g))
        cons = consumers_of(r, g) + [b"nobody"] if g != b"nogroup" else [b"x"]
        for _ in range(12):
            a, z = rnd.choice(bs), rnd.choice(bs)
            c = rnd.choice([0, 1, 3, 10, -2, 2 ** 63 - 1])
            tail = [rnd.choice(cons)] if rnd.random() < 0.5 else []
            if rnd.random() < 0.4:
                idle = rnd.choice([0, 1, -5, 10 ** 12, -10 ** 12, 2 ** 63 - 1, -2 ** 63])
                out.append(cmd("XPENDING", "s", g, "IDLE", idle, a, z, c, *tail))
            else:
                out.append(cmd("XPENDING", "s", g, a, z, c, *tail))
        out.append(cmd("XPENDING", "s", g, "-", "+", 1000))
    return out


# the errors, of no shape
def errors():
    out = []
    for c in (["XLEN"], ["XLEN", "s", "x"], ["XRANGE", "s", "-"], ["XREVRANGE", "s"], ["XREAD", "STREAMS", "s"],
              ["XINFO"], ["XINFO", "STREAM"], ["XINFO", "GROUPS"], ["XINFO", "GROUPS", "s", "x"],
              ["XINFO", "CONSUMERS", "s"], ["XINFO", "HELP", "x"], ["XPENDING", "s"]):
        out.append(cmd(*c))
    bad_ids = ["", "x", "1-x", "1-", "-1", "1--3", "0x10", "9 ", "18446744073709551616", "1-18446744073709551616",
               "1" * 128, " 8", "+7", "009-3", "1--03", "5- 3", "5-+3", "5--0", "1- -5", "\t9", " +12-0", "1\x003",
               "7\x00-junk", "-0-5", "1-2-3", "((1", "(-", "(+", "(", "-9223372036854775808", "-9223372036854775809",
               "+", "-"]
    for i in bad_ids:
        out.append(cmd("XRANGE", "s", i, "+"))
        out.append(cmd("XRANGE", "s", "-", i))
        out.append(cmd("XREVRANGE", "s", i, "-"))
        out.append(cmd("XREAD", "STREAMS", "s", i))
        out.append(cmd("XREAD", "STREAMS", "nokey", i))
        out.append(cmd("XPENDING", "s", "g1", i, "+", 10))
        out.append(cmd("XPENDING", "nokey", "g1", "-", i, 10))
    for c in (["XRANGE", "s", "(%d-%d" % (U64, U64), "+"], ["XRANGE", "s", "-", "(0-0"], ["XRANGE", "s", "-", "(0"],
              ["XREVRANGE", "s", "(0-0", "-"], ["XPENDING", "s", "g1", "(%d-%d" % (U64, U64), "+", 1],
              ["XRANGE", "s", "-", "+", "COUNT"], ["XRANGE", "s", "-", "+", "COUNT", "x"], ["XRANGE", "s", "-", "+", "FOO", 1],
              ["XRANGE", "s", "-", "+", "COUNT", 1, "COUNT", 2], ["XRANGE", "s", "-", "+", "count", 1, "x"],
              ["XREAD", "COUNT", "x", "STREAMS", "s", "0"], ["XREAD", "BLOCK", -1, "STREAMS", "s", "0"],
              ["XREAD", "BLOCK", "x", "STREAMS", "s", "0"], ["XREAD", "STREAMS", "s", "t", "0"],
              ["XREAD", "GROUP", "g", "c", "STREAMS", "s", "0"], ["XREAD", "NOACK", "STREAMS", "s", "0"],
              ["XREAD", "COUNT", 1, "s", "0"], ["XREAD", "FOO", "STREAMS", "s", "0"], ["XREAD", "COUNT", 1, "BLOCK"],
              ["XREAD", "STREAMS", "s", ">"], ["XREAD", "STREAMS", "s", "s", "0", ">"], ["XREAD", "GROUP", "g", "STREAMS"],
              ["XREAD", "COUNT", -3, "STREAMS", "s", "0"], ["XREAD", "streams", "s", "$"],
              ["XREAD", "BLOCK", 0, "STREAMS", "s", "x"], ["XREAD", "BLOCK", 0, "STREAMS", "s", ">"],
              ["XREAD", "BLOCK", 0, "STREAMS", "str", "0"], ["XREAD", "BLOCK", 0, "STREAMS", "s", "nokey", "str", "$", "$", "0"],
              ["XINFO", "FOO", "s"], ["XINFO", "STREAM", "nokey"], ["XINFO", "GROUPS", "nokey"],
              ["XINFO", "CONSUMERS", "nokey", "g"], ["XINFO", "STREAM", "s", "FULLX"], ["XINFO", "STREAM", "s", "FULL", "COUNT"],
              ["XINFO", "STREAM", "s", "FULL", "COUNT", "x"], ["XINFO", "STREAM", "s", "FULL", "x", 1],
              ["XINFO", "stream", "s", "FULL", "COUNT", 1, "x"], ["XINFO", "STREAM", "s", "x", "COUNT", 1], ["XINFO", "HELP"],
              ["XINFO", "help"], ["XPENDING", "s", "g1", "-"], ["XPENDING", "s", "g1", "-", "+"],
              ["XPENDING", "s", "g1", "-", "+", "x"], ["XPENDING", "s", "g1", "IDLE", "x", "-", "+", 1],
              ["XPENDING", "s", "g1", "IDLE", 5, "-", "+"], ["XPENDING", "s", "g1", "IDLE", 5, "-"],
              ["XPENDING", "s", "g1", "-", "+", 1, "c", "x", "y"], ["XPENDING", "s", "g1", "-", "+", 1, "c", "x", "y", "z"],
              ["XPENDING", "nokey", "g"], ["XPENDING", "s", "nogroup"], ["XPENDING", "s", "nogroup", "-", "+", 1],
              ["XPENDING", "s", "g1", "idle", 0, "-", "+", 5, "alice"]):
        out.append(cmd(*c))
    for k in ("str", "hash"):
        for c in (["XLEN", k], ["XRANGE", k, "-", "+"], ["XREVRANGE", k, "+", "-", "COUNT", 0], ["XREAD", "STREAMS", k, "0"],
                  ["XREAD", "STREAMS", "s", k, "0", "x"], ["XREAD", "STREAMS", k, "s", "x", "0"], ["XINFO", "STREAM", k],
                  ["XINFO", "GROUPS", k], ["XINFO", "CONSUMERS", k, "g"], ["XPENDING", k, "g"], ["XPENDING", k, "g", "-", "+", 1]):
            out.append(cmd(*c))
    for c in (["XLEN", "nokey"], ["XRANGE", "nokey", "-", "+"], ["XRANGE", "nokey", "-", "+", "COUNT", 0],
              ["XREVRANGE", "nokey", "+", "-"], ["XREAD", "STREAMS", "nokey", "0"], ["XREAD", "STREAMS", "nokey", "$"],
              ["XREAD", "STREAMS", "nokey", "nokey2", "$", "0"]):
        out.append(cmd(*c))
    return out


def shape_reads(b, r, shape, rnd, conns):
    p = make(r, shape)
    if p is None:
        fail("Redis DUMPs the shape '%s'" % shape[0], "", p)
        return
    x = run(b, cmd("RESTORE", "s", 0, p, "REPLACE"))
    if x != (b"+", b"OK"):
        fail("BendKV RESTOREs the shape '%s'" % shape[0], x, "")
        return
    ids = ids_of(r)
    bs = bounds(ids, rnd, 40)
    gs = groups_of(r)
    for (bc, rc) in conns:
        batch(bc, rc, ranges(bs, rnd, 60))
        batch(bc, rc, reads(bs, rnd, run(r, cmd("XLEN", "s")) != (b":", b"0")))
        batch(bc, rc, infos(gs, r), loose=True)
        batch(bc, rc, pendings(gs, r, bs, rnd), loose=True, xpend=True)


def block_alone(b):
    global n
    for c, want in ((cmd("XREAD", "BLOCK", 0, "STREAMS", "s", "$"), b"ERR BendKV does not block on streams yet"),
                    (cmd("XREAD", "BLOCK", 100, "STREAMS", "nokey", "s", "$", "$"), b"ERR BendKV does not block on streams yet")):
        n += 1
        x = run(b, c)
        if x != (b"-", want):
            fail(b" ".join(c), x, "(BendKV alone) -" + want.decode())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bendkv", type=int, default=6380)
    ap.add_argument("--redis", type=int, default=6390)
    ap.add_argument("--seed", type=int, default=1)
    a = ap.parse_args()
    rnd = random.Random(a.seed)
    b, r = Conn(a.bendkv, False), Conn(a.redis, False)
    conns = [(b, r), (Conn(a.bendkv, True), Conn(a.redis, True))]
    conf = {}
    for k in ("rdbcompression", "sanitize-dump-payload", "stream-node-max-entries", "stream-node-max-bytes"):
        conf[k] = flat(run(r, cmd("CONFIG", "GET", k)))[1]
    run(r, cmd("CONFIG", "SET", "rdbcompression", "no"))
    run(r, cmd("CONFIG", "SET", "sanitize-dump-payload", "yes"))
    try:
        for c in (b, r):
            run(c, cmd("FLUSHALL"))
            run(c, cmd("SET", "str", "v"))
            run(c, cmd("HSET", "hash", "f", "v"))
        # a second stream, for XREAD of several keys
        p2 = make(r, ("s2", 100, 4096, [cmd("XADD", "s", "%d-1" % i, "f", i) for i in range(1, 6)]))
        run(r, cmd("RENAME", "s", "s2"))
        run(b, cmd("RESTORE", "s2", 0, p2))
        for shape in shapes(rnd):
            shape_reads(b, r, shape, rnd, conns)
            for (bc, rc) in conns:
                batch(bc, rc, errors(), loose=True, xpend=True)
        block_alone(b)
        t = time.time()
        big = big_shape()
        p = make(r, big)
        run(b, cmd("RESTORE", "s", 0, p, "REPLACE"))
        for (bc, rc) in conns:
            batch(bc, rc, [cmd("XLEN", "s"), cmd("XRANGE", "s", "-", "+", "COUNT", 10), cmd("XREVRANGE", "s", "+", "-", "COUNT", 10),
                           cmd("XINFO", "STREAM", "s"), cmd("XREAD", "COUNT", 5, "STREAMS", "s", "0"),
                           cmd("XRANGE", "s", "-", "+", "COUNT", 1000)])
            batch(bc, rc, [cmd("XPENDING", "s", "g"), cmd("XPENDING", "s", "g", "-", "+", 20)], loose=True, xpend=True)
        print("the stream of 100,000 entries: %.1f s" % (time.time() - t))
        for c in (b, r):
            run(c, cmd("FLUSHALL"))
    finally:
        for k, v in conf.items():
            run(r, cmd("CONFIG", "SET", k, v))
    print("stream reads: %d checks, %d differ" % (n, bad))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
