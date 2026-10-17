#!/usr/bin/env python3
"""PFADD, PFCOUNT, PFMERGE, PFDEBUG and PFSELFTEST against Redis: the
cases of Redis's unit/hyperloglog and of hyperloglog.c (the sparse
opcodes split and merged, the turn to dense, the count kept in the value
and when it is made again, the union of several, the errors and their
order), values made by hand (registers past 32, every register at its
most, opcodes that do not cover 16384 registers or end within an XZERO),
values corrupted at random bytes, then random sequences of the commands
over a few keys. Every reply is compared, and after each write the
value itself (GET), byte for byte.

But for a value whose opcodes end within an XZERO (docs/UPSTREAM.md, bug
6): Redis reads the byte after the value's end as the XZERO's second, and
what lies there turns on how Redis grew the value's buffer, by the sizes
of jemalloc's classes. BendKV reads the byte as 0 when a command starts,
and as the byte a split it made wrote there in the same command. A
command that reads such a value and is answered otherwise, or leaves
other values, is counted, not failed, and both servers go on from Redis's
values; BendKV's reading of one such value is checked alone.

    python3 tests/hll_test.py --bendkv 6380 --redis 6390 [--rounds 3000] [--seed 1]
"""
import argparse
import random
import struct
import sys

from diff_test import Conn

bad = 0
n = 0


def run(c, cmd):
    c.send([cmd])
    return c.reply()


# while a command reads a value cut within an XZERO, its differences
# (held: bug 6), and the commands that had some
held = None
cuts = 0


def fail(cmd, x, y):
    global bad
    if held is not None:
        held.append(cmd)
        return
    bad += 1
    if bad <= 20:
        print("FAIL: %r: BendKV %r, Redis %r" % (b" ".join(cmd)[:200], str(x)[:300], str(y)[:300]))


def same(b, r, cmd):
    global n
    n += 1
    x, y = run(b, cmd), run(r, cmd)
    if x != y:
        fail(cmd, x, y)
    return y


# a time to live, as far as two servers that run apart agree on it: none,
# no key, or about how long
def ttl_of(rep):
    v = int(rep[1])
    return v if v < 0 else (v + 500) // 1000


# whether v (a GET's reply) is a sparse value whose opcodes end within an
# XZERO: its second byte past the value's end
def cut_xzero(rep):
    v = rep[1] if isinstance(rep, tuple) else None
    if not isinstance(v, bytes) or len(v) < 17 or v[:4] != b"HYLL" or v[4] != 1:
        return False
    i = 16
    while i < len(v):
        if v[i] & 0xC0 == 0x40:
            if i + 1 == len(v):
                return True
            i += 2
        else:
            i += 1
    return False


# the keys a command of the test reads
def reads(cmd):
    if cmd[0] in (b"PFCOUNT", b"PFMERGE"):
        return list(cmd[1:])
    return list(cmd[2:3] if cmd[0] == b"PFDEBUG" else cmd[1:2])


# both servers set to Redis's value of k, its time to live too
def resync(b, r, k):
    v, t = run(r, [b"GET", k]), int(run(r, [b"PTTL", k])[1])
    if v[0] == b"-":
        return
    both(b, r, [b"DEL", k])
    if v[1] is not None:
        both(b, r, [b"SET", k, v[1]])
        if t > 0:
            both(b, r, [b"PEXPIRE", k, str(t).encode()])


# a write, then the values of the keys it may have changed read back
def write(b, r, cmd, keys):
    global n, held, cuts
    rs = reads(cmd)
    if any(cut_xzero(run(r, [b"GET", k])) for k in rs):
        held = []
    same(b, r, cmd)
    for k in keys:
        same(b, r, [b"GET", k])
        n += 1
        x, y = run(b, [b"PTTL", k]), run(r, [b"PTTL", k])
        if ttl_of(x) != ttl_of(y):
            fail([b"PTTL", k], x, y)
    if held:
        cuts += 1
        for k in rs + keys:
            resync(b, r, k)
    held = None


# BendKV alone: a value cut within an XZERO (bug 6), whose first set splits
# the XZERO and writes its last byte past the value's end, and the second
# reads it there, in the same PFADD (7.0.15's reading; 7.2.16 writes a NUL
# there first, as it grows the value's buffer)
def bug6(b):
    global n
    n += 1
    v = hll(1, ops=b"\x00" * 23 + b"\x7f", card=b"\x00" * 7 + b"\x80")
    run(b, [b"SET", b"cut6", v])
    run(b, [b"PFADD", b"cut6", b"a3", b"b3"])
    got = run(b, [b"GET", b"cut6"])
    want = v[:16] + b"\x00" * 23 + bytes.fromhex("4827846b4f884b")
    run(b, [b"DEL", b"cut6"])
    if got != (b"$", want):
        fail([b"PFADD", b"cut6", b"a3", b"b3"], got, (b"$", want))


def both(b, r, cmd):
    run(b, cmd)
    run(r, cmd)


def hll(enc, regs=None, ops=b"", card=b"\x00" * 8):
    """a value made by hand: dense with registers regs, or sparse with the
    opcodes ops"""
    head = b"HYLL" + bytes([enc]) + b"\x00\x00\x00" + card
    if enc == 0:
        bits = 0
        for i, v in enumerate(regs):
            bits |= (v & 63) << (6 * i)
        return head + bits.to_bytes(12288, "little")
    return head + ops


def xzero(n):
    return bytes([((n - 1) >> 8) | 0x40, (n - 1) & 0xFF])


def zero(n):
    return bytes([n - 1])


def val(v, n):
    return bytes([0x80 | ((v - 1) << 2) | (n - 1)])


def script(b, r):
    k = b"hll"
    both(b, r, [b"DEL", k, b"h1", b"h2", b"h3", b"d", b"s", b"x", b"l"])
    same(b, r, [b"PFSELFTEST"])
    # unit/hyperloglog
    write(b, r, [b"PFADD", k], [k])
    same(b, r, [b"EXISTS", k])
    write(b, r, [b"PFCOUNT", k], [k])
    write(b, r, [b"PFADD", k, b"a", b"b", b"c"], [k])
    write(b, r, [b"PFADD", k, b"a", b"b", b"c"], [k])
    write(b, r, [b"PFADD", k, b""], [k])
    both(b, r, [b"DEL", k])
    write(b, r, [b"PFADD", k, b"1", b"2", b"3", b"4", b"5"], [k])
    write(b, r, [b"PFCOUNT", k], [k])
    write(b, r, [b"PFCOUNT", k], [k])
    write(b, r, [b"PFADD", k, b"6", b"7", b"8", b"8", b"9", b"10"], [k])
    write(b, r, [b"PFCOUNT", k], [k])
    same(b, r, [b"GETRANGE", k, b"15", b"15"])
    # from sparse to dense, a hundred at a time
    both(b, r, [b"DEL", k])
    rnd = random.Random(7)
    for i in range(40):
        els = [("%.17f" % rnd.random()).encode() for _ in range(100)]
        write(b, r, [b"PFADD", k] + els, [k])
        write(b, r, [b"PFCOUNT", k], [k])
        same(b, r, [b"PFDEBUG", b"ENCODING", k])
    same(b, r, [b"PFDEBUG", b"GETREG", k])
    same(b, r, [b"STRLEN", k])
    # sparse and dense agree
    for x in range(30):
        both(b, r, [b"DEL", b"h1", b"h2"])
        els = [("%.17f" % rnd.random()).encode() for _ in range(rnd.randrange(100))]
        write(b, r, [b"PFADD", b"h2"], [b"h2"])
        write(b, r, [b"PFDEBUG", b"TODENSE", b"h2"], [b"h2"])
        write(b, r, [b"PFADD", b"h1"] + els, [b"h1"])
        write(b, r, [b"PFADD", b"h2"] + els, [b"h2"])
        same(b, r, [b"PFDEBUG", b"ENCODING", b"h1"])
        same(b, r, [b"PFDEBUG", b"DECODE", b"h1"])
        write(b, r, [b"PFCOUNT", b"h1"], [b"h1"])
        write(b, r, [b"PFCOUNT", b"h2"], [b"h2"])
    # corrupted
    both(b, r, [b"DEL", k])
    write(b, r, [b"PFADD", k, b"a", b"b", b"c"], [k])
    both(b, r, [b"APPEND", k, b"hello"])
    write(b, r, [b"PFCOUNT", k], [k])
    write(b, r, [b"PFADD", k, b"zz"], [k])
    for off, byte in [(0, b"0123"), (4, b"x"), (4, b"\x00")]:
        both(b, r, [b"DEL", k])
        write(b, r, [b"PFADD", k, b"a", b"b", b"c"], [k])
        both(b, r, [b"SETRANGE", k, str(off).encode(), byte])
        write(b, r, [b"PFCOUNT", k], [k])
        write(b, r, [b"PFADD", k, b"q"], [k])
        write(b, r, [b"PFMERGE", b"x", k], [b"x", k])
        same(b, r, [b"PFCOUNT", k, b"x"])
        write(b, r, [b"PFDEBUG", b"GETREG", k], [k])
    # the type checks
    both(b, r, [b"SET", b"foo", b"bar"])
    both(b, r, [b"RPUSH", b"l", b"a"])
    for c in ([b"PFADD", b"foo", b"1"], [b"PFCOUNT", b"foo"], [b"PFMERGE", b"bar", b"foo"],
              [b"PFMERGE", b"foo", b"bar"], [b"PFADD", b"l", b"1"], [b"PFCOUNT", b"l"],
              [b"PFCOUNT", b"l", b"foo"], [b"PFCOUNT", b"foo", b"l"], [b"PFMERGE", b"l"],
              [b"PFDEBUG", b"GETREG", b"l"], [b"PFDEBUG", b"GETREG", b"foo"],
              [b"PFDEBUG", b"GETREG", b"nokey"], [b"PFDEBUG", b"nosuch", b"nokey"],
              [b"PFDEBUG", b"nosuch", b"foo"]):
        write(b, r, c, [c[1], c[-1]])
    # the union
    both(b, r, [b"DEL", b"h", b"h1", b"h2", b"h3"])
    write(b, r, [b"PFADD", b"h1", b"a", b"b", b"c"], [b"h1"])
    write(b, r, [b"PFADD", b"h2", b"b", b"c", b"d"], [b"h2"])
    write(b, r, [b"PFADD", b"h3", b"c", b"d", b"e"], [b"h3"])
    write(b, r, [b"PFMERGE", b"h", b"h1", b"h2", b"h3"], [b"h"])
    write(b, r, [b"PFCOUNT", b"h"], [b"h"])
    same(b, r, [b"PFCOUNT", b"h1", b"h2", b"h3", b"nokey"])
    both(b, r, [b"DEL", b"h1", b"h2", b"h3"])
    for x in range(1, 2000):
        both(b, r, [b"PFADD", b"h1", b"foo-%d" % x])
        both(b, r, [b"PFADD", b"h2", b"bar-%d" % x])
        both(b, r, [b"PFADD", b"h3", b"zap-%d" % x])
        if x % 97 == 0:
            same(b, r, [b"PFCOUNT", b"h1", b"h2", b"h3"])
            for kk in (b"h1", b"h2", b"h3"):
                same(b, r, [b"GET", kk])
    write(b, r, [b"PFMERGE", b"h", b"h1", b"h2"], [b"h"])
    write(b, r, [b"PFMERGE", b"h1", b"h1"], [b"h1"])
    write(b, r, [b"PFMERGE", b"new"], [b"new"])
    write(b, r, [b"PFMERGE", b"new2", b"nokey"], [b"new2"])
    # a time to live kept
    both(b, r, [b"DEL", b"t"])
    write(b, r, [b"PFADD", b"t", b"a"], [b"t"])
    both(b, r, [b"PEXPIRE", b"t", b"100000"])
    write(b, r, [b"PFADD", b"t", b"b"], [b"t"])
    write(b, r, [b"PFCOUNT", b"t"], [b"t"])
    write(b, r, [b"PFMERGE", b"t", b"h1"], [b"t"])
    write(b, r, [b"PFDEBUG", b"TODENSE", b"t"], [b"t"])
    # PFDEBUG
    both(b, r, [b"DEL", b"s"])
    write(b, r, [b"PFADD", b"s", b"1", b"2", b"3"], [b"s"])
    for sub in (b"ENCODING", b"encoding", b"DeCoDe", b"getreg", b"TODENSE", b"todense",
                b"decode", b"encoding", b"x", b"get\x00reg", b"a\r\nb"):
        write(b, r, [b"PFDEBUG", sub, b"s"], [b"s"])
    for c in ([b"PFDEBUG"], [b"PFDEBUG", b"GETREG"], [b"PFDEBUG", b"GETREG", b"s", b"x"],
              [b"PFADD"], [b"PFCOUNT"], [b"PFMERGE"], [b"PFSELFTEST", b"x"]):
        same(b, r, c)
    # values made by hand
    made = [
        hll(1, ops=xzero(16384)),
        hll(1, ops=xzero(16384) + val(5, 1)),
        hll(1, ops=xzero(16383)),
        hll(1, ops=xzero(16380) + bytes([0x40])),
        hll(1, ops=xzero(16000) + zero(64) + val(32, 4) + val(32, 4) + xzero(316)),
        hll(1, ops=b"".join(zero(1) for _ in range(16384))),
        hll(1, ops=b"".join(val(3, 4) for _ in range(4096))),
        hll(1, ops=b"".join(val(1 + i % 32, 1) for i in range(16384))),
        hll(1, ops=b""),
        hll(1, ops=xzero(8000) + xzero(8384), card=b"\x07\x00\x00\x00\x00\x00\x00\x00"),
        hll(1, ops=xzero(16384), card=b"\xff\xff\xff\xff\xff\xff\xff\x7f"),
        hll(0, regs=[0] * 16384),
        hll(0, regs=[51] * 16384),
        hll(0, regs=[63] * 16384),
        hll(0, regs=[50] * 16384),
        hll(0, regs=[i % 64 for i in range(16384)]),
        hll(0, regs=[51 if i % 7 == 0 else i % 30 for i in range(16384)]),
        hll(0, regs=[51 if i < 9000 else 0 for i in range(16384)]),
        hll(0, regs=[40 + i % 12 for i in range(16384)]),
        hll(0, regs=[1] * 16384),
        hll(0, regs=[0] * 16383 + [20], card=b"\x01\x02\x03\x04\x05\x06\x07\x08"),
    ]
    for v in made:
        for c in ([b"PFCOUNT", b"m"], [b"PFADD", b"m", b"a", b"b", b"c", b"d", b"e"],
                  [b"PFDEBUG", b"DECODE", b"m"], [b"PFDEBUG", b"GETREG", b"m"],
                  [b"PFDEBUG", b"TODENSE", b"m"], [b"PFCOUNT", b"m", b"s"],
                  [b"PFMERGE", b"m2", b"m"], [b"PFMERGE", b"m", b"s"], [b"PFCOUNT", b"m2"]):
            both(b, r, [b"DEL", b"m", b"m2"])
            both(b, r, [b"SET", b"m", v])
            write(b, r, c, [b"m", b"m2"])
    # opcodes that end within an XZERO: Redis reads the byte past the
    # string's end as its second (the NUL of its sds string, as a command
    # starts); a set that splits it writes the last byte of the opcodes it
    # makes there, which the sets after it in the same PFADD or PFMERGE
    # read (c0 and c12 split it in turn, the second where that byte counts),
    # while the value's buffer has room (docs/UPSTREAM.md, bug 6)
    cut = hll(1, ops=b"\x7f", card=b"\x00" * 7 + b"\x80")
    for els in ([b"c0", b"c12"], [b"c0", b"c14"], [b"c0", b"c26"], [b"c%d" % i for i in range(40)]):
        both(b, r, [b"DEL", b"m"])
        both(b, r, [b"SET", b"m", cut])
        write(b, r, [b"PFADD", b"m"] + els, [b"m"])
    both(b, r, [b"DEL", b"m", b"m2"])
    both(b, r, [b"PFADD", b"m2"] + [b"c%d" % i for i in range(40)])
    for ops in (xzero(255) + b"\x7f", xzero(16000) + bytes([0x41])):
        both(b, r, [b"SET", b"m", hll(1, ops=ops)])
        write(b, r, [b"PFCOUNT", b"m"], [b"m"])
        both(b, r, [b"SET", b"m", hll(1, ops=ops)])
        write(b, r, [b"PFMERGE", b"m", b"m2"], [b"m"])
    both(b, r, [b"DEL", b"m", b"m2"])
    # a sparse value at hll-sparse-max-bytes's edge
    both(b, r, [b"DEL", b"e"])
    for i in range(2500):
        both(b, r, [b"PFADD", b"e", b"el%d" % i])
        if i > 1000 and i % 10 == 0:
            same(b, r, [b"GET", b"e"])


def fuzz(b, r, rnd, rounds):
    k = b"hll"
    for j in range(rounds):
        both(b, r, [b"DEL", k])
        els = [("%.17f" % rnd.random()).encode() for _ in range(rnd.randrange(3000))]
        for i in range(0, len(els), 500):
            both(b, r, [b"PFADD", k] + els[i:i + 500])
        same(b, r, [b"GET", k])
        for i in range(5):
            ln = run(r, [b"STRLEN", k])[1]
            pos = rnd.randrange(int(ln))
            byte = bytes([rnd.randrange(256)])
            both(b, r, [b"SETRANGE", k, str(pos).encode(), byte])
            if rnd.random() < 0.5:
                break
        c = rnd.choice([[b"PFCOUNT", k], [b"PFADD", k, b"x", b"y", b"z"], [b"PFADD", k] + els[:20],
                        [b"PFDEBUG", b"GETREG", k], [b"PFDEBUG", b"DECODE", k],
                        [b"PFDEBUG", b"TODENSE", k], [b"PFMERGE", b"x", k], [b"PFCOUNT", k, b"x"]])
        write(b, r, c, [k, b"x"])


def rand_el(rnd):
    w = rnd.random()
    if w < 0.6:
        return b"e%d" % rnd.randrange(5000)
    if w < 0.9:
        return bytes(rnd.randrange(256) for _ in range(rnd.randrange(20)))
    return bytes(rnd.randrange(256) for _ in range(rnd.randrange(200)))


def random_ops(b, r, rnd, rounds):
    keys = [b"r%d" % i for i in range(4)] + [b"rs"]
    both(b, r, [b"DEL"] + keys)
    both(b, r, [b"SET", b"rs", b"plain"])
    for j in range(rounds):
        w = rnd.random()
        k = rnd.choice(keys[:4])
        if w < 0.5:
            cmd = [b"PFADD", k] + [rand_el(rnd) for _ in range(rnd.choice([0, 1, 1, 2, 5, 30, 200]))]
        elif w < 0.65:
            cmd = [b"PFCOUNT", k]
        elif w < 0.75:
            cmd = [b"PFCOUNT"] + rnd.sample(keys, rnd.randrange(1, 4))
        elif w < 0.85:
            cmd = [b"PFMERGE", k] + rnd.sample(keys, rnd.randrange(0, 3))
        elif w < 0.9:
            cmd = [b"PFDEBUG", rnd.choice([b"TODENSE", b"ENCODING", b"DECODE"]), k]
        elif w < 0.93:
            cmd = [b"DEL", k]
        elif w < 0.96:
            cmd = [b"PEXPIRE", k, b"100000"]
        else:
            cmd = [b"SETRANGE", k, str(rnd.randrange(16, 40)).encode(), bytes([rnd.randrange(256)])]
        write(b, r, cmd, [k] if cmd[0] != b"PFMERGE" else [cmd[1]])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bendkv", type=int, default=6380)
    ap.add_argument("--redis", type=int, default=6390)
    ap.add_argument("--rounds", type=int, default=3000)
    ap.add_argument("--seed", type=int, default=1)
    a = ap.parse_args()
    rnd = random.Random(a.seed)
    for resp3 in (False, True):
        b, r = Conn(a.bendkv, resp3), Conn(a.redis, resp3)
        both(b, r, [b"FLUSHALL"])
        script(b, r)
        bug6(b)
        if not resp3:
            fuzz(b, r, rnd, a.rounds // 10)
            random_ops(b, r, rnd, a.rounds)
        else:
            random_ops(b, r, rnd, a.rounds // 5)
    print("hll: %d commands, %d differ; %d on values cut within an XZERO answered otherwise"
          " (docs/UPSTREAM.md, bug 6)" % (n, bad, cuts))
    sys.exit(1 if bad else 0)


main()
