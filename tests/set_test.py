#!/usr/bin/env python3
"""Sets against Redis: a script of set commands at their edges, sets of
many sizes on both sides of the intset limit (512 integers), sets whose
key's time has passed, then random commands on a few keys (moves and the
operations of several sets among them), replies compared one by one.

An intset keeps its members in numeric order on both servers, and those
replies are compared as they are; a hashtable answers in the order of
each server's own table, so a whole set (SMEMBERS, SINTER, SUNION,
SDIFF) is compared as a set, and SSCAN by the members its whole walk
answers. SRANDMEMBER and SPOP pick at random: their replies are compared
by kind and size, each member checked against the set it was picked
from (distinct where they must be), and the set an SPOP leaves against
the set less the members it answered; then the key is made again on
both servers from BendKV's members, so that the two go on alike. MEMORY
USAGE, an estimate on each server, is compared by kind.

    python3 tests/set_test.py --bendkv 6380 --redis 6390 [--rounds 3000] [--seed 1]
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


def fail(cmd, x, y):
    global bad
    bad += 1
    if bad <= 20:
        print("FAIL: %r: BendKV %r, Redis %r" % (b" ".join(cmd)[:200], str(x)[:300], str(y)[:300]))


def members(c, key):
    rep = run(c, [b"SMEMBERS", key])
    return sorted(v for _, v in rep[1]) if rep[0] == b"*" else []


def encoding(c, key):
    return run(c, [b"OBJECT", b"ENCODING", key])


# a key made again on both servers with BendKV's members
def resync(b, r, key):
    ms = members(b, key)
    for c in (b, r):
        run(c, [b"DEL", key])
        for i in range(0, len(ms), 100):
            run(c, [b"SADD", key] + ms[i:i + 100])


def count_of(cmd):
    if len(cmd) < 3:
        return None
    try:
        return int(cmd[2])
    except ValueError:
        return None


# SPOP: the same kind and size; the members distinct and from the set;
# the set left is the set less them
def spop(b, r, cmd):
    key = cmd[1] if len(cmd) > 1 else b""
    before = members(b, key)
    x, y = run(b, cmd), run(r, cmd)
    if x[0] != y[0] or x[0] in (b"-", b":", b"+"):
        if x != y:
            fail(cmd, x, y)
        return
    if x[0] == b"$":
        if (x[1] is None) != (y[1] is None):
            fail(cmd, x, y)
        got = [] if x[1] is None else [x[1]]
    else:
        if x[1] is None or y[1] is None or len(x[1]) != len(y[1]):
            fail(cmd, x, y)
            resync(b, r, key)
            return
        got = [v for _, v in x[1]]
    if len(set(got)) != len(got) or any(v not in before for v in got):
        fail(cmd, x, "members of %r" % before[:20])
    left = members(b, key)
    if left != sorted(set(before) - set(got)):
        fail(cmd + [b"(left)"], left, "the set less %r" % got[:20])
    resync(b, r, key)


# SRANDMEMBER: the same kind and size; the members from the set, distinct
# for a count that is not negative
def srand(b, r, cmd):
    key = cmd[1] if len(cmd) > 1 else b""
    x, y = run(b, cmd), run(r, cmd)
    if x[0] != y[0] or x[0] in (b"-", b":", b"+"):
        if x != y:
            fail(cmd, x, y)
        return
    have = set(members(b, key))
    if x[0] == b"$":
        if (x[1] is None) != (y[1] is None) or (x[1] is not None and x[1] not in have):
            fail(cmd, x, y)
        return
    if x[1] is None or y[1] is None or len(x[1]) != len(y[1]):
        fail(cmd, x, y)
        return
    got = [v for _, v in x[1]]
    if any(v not in have for v in got) or ((count_of(cmd) or 0) > 0 and len(set(got)) != len(got)):
        fail(cmd, x, "members of %r" % sorted(have)[:20])


# SSCAN from cursor 0 to its end, on each server: the members it answered
def walk(c, cmd):
    cur, seen = b"0", set()
    for _ in range(100000):
        rep = run(c, cmd[:2] + [cur] + cmd[3:])
        if rep[0] != b"*":
            return rep
        cur = rep[1][0][1]
        seen |= {v for _, v in rep[1][1][1]}
        if cur == b"0":
            break
    return (b"*", sorted(seen))


WHOLE = (b"SMEMBERS", b"SINTER", b"SUNION", b"SDIFF")


def same(b, r, cmd):
    global n
    n += 1
    name = cmd[0].upper()
    if name == b"SPOP":
        return spop(b, r, cmd)
    if name == b"SRANDMEMBER":
        return srand(b, r, cmd)
    if name == b"SSCAN" and len(cmd) > 2 and cmd[2] == b"0":
        x, y = walk(b, cmd), walk(r, cmd)
        if x != y:
            fail(cmd, x, y)
        return
    x, y = run(b, cmd), run(r, cmd)
    if name == b"MEMORY":
        if x[0] != y[0] or (x[0] != b":" and x != y):
            fail(cmd, x, y)
        return
    if name in WHOLE and x[0] == y[0] == b"*" and x[1] is not None and y[1] is not None:
        x, y = sorted(x[1]), sorted(y[1])
    if name == b"SCAN" and x[0] == y[0] == b"*":
        x, y = sorted(x[1][1][1]), sorted(y[1][1][1])
    if x != y:
        fail(cmd, x, y)


# a whole set as it is: in order, for an intset
def exact(b, r, key):
    global n
    n += 1
    cmd = [b"SMEMBERS", key]
    x, y = run(b, cmd), run(r, cmd)
    if encoding(r, key) == (b"$", b"intset") and x != y:
        fail(cmd, x, y)


LLONG_MIN = b"-9223372036854775808"
LLONG_MAX = b"9223372036854775807"

SCRIPT = [
    # SADD, SCARD, SISMEMBER, SMISMEMBER, SMEMBERS, SREM
    [b"SADD", b"s"], [b"SADD"], [b"SADD", b"s", b"a"], [b"SADD", b"s", b"b", b"c", b"a", b"b"], [b"sadd", b"s", b"1", b"2"],
    [b"SCARD", b"s"], [b"SCARD", b"nope"], [b"SCARD"], [b"SCARD", b"s", b"x"], [b"SISMEMBER", b"s", b"a"],
    [b"SISMEMBER", b"s", b"zz"], [b"SISMEMBER", b"s", b"1"], [b"SISMEMBER", b"nope", b"a"], [b"SISMEMBER", b"s"],
    [b"SMISMEMBER", b"s", b"a", b"zz", b"1", b"a"], [b"SMISMEMBER", b"nope", b"a", b"b"], [b"SMISMEMBER", b"s"],
    [b"SMEMBERS", b"s"], [b"SMEMBERS", b"nope"], [b"SMEMBERS"], [b"SMEMBERS", b"s", b"x"], [b"OBJECT", b"ENCODING", b"s"],
    [b"SREM", b"s", b"a", b"zz", b"a"], [b"SREM", b"s"], [b"SREM", b"nope", b"a"], [b"SREM", b"s", b"b", b"c", b"1", b"2"],
    [b"EXISTS", b"s"], [b"SREM", b"s", b"a"],
    # intsets: canonical int64s alone, in numeric order; any other member
    # makes a hashtable, which stays one
    [b"SADD", b"i", b"3", b"-1", b"20", b"2"], [b"OBJECT", b"ENCODING", b"i"], [b"SMEMBERS", b"i"],
    [b"SADD", b"i", LLONG_MIN, LLONG_MAX, b"0"], [b"SMEMBERS", b"i"], [b"SISMEMBER", b"i", LLONG_MIN],
    [b"SISMEMBER", b"i", b"03"], [b"SREM", b"i", b"03"], [b"SREM", b"i", b"3", LLONG_MAX], [b"SMEMBERS", b"i"],
    [b"SADD", b"j1", b"01"], [b"OBJECT", b"ENCODING", b"j1"], [b"SADD", b"j2", b"+1"], [b"OBJECT", b"ENCODING", b"j2"],
    [b"SADD", b"j3", b"-0"], [b"OBJECT", b"ENCODING", b"j3"], [b"SADD", b"j4", b"9223372036854775808"],
    [b"OBJECT", b"ENCODING", b"j4"], [b"SADD", b"j5", b" 1"], [b"OBJECT", b"ENCODING", b"j5"],
    [b"SADD", b"j6", b"-9223372036854775809"], [b"OBJECT", b"ENCODING", b"j6"], [b"SADD", b"j7", b""],
    [b"OBJECT", b"ENCODING", b"j7"], [b"SADD", b"i", b"x"], [b"OBJECT", b"ENCODING", b"i"], [b"SREM", b"i", b"x"],
    [b"OBJECT", b"ENCODING", b"i"], [b"SMEMBERS", b"i"],
    # SMOVE
    [b"SADD", b"m1", b"a", b"b", b"1"], [b"SMOVE", b"m1", b"m2", b"a"], [b"SMOVE", b"m1", b"m2", b"zz"],
    [b"SMOVE", b"nope", b"m2", b"a"], [b"SMOVE", b"m1", b"m1", b"b"], [b"SMOVE", b"m1", b"m1", b"zz"],
    [b"SMOVE", b"m1", b"m2", b"1"], [b"OBJECT", b"ENCODING", b"m2"], [b"SMEMBERS", b"m1"], [b"SMEMBERS", b"m2"],
    [b"SMOVE", b"m1", b"m3", b"b"], [b"EXISTS", b"m1"], [b"OBJECT", b"ENCODING", b"m3"], [b"SMOVE", b"m2", b"m4", b"1"],
    [b"OBJECT", b"ENCODING", b"m4"], [b"SMOVE", b"m2"], [b"SMOVE"], [b"SMOVE", b"m2", b"m4", b"a", b"b"],
    [b"SET", b"str", b"v"], [b"SMOVE", b"str", b"m2", b"a"], [b"SMOVE", b"m2", b"str", b"a"], [b"SMOVE", b"m2", b"str", b"zz"],
    [b"SMOVE", b"nope", b"str", b"a"], [b"SMOVE", b"str", b"str", b"a"], [b"SMEMBERS", b"m2"],
    # SINTER, SUNION, SDIFF and their STOREs, SINTERCARD
    [b"SADD", b"a1", b"1", b"2", b"3", b"4", b"a"], [b"SADD", b"a2", b"3", b"4", b"5", b"b", b"a"], [b"SADD", b"a3", b"4", b"a", b"z"],
    [b"SADD", b"n1", b"1", b"2", b"3"], [b"SADD", b"n2", b"2", b"3", b"4"],
    [b"SINTER", b"a1", b"a2"], [b"SINTER", b"a1", b"a2", b"a3"], [b"SINTER", b"n1", b"n2"], [b"SINTER", b"a1", b"nope"],
    [b"SINTER", b"nope", b"a1"], [b"SINTER", b"a1", b"str"], [b"SINTER", b"nope", b"str"], [b"SINTER", b"str", b"nope"],
    [b"SINTER", b"a1"], [b"SINTER"], [b"SUNION", b"a1", b"a2", b"nope"], [b"SUNION", b"n1", b"n2"], [b"SUNION", b"a1", b"str"],
    [b"SUNION", b"nope"], [b"SUNION"], [b"SDIFF", b"a1", b"a2"], [b"SDIFF", b"a1", b"a2", b"a3"], [b"SDIFF", b"n1", b"n2"],
    [b"SDIFF", b"nope", b"a1"], [b"SDIFF", b"a1", b"nope"], [b"SDIFF", b"a1", b"a1"], [b"SDIFF", b"a1", b"a2", b"a1"],
    [b"SDIFF", b"a1", b"str"], [b"SDIFF", b"nope", b"str"], [b"SDIFF"],
    [b"SINTERSTORE", b"d", b"a1", b"a2"], [b"SMEMBERS", b"d"], [b"OBJECT", b"ENCODING", b"d"], [b"SINTERSTORE", b"d", b"n1", b"n2"],
    [b"OBJECT", b"ENCODING", b"d"], [b"SUNIONSTORE", b"d", b"a1", b"a2"], [b"SMEMBERS", b"d"], [b"SDIFFSTORE", b"d", b"a1", b"a2"],
    [b"SMEMBERS", b"d"], [b"SINTERSTORE", b"d", b"a1", b"nope"], [b"EXISTS", b"d"], [b"SDIFFSTORE", b"d", b"a1", b"a1"],
    [b"EXISTS", b"d"], [b"SINTERSTORE", b"a3", b"a3", b"a1"], [b"SMEMBERS", b"a3"], [b"SUNIONSTORE", b"str", b"n1"],
    [b"TYPE", b"str"], [b"SET", b"str", b"v"], [b"SDIFFSTORE", b"d", b"str", b"a1"], [b"SINTERSTORE", b"str", b"nope"],
    [b"EXISTS", b"str"], [b"SET", b"str", b"v"], [b"SINTERSTORE", b"d"], [b"SINTERSTORE"], [b"SUNIONSTORE", b"d", b"nope"],
    [b"SINTERCARD", b"2", b"a1", b"a2"], [b"SINTERCARD", b"2", b"a1", b"a2", b"LIMIT", b"1"],
    [b"SINTERCARD", b"2", b"a1", b"a2", b"limit", b"0"], [b"SINTERCARD", b"2", b"a1", b"a2", b"LIMIT", b"100"],
    [b"SINTERCARD", b"0", b"a1"], [b"SINTERCARD", b"-1", b"a1"], [b"SINTERCARD", b"x", b"a1"], [b"SINTERCARD", b"3", b"a1", b"a2"],
    [b"SINTERCARD", b"2", b"a1", b"a2", b"LIMIT", b"-1"], [b"SINTERCARD", b"2", b"a1", b"a2", b"LIMIT", b"x"],
    [b"SINTERCARD", b"2", b"a1", b"a2", b"FOO", b"1"], [b"SINTERCARD", b"2", b"a1", b"a2", b"LIMIT"],
    [b"SINTERCARD", b"1", b"nope"], [b"SINTERCARD", b"2", b"a1", b"str"], [b"SINTERCARD", b"2", b"nope", b"str"],
    [b"SINTERCARD", b"1"], [b"SINTERCARD"], [b"SINTERCARD", b"1", b"a1", b"LIMIT", b"1", b"LIMIT", b"2"],
    [b"SINTERCARD", b"9223372036854775808", b"a1"],
    # SPOP and SRANDMEMBER: their counts and errors
    [b"SADD", b"p", b"a", b"b", b"c", b"1", b"2"], [b"SPOP", b"nope"], [b"SPOP", b"nope", b"2"], [b"SPOP", b"p", b"0"],
    [b"SPOP", b"p", b"-1"], [b"SPOP", b"p", b"x"], [b"SPOP", b"p", b"1", b"2"], [b"SPOP"], [b"SPOP", b"str"],
    [b"SPOP", b"str", b"2"], [b"SPOP", b"p"], [b"SPOP", b"p", b"2"], [b"SPOP", b"p", b"100"], [b"EXISTS", b"p"],
    [b"SPOP", b"p", LLONG_MAX], [b"SPOP", b"p", b"9223372036854775808"],
    [b"SADD", b"q", b"a", b"b", b"c", b"1", b"2"], [b"SRANDMEMBER", b"nope"], [b"SRANDMEMBER", b"nope", b"3"],
    [b"SRANDMEMBER", b"nope", b"-3"], [b"SRANDMEMBER", b"q", b"0"], [b"SRANDMEMBER", b"q", b"x"], [b"SRANDMEMBER", b"q"],
    [b"SRANDMEMBER", b"q", b"3"], [b"SRANDMEMBER", b"q", b"-3"], [b"SRANDMEMBER", b"q", b"5"], [b"SRANDMEMBER", b"q", b"100"],
    [b"SRANDMEMBER", b"q", b"-100"], [b"SRANDMEMBER", b"q", LLONG_MIN], [b"SRANDMEMBER", b"q", LLONG_MAX],
    [b"SRANDMEMBER", b"q", b"1", b"2"], [b"SRANDMEMBER", b"str"], [b"SRANDMEMBER", b"str", b"2"], [b"SRANDMEMBER"],
    # SSCAN
    [b"SSCAN", b"q", b"0"], [b"SSCAN", b"q", b"0", b"COUNT", b"1"], [b"SSCAN", b"q", b"0", b"MATCH", b"[ab]*"],
    [b"SSCAN", b"i", b"0", b"MATCH", b"*1*", b"COUNT", b"2"], [b"SSCAN", b"q", b"x"], [b"SSCAN", b"q", b"0", b"COUNT", b"0"],
    [b"SSCAN", b"q", b"0", b"COUNT", b"-1"], [b"SSCAN", b"q", b"0", b"COUNT"], [b"SSCAN", b"q", b"0", b"FOO", b"1"],
    [b"SSCAN", b"q", b"0", b"TYPE", b"set"], [b"SSCAN", b"nope", b"0"], [b"SSCAN", b"str", b"0"], [b"SSCAN", b"q"],
    [b"SSCAN"], [b"SSCAN", b"n1", b"-1"], [b"SSCAN", b"q", b"18446744073709551616"],
    # another kind
    [b"SADD", b"str", b"a"], [b"SREM", b"str", b"a"], [b"SCARD", b"str"], [b"SISMEMBER", b"str", b"a"],
    [b"SMISMEMBER", b"str", b"a"], [b"SMEMBERS", b"str"], [b"HSET", b"h", b"f", b"v"], [b"SADD", b"h", b"a"],
    [b"RPUSH", b"l", b"a"], [b"SADD", b"l", b"a"], [b"SINTER", b"l"], [b"SINTERSTORE", b"d2", b"l"], [b"SCARD", b"h"],
    [b"SMOVE", b"q", b"h", b"a"], [b"SMOVE", b"h", b"q", b"a"], [b"TYPE", b"q"],
    # a set read and written as another kind
    [b"SADD", b"k", b"1", b"2"], [b"TYPE", b"k"], [b"GET", b"k"], [b"APPEND", b"k", b"x"], [b"INCR", b"k"],
    [b"STRLEN", b"k"], [b"GETRANGE", b"k", b"0", b"1"], [b"SETRANGE", b"k", b"0", b"x"], [b"GETBIT", b"k", b"0"],
    [b"BITCOUNT", b"k"], [b"HSET", b"k", b"f", b"v"], [b"HGET", b"k", b"f"], [b"LPUSH", b"k", b"a"], [b"LLEN", b"k"],
    [b"GETDEL", b"k"], [b"LCS", b"k", b"str"], [b"BITOP", b"AND", b"d3", b"k"], [b"MSETNX", b"k", b"x"],
    [b"SETNX", b"k", b"x"], [b"EXISTS", b"k"], [b"SCAN", b"0", b"TYPE", b"set", b"COUNT", b"1000"],
    # time, RENAME, COPY, MOVE, SET over it
    [b"EXPIRE", b"k", b"100"], [b"TTL", b"k"], [b"SADD", b"k", b"3"], [b"SREM", b"k", b"1"], [b"TTL", b"k"],
    [b"SMOVE", b"k", b"k9", b"2"], [b"TTL", b"k"], [b"TTL", b"k9"], [b"SINTERSTORE", b"k9", b"k"], [b"TTL", b"k9"],
    [b"PERSIST", b"k"], [b"TTL", b"k"], [b"RENAME", b"k", b"k2"], [b"SMEMBERS", b"k2"], [b"COPY", b"k2", b"k3"],
    [b"SMEMBERS", b"k3"], [b"SADD", b"k3", b"9"], [b"SMEMBERS", b"k2"], [b"MOVE", b"k3", b"1"], [b"SELECT", b"1"],
    [b"SMEMBERS", b"k3"], [b"SMOVE", b"k3", b"k4", b"9"], [b"SELECT", b"0"], [b"SET", b"k2", b"x"], [b"TYPE", b"k2"],
    [b"SADD", b"k2", b"a"], [b"DEL", b"k2"], [b"SADD", b"k2", b"a"], [b"TYPE", b"k2"], [b"MEMORY", b"USAGE", b"k2"],
    [b"MEMORY", b"USAGE", b"i", b"SAMPLES", b"0"],
    # the bytes of members
    [b"SADD", b"\x00k", b"\x00", b"\r\n", b"", b"\xff\xfe", b"\x00"], [b"SMEMBERS", b"\x00k"], [b"SISMEMBER", b"\x00k", b""],
    [b"SMISMEMBER", b"\x00k", b"\r\n", b"\r"], [b"SREM", b"\x00k", b"\r\n"], [b"SMEMBERS", b"\x00k"], [b"SCARD", b"\x00k"],
]


def adds(key, items):
    return [[b"SADD", key] + items[i:i + 100] for i in range(0, len(items), 100)]


# sets of many sizes, of integers (an intset up to 512 of them) and of
# words, made in calls of a hundred members, then read and written
def sizes(b, r):
    for size in (1, 100, 511, 512, 513, 1000, 20000):
        rng = random.Random(size)
        ints = [b"%d" % x for x in rng.sample(range(-10**6, 10**6), size)]
        words = [b"w%d" % i for i in range(size)]
        ki, kw = b"zi%d" % size, b"zw%d" % size
        for key, items in ((ki, ints), (kw, words)):
            for cmd in adds(key, items):
                same(b, r, cmd)
        h = items_half = ints[size // 2]
        for cmd in ([b"OBJECT", b"ENCODING", ki], [b"OBJECT", b"ENCODING", kw], [b"SCARD", ki], [b"SCARD", kw],
                    [b"SISMEMBER", ki, h], [b"SISMEMBER", ki, b"x"], [b"SISMEMBER", kw, b"w1"],
                    [b"SMISMEMBER", ki, ints[0], b"7777777", ints[-1]], [b"SRANDMEMBER", ki], [b"SRANDMEMBER", kw, b"5"],
                    [b"SRANDMEMBER", ki, b"-7"], [b"SRANDMEMBER", kw, b"%d" % size], [b"SRANDMEMBER", ki, b"%d" % (size + 5)],
                    [b"SRANDMEMBER", kw, b"-%d" % (size + 5)], [b"SSCAN", ki, b"0", b"COUNT", b"10"],
                    [b"SSCAN", kw, b"0", b"MATCH", b"w1*"], [b"SINTERCARD", b"2", ki, kw], [b"SINTERCARD", b"2", ki, ki, b"LIMIT", b"3"],
                    [b"SUNIONSTORE", ki + b"u", ki, kw], [b"SCARD", ki + b"u"], [b"OBJECT", b"ENCODING", ki + b"u"],
                    [b"SINTERSTORE", ki + b"n", ki, ki], [b"OBJECT", b"ENCODING", ki + b"n"], [b"SDIFFSTORE", kw + b"d", kw, ki],
                    [b"SCARD", kw + b"d"], [b"SMOVE", ki, kw, h], [b"SMOVE", kw, ki, b"w0"], [b"OBJECT", b"ENCODING", ki],
                    [b"SREM", ki, b"w0"], [b"OBJECT", b"ENCODING", ki], [b"SPOP", ki], [b"SPOP", kw, b"3"],
                    [b"SREM", kw] + words[:size // 2], [b"SCARD", kw], [b"OBJECT", b"ENCODING", kw],
                    [b"MEMORY", b"USAGE", ki], [b"MEMORY", b"USAGE", kw]):
            same(b, r, cmd)
        if size <= 1000:
            for key in (ki, kw, ki + b"u", ki + b"n"):
                same(b, r, [b"SMEMBERS", key])
                exact(b, r, key)
            same(b, r, [b"SINTER", ki, ki + b"n"])
            same(b, r, [b"SDIFF", ki + b"u", kw])
    # an intset grown past 512 by one member at a time, and taken back
    for i in range(520):
        same(b, r, [b"SADD", b"grow", b"%d" % (i * 7)])
        if i in (510, 511, 512, 513):
            same(b, r, [b"OBJECT", b"ENCODING", b"grow"])
    for i in range(515):
        same(b, r, [b"SREM", b"grow", b"%d" % (i * 7)])
    same(b, r, [b"OBJECT", b"ENCODING", b"grow"])
    same(b, r, [b"SMEMBERS", b"grow"])


# a set whose time passed: a read finds nothing, a write makes it anew,
# a move or a STORE takes it as not there, as a source or a destination
def expired(b, r):
    for c in (b, r):
        for cmd in ([b"SADD", b"x1", b"a", b"b", b"c"], [b"PEXPIRE", b"x1", b"50"], [b"SET", b"x2", b"str", b"PX", b"50"],
                    [b"SADD", b"x3", b"a", b"q"], [b"PEXPIRE", b"x3", b"50"], [b"SADD", b"x4", b"a", b"b"],
                    [b"PEXPIRE", b"x4", b"50"], [b"SADD", b"x5", b"q"], [b"PEXPIRE", b"x5", b"50"],
                    [b"HSET", b"x6", b"f", b"v"], [b"PEXPIRE", b"x6", b"50"], [b"SADD", b"x7", b"a", b"z"],
                    [b"PEXPIRE", b"x7", b"50"], [b"SADD", b"x8", b"1"], [b"PEXPIRE", b"x8", b"50"],
                    [b"RPUSH", b"x9", b"a"], [b"PEXPIRE", b"x9", b"50"], [b"SADD", b"em", b"a", b"b", b"c", b"1"]):
            run(c, cmd)
    time.sleep(0.2)
    for cmd in ([b"SCARD", b"x1"], [b"SMEMBERS", b"x1"], [b"SISMEMBER", b"x1", b"a"], [b"SADD", b"x1", b"n"],
                [b"SMEMBERS", b"x1"], [b"TTL", b"x1"], [b"SADD", b"x2", b"a"], [b"TYPE", b"x2"], [b"SMEMBERS", b"x2"],
                [b"SMOVE", b"em", b"x3", b"a"], [b"SMEMBERS", b"x3"], [b"TTL", b"x3"], [b"SMOVE", b"x4", b"em", b"a"],
                [b"SUNIONSTORE", b"x5", b"em"], [b"SMEMBERS", b"x5"], [b"TTL", b"x5"], [b"SMOVE", b"em", b"x6", b"b"],
                [b"TYPE", b"x6"], [b"SMEMBERS", b"x6"], [b"SINTER", b"em", b"x7"], [b"SUNION", b"em", b"x7"],
                [b"SDIFF", b"x7", b"em"], [b"SDIFF", b"em", b"x7"], [b"SINTERCARD", b"2", b"em", b"x7"], [b"SPOP", b"x8"],
                [b"SRANDMEMBER", b"x8", b"2"], [b"SREM", b"x8", b"1"], [b"EXISTS", b"x8"], [b"SADD", b"x9", b"a"],
                [b"TYPE", b"x9"], [b"SINTERSTORE", b"x7", b"em", b"x6"], [b"SMEMBERS", b"x7"], [b"SMEMBERS", b"em"]):
        same(b, r, cmd)


KEYS = [b"r1", b"r2", b"r3", b"rs"]
MEMS = [b"1", b"2", b"3", b"-4", b"10", b"a", b"b", b""]


def rand_cmd(r):
    key = r.choice(KEYS)
    ks = lambda: [r.choice(KEYS) for _ in range(r.randint(1, 3))]
    m = lambda: r.choice(MEMS) if r.random() < 0.95 else b"x" * r.randint(1, 80)
    num = lambda: r.choice([b"0", b"1", b"2", b"3", b"-1", b"-2", b"5", b"-5", b"100", b"-100", b"x"])
    k = r.random()
    if k < 0.2:
        return [b"SADD", key] + [m() for _ in range(r.randint(1, 4))]
    if k < 0.22:
        return [b"SADD", key] + [b"%d" % r.randint(-1000, 1000) for _ in range(r.randint(50, 200))]
    if k < 0.32:
        return [b"SREM", key] + [m() for _ in range(r.randint(1, 4))]
    if k < 0.37:
        return [b"SPOP", key] + ([num()] if r.random() < 0.6 else [])
    if k < 0.42:
        return [b"SRANDMEMBER", key] + ([num()] if r.random() < 0.7 else [])
    if k < 0.5:
        return [b"SMOVE", key, r.choice(KEYS), m()]
    if k < 0.58:
        return [r.choice([b"SINTER", b"SUNION", b"SDIFF"])] + ks()
    if k < 0.66:
        return [r.choice([b"SINTERSTORE", b"SUNIONSTORE", b"SDIFFSTORE"]), r.choice(KEYS)] + ks()
    if k < 0.7:
        x = ks()
        return [b"SINTERCARD", b"%d" % len(x)] + x + ([b"LIMIT", num()] if r.random() < 0.5 else [])
    if k < 0.73:
        return [r.choice([b"SET", b"DEL", b"EXPIRE"]), key] + ([b"str"] if r.random() < 0.5 else [b"1000"])
    if k < 0.76:
        return [b"SSCAN", key, b"0"] + r.choice([[], [b"COUNT", b"2"], [b"MATCH", b"*1*"], [b"MATCH", b"[ab]"]])
    return r.choice([[b"SCARD", key], [b"SISMEMBER", key, m()], [b"SMISMEMBER", key, m(), m()], [b"SMEMBERS", key],
                     [b"TYPE", key], [b"EXISTS", key], [b"TTL", key], [b"OBJECT", b"ENCODING", key]])


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
    for key in KEYS:
        same(b, rd, [b"SMEMBERS", key])
        exact(b, rd, key)
    for c in (b, rd):
        run(c, [b"FLUSHALL"])
    if bad:
        sys.exit("FAIL: %d of %d" % (bad, n))
    print("OK: %d set commands, each answered as Redis answers it" % n)


if __name__ == "__main__":
    main()
