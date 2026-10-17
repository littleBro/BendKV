#!/usr/bin/env python3
"""Lists against Redis: a script of list commands at their edges, lists
of many sizes, lists whose key's time has passed, then random commands
on a few keys (moves between them among them), replies compared one by
one. A list keeps its order on both servers, so every reply is compared
as it is, but MEMORY USAGE, an estimate on each server, which is
compared by kind (a number, a nil, an error), and a whole SCAN, whose
keys each server lists in the order of its own table: compared as a
set. BendKV keeps a list in pieces of up to 2,048 bytes: lists of long
elements grown, read, set (a piece made longer than a buffer is dealt
again), trimmed and emptied from either end, each dumped by BendKV and
restored in Redis; searched (LPOS), written in the middle (LINSERT) and
taken from (LREM) across their pieces, from either end; then random
commands on lists of long elements. Redis 7.2 holds a small list as a
listpack and a larger one as a quicklist of nodes: each turn from one to
the other, and the nodes each write leaves (a push at either end, a pop,
LSET, LINSERT into a node, next to it or splitting it, LREM, LTRIM, a
move, a payload read), are checked by OBJECT ENCODING and by DUMP, its
payload compared byte for byte (Redis runs with rdbcompression no), as
the random commands are.

    python3 tests/list_test.py --bendkv 6380 --redis 6390 [--rounds 3000] [--seed 1]
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


# Where BendKV differs (README, Lists): an LSET of an index the list does
# not have and an LINSERT whose pivot is not there leave the list as it
# was, where Redis has already made a listpack a quicklist when the element
# would take it past 8 KB; and LMOVE counts an integer it takes from a
# quicklist by its length, and checks a list moved onto itself after the
# pop. Right after such a command, a list whose encoding parted from
# Redis's is followed apart: its OBJECT ENCODING and DUMP are not compared
# until they meet again (both nil when the key goes), and every other reply
# is.
apart = set()
parted = 0


LP, QL = (b"$", b"listpack"), (b"$", b"quicklist")


# key k parted from Redis's as BendKV and Redis hold it: (BendKV's, Redis's)
def part(b, r, k, way):
    global parted
    x, y = run(b, [b"OBJECT", b"ENCODING", k]), run(r, [b"OBJECT", b"ENCODING", k])
    if (x, y) == way and k not in apart:
        apart.add(k)
        parted += 1


def ints(x):
    return x[0] == b"$" and x[1] is not None and (x[1] == b"0" or (x[1].lstrip(b"-")[:1] in b"123456789" and x[1].lstrip(b"-").isdigit()))


def same(b, r, cmd):
    global n
    n += 1
    x, y = run(b, cmd), run(r, cmd)
    name = cmd[0].upper()
    if name == b"MEMORY":
        if x[0] != y[0] or (x[0] != b":" and x != y):
            fail(cmd, x, y)
        return
    if name == b"SCAN" and x[0] == y[0] == b"*":
        x, y = sorted(x[1][1][1]), sorted(y[1][1][1])
    key = cmd[2] if name == b"OBJECT" and len(cmd) > 2 else (cmd[1] if len(cmd) > 1 else None)
    if name in (b"OBJECT", b"DUMP") and key in apart:
        if x == y and name == b"OBJECT":
            d1, d2 = run(b, [b"DUMP", key]), run(r, [b"DUMP", key])
            if d1 == d2:
                apart.discard(key)
        return
    if x != y:
        fail(cmd, x, y)
    elif (name == b"LSET" and x[0] == b"-") or (name == b"LINSERT" and x == (b":", b"-1")):
        part(b, r, cmd[1], (LP, QL))
    elif name in (b"LMOVE", b"RPOPLPUSH") and len(cmd) > 2:
        if cmd[1] == cmd[2]:
            part(b, r, cmd[1], (LP, QL))
        elif ints(x):
            part(b, r, cmd[2], (QL, LP))


LLONG_MIN = b"-9223372036854775808"
LLONG_MAX = b"9223372036854775807"

SCRIPT = [
    # pushes, LLEN, LRANGE, LINDEX
    [b"LPUSH", b"l"], [b"RPUSH", b"l"], [b"LPUSH", b"l", b"a"], [b"RPUSH", b"l", b"b", b"c"],
    [b"LPUSH", b"l", b"x", b"y"], [b"LRANGE", b"l", b"0", b"-1"], [b"LLEN", b"l"], [b"LLEN", b"nope"], [b"LLEN"],
    [b"LPUSHX", b"nope", b"a"], [b"RPUSHX", b"nope", b"a", b"b"], [b"LPUSHX", b"l", b"p"], [b"RPUSHX", b"l", b"q", b"r"],
    [b"LPUSHX", b"l"], [b"RPUSHX"], [b"EXISTS", b"nope"], [b"LINDEX", b"l", b"0"], [b"LINDEX", b"l", b"-1"],
    [b"LINDEX", b"l", b"100"], [b"LINDEX", b"l", b"-100"], [b"LINDEX", b"l", b"x"], [b"LINDEX", b"l", b"1.5"],
    [b"LINDEX", b"l", LLONG_MIN], [b"LINDEX", b"l", LLONG_MAX], [b"LINDEX", b"l", b"9223372036854775808"],
    [b"LINDEX", b"nope", b"0"], [b"LINDEX", b"nope", b"x"], [b"LINDEX", b"l"], [b"LRANGE", b"l", b"0", b"0"],
    [b"LRANGE", b"l", b"-2", b"-1"], [b"LRANGE", b"l", b"5", b"1"], [b"LRANGE", b"l", b"-100", b"100"],
    [b"LRANGE", b"l", b"x", b"1"], [b"LRANGE", b"l", b"0", b"x"], [b"LRANGE", b"nope", b"0", b"-1"],
    [b"LRANGE", b"nope", b"x", b"1"], [b"LRANGE", b"l", b"0"], [b"LRANGE", b"l", LLONG_MIN, LLONG_MAX],
    [b"LRANGE", b"l", b"100", b"200"], [b"LRANGE", b"l", b"-1", b"-2"],
    # LSET, LINSERT, LREM, LTRIM
    [b"LSET", b"l", b"0", b"z"], [b"LSET", b"l", b"-1", b"w"], [b"LSET", b"l", b"100", b"v"], [b"LSET", b"l", b"x", b"v"],
    [b"LSET", b"nope", b"0", b"v"], [b"LSET", b"nope", b"x", b"v"], [b"LSET", b"l", b"0"], [b"LRANGE", b"l", b"0", b"-1"],
    [b"LINSERT", b"l", b"BEFORE", b"z", b"i1"], [b"LINSERT", b"l", b"after", b"w", b"i2"],
    [b"LINSERT", b"l", b"BEFORE", b"nope", b"i3"], [b"LINSERT", b"l", b"MIDDLE", b"z", b"i4"],
    [b"LINSERT", b"nope", b"BEFORE", b"a", b"b"], [b"LINSERT", b"nope", b"MIDDLE", b"a", b"b"],
    [b"LINSERT", b"l", b"BEFORE", b"z"], [b"LRANGE", b"l", b"0", b"-1"], [b"LREM", b"l", b"0", b"i1"],
    [b"LREM", b"l", b"1", b"nope"], [b"LREM", b"l", b"-1", b"a"], [b"LREM", b"l", b"x", b"a"], [b"LREM", b"nope", b"0", b"a"],
    [b"LREM", b"nope", b"x", b"a"], [b"LREM", b"l", b"0"], [b"RPUSH", b"r", b"a", b"b", b"a", b"c", b"a", b"d", b"a"],
    [b"LREM", b"r", b"2", b"a"], [b"LRANGE", b"r", b"0", b"-1"], [b"LREM", b"r", b"-1", b"a"], [b"LRANGE", b"r", b"0", b"-1"],
    [b"LREM", b"r", b"0", b"a"], [b"LRANGE", b"r", b"0", b"-1"], [b"LREM", b"r", LLONG_MIN, b"b"],
    [b"LTRIM", b"r", b"0", b"0"], [b"LRANGE", b"r", b"0", b"-1"], [b"LTRIM", b"r", b"1", b"0"], [b"EXISTS", b"r"],
    [b"LTRIM", b"nope", b"0", b"1"], [b"LTRIM", b"nope", b"x", b"1"], [b"LTRIM", b"l", b"x", b"1"], [b"LTRIM", b"l", b"0"],
    [b"RPUSH", b"r", b"a", b"b", b"c", b"d", b"e"], [b"LTRIM", b"r", b"-3", b"-2"], [b"LRANGE", b"r", b"0", b"-1"],
    [b"LTRIM", b"r", b"-100", b"100"], [b"LTRIM", b"r", b"5", b"10"], [b"EXISTS", b"r"],
    # pops
    [b"LPOP", b"l"], [b"RPOP", b"l"], [b"LPOP", b"l", b"0"], [b"LPOP", b"l", b"2"], [b"RPOP", b"l", b"1"],
    [b"LPOP", b"l", b"-1"], [b"LPOP", b"l", b"x"], [b"LPOP", b"nope"], [b"LPOP", b"nope", b"2"], [b"LPOP", b"nope", b"0"],
    [b"LPOP", b"nope", b"-1"], [b"LPOP", b"l", b"1", b"2"], [b"LPOP"], [b"RPOP", b"l", b"100"], [b"EXISTS", b"l"],
    [b"RPOP", b"l", LLONG_MAX], [b"RPOP", b"l", b"9223372036854775808"],
    # LPOS
    [b"RPUSH", b"p", b"a", b"b", b"c", b"a", b"b", b"c", b"a"], [b"LPOS", b"p", b"a"], [b"LPOS", b"p", b"a", b"RANK", b"2"],
    [b"LPOS", b"p", b"a", b"RANK", b"-1"], [b"LPOS", b"p", b"a", b"RANK", b"-2"], [b"LPOS", b"p", b"a", b"RANK", b"0"],
    [b"LPOS", b"p", b"a", b"COUNT", b"0"], [b"LPOS", b"p", b"a", b"COUNT", b"2"], [b"LPOS", b"p", b"a", b"COUNT", b"-1"],
    [b"LPOS", b"p", b"a", b"MAXLEN", b"2"], [b"LPOS", b"p", b"a", b"MAXLEN", b"-1"],
    [b"LPOS", b"p", b"a", b"RANK", b"2", b"COUNT", b"0", b"MAXLEN", b"5"], [b"LPOS", b"p", b"a", b"rank", b"-1", b"count", b"2"],
    [b"LPOS", b"p", b"zz"], [b"LPOS", b"p", b"zz", b"COUNT", b"0"], [b"LPOS", b"nope", b"a"], [b"LPOS", b"nope", b"a", b"COUNT", b"0"],
    [b"LPOS", b"nope", b"a", b"RANK", b"0"], [b"LPOS", b"p", b"a", b"BAD"], [b"LPOS", b"p", b"a", b"RANK"],
    [b"LPOS", b"p", b"a", b"RANK", b"x"], [b"LPOS", b"p", b"a", b"COUNT", b"1", b"COUNT"], [b"LPOS", b"p", b"a", b"RANK", LLONG_MIN],
    [b"LPOS", b"p", b"a", b"RANK", LLONG_MIN, b"COUNT", b"0"], [b"LPOS", b"p", b"a", b"RANK", LLONG_MAX],
    [b"LPOS", b"p", b"a", b"COUNT", b"0", b"RANK", b"1", b"RANK", b"-1"], [b"LPOS", b"p", b"a", b"MAXLEN", b"0", b"COUNT", b"0"],
    [b"LPOS", b"p"], [b"LPOS"],
    # LMOVE, RPOPLPUSH
    [b"RPUSH", b"m1", b"a", b"b", b"c"], [b"LMOVE", b"m1", b"m2", b"LEFT", b"RIGHT"], [b"LMOVE", b"m1", b"m2", b"right", b"left"],
    [b"LMOVE", b"m1", b"m1", b"LEFT", b"RIGHT"], [b"LRANGE", b"m1", b"0", b"-1"], [b"LRANGE", b"m2", b"0", b"-1"],
    [b"LMOVE", b"m1", b"m2", b"LEFT", b"UP"], [b"LMOVE", b"m1", b"m2", b"UP", b"LEFT"], [b"LMOVE", b"nope", b"m2", b"LEFT", b"LEFT"],
    [b"LMOVE", b"nope", b"m2", b"UP", b"LEFT"], [b"LMOVE", b"m1", b"m2", b"LEFT"], [b"RPOPLPUSH", b"m2", b"m3"],
    [b"RPOPLPUSH", b"nope", b"m3"], [b"RPOPLPUSH", b"m3", b"m3"], [b"RPOPLPUSH", b"m2"], [b"LMOVE", b"m1", b"m1", b"LEFT", b"LEFT"],
    [b"LMOVE", b"m1", b"m4", b"RIGHT", b"RIGHT"], [b"EXISTS", b"m1"], [b"LRANGE", b"m4", b"0", b"-1"],
    # LMPOP
    [b"LMPOP", b"1", b"m3", b"LEFT"], [b"LMPOP", b"2", b"nope", b"m2", b"RIGHT", b"COUNT", b"2"],
    [b"LMPOP", b"2", b"nope", b"nope2", b"LEFT"], [b"LMPOP", b"0", b"m2", b"LEFT"], [b"LMPOP", b"-1", b"m2", b"LEFT"],
    [b"LMPOP", b"x", b"m2", b"LEFT"], [b"LMPOP", b"1", b"m2", b"MIDDLE"], [b"LMPOP", b"1", b"m2", b"LEFT", b"COUNT", b"0"],
    [b"LMPOP", b"1", b"m2", b"LEFT", b"COUNT", b"-1"], [b"LMPOP", b"1", b"m2", b"LEFT", b"COUNT", b"x"],
    [b"LMPOP", b"1", b"m2", b"LEFT", b"COUNT"], [b"LMPOP", b"1", b"m2", b"LEFT", b"COUNT", b"1", b"COUNT", b"2"],
    [b"LMPOP", b"2", b"m2"], [b"LMPOP", b"3", b"a", b"b", b"LEFT"], [b"LMPOP", b"1"], [b"LMPOP"],
    [b"LMPOP", b"1", b"m4", b"RIGHT", b"COUNT", b"10"], [b"EXISTS", b"m4"],
    # another kind
    [b"SET", b"s", b"str"], [b"LPUSH", b"s", b"a"], [b"RPUSH", b"s", b"a"], [b"LPUSHX", b"s", b"a"], [b"RPUSHX", b"s", b"a"],
    [b"LLEN", b"s"], [b"LINDEX", b"s", b"0"], [b"LINDEX", b"s", b"x"], [b"LRANGE", b"s", b"0", b"-1"],
    [b"LRANGE", b"s", b"x", b"1"], [b"LSET", b"s", b"0", b"a"], [b"LSET", b"s", b"x", b"a"],
    [b"LINSERT", b"s", b"BEFORE", b"a", b"b"], [b"LREM", b"s", b"0", b"a"], [b"LREM", b"s", b"x", b"a"],
    [b"LTRIM", b"s", b"0", b"1"], [b"LPOP", b"s"], [b"RPOP", b"s", b"2"], [b"LPOP", b"s", b"x"], [b"LPOS", b"s", b"a"],
    [b"LMOVE", b"s", b"m9", b"LEFT", b"LEFT"], [b"RPUSH", b"m9", b"a"], [b"LMOVE", b"m9", b"s", b"LEFT", b"LEFT"],
    [b"LRANGE", b"m9", b"0", b"-1"], [b"LMPOP", b"1", b"s", b"LEFT"], [b"LMPOP", b"2", b"nope", b"s", b"LEFT"],
    [b"LMPOP", b"2", b"s", b"m9", b"LEFT"], [b"HSET", b"h", b"f", b"v"], [b"LPUSH", b"h", b"a"], [b"LLEN", b"h"],
    [b"LPOS", b"h", b"a"], [b"RPOPLPUSH", b"m9", b"h"], [b"TYPE", b"s"], [b"TYPE", b"m9"],
    # a list read and written as another kind
    [b"RPUSH", b"k", b"1", b"2", b"3"], [b"TYPE", b"k"], [b"OBJECT", b"ENCODING", b"k"], [b"GET", b"k"], [b"APPEND", b"k", b"x"],
    [b"INCR", b"k"], [b"STRLEN", b"k"], [b"GETRANGE", b"k", b"0", b"1"], [b"SETRANGE", b"k", b"0", b"x"],
    [b"GETBIT", b"k", b"0"], [b"BITCOUNT", b"k"], [b"HSET", b"k", b"f", b"v"], [b"HGET", b"k", b"f"], [b"HLEN", b"k"],
    [b"GETDEL", b"k"], [b"LCS", b"k", b"s"], [b"BITOP", b"AND", b"d", b"k"], [b"MSETNX", b"k", b"x"], [b"SETNX", b"k", b"x"],
    [b"EXISTS", b"k"], [b"SCAN", b"0", b"TYPE", b"list", b"COUNT", b"1000"],
    # time, RENAME, COPY, MOVE, SET over it
    [b"EXPIRE", b"k", b"100"], [b"TTL", b"k"], [b"LPUSH", b"k", b"t"], [b"RPOP", b"k"], [b"TTL", b"k"], [b"PERSIST", b"k"],
    [b"TTL", b"k"], [b"RENAME", b"k", b"k2"], [b"LRANGE", b"k2", b"0", b"-1"], [b"COPY", b"k2", b"k3"],
    [b"LRANGE", b"k3", b"0", b"-1"], [b"RPUSH", b"k3", b"c"], [b"LRANGE", b"k2", b"0", b"-1"], [b"MOVE", b"k3", b"1"],
    [b"SELECT", b"1"], [b"LRANGE", b"k3", b"0", b"-1"], [b"LMOVE", b"k3", b"k4", b"LEFT", b"LEFT"], [b"SELECT", b"0"],
    [b"SET", b"k2", b"x"], [b"TYPE", b"k2"], [b"RPUSH", b"k2", b"a"], [b"DEL", b"k2"], [b"RPUSH", b"k2", b"a"], [b"TYPE", b"k2"],
    [b"MEMORY", b"USAGE", b"k2"], [b"MEMORY", b"USAGE", b"k2", b"SAMPLES", b"0"],
    # the bytes of elements
    [b"RPUSH", b"\x00k", b"\x00", b"\r\n", b"", b"\xff\xfe"], [b"LRANGE", b"\x00k", b"0", b"-1"], [b"LPOS", b"\x00k", b""],
    [b"LPOS", b"\x00k", b"\r\n"], [b"LINSERT", b"\x00k", b"AFTER", b"", b"\x00\x00"], [b"LREM", b"\x00k", b"0", b""],
    [b"LRANGE", b"\x00k", b"0", b"-1"], [b"LSET", b"\x00k", b"0", b""], [b"LINDEX", b"\x00k", b"0"],
]


def push_all(key, items, left=False):
    return [[b"LPUSH" if left else b"RPUSH", key] + items[i:i + 100] for i in range(0, len(items), 100)]


# lists of many sizes, made in calls of a hundred elements, then read and
# written at both ends and in the middle
def sizes(b, r):
    for size in (1, 100, 128, 129, 1000, 20000):
        key = b"z%d" % size
        items = [b"e%d" % i for i in range(size)]
        for cmd in push_all(key, items, size % 2 == 0):
            same(b, r, cmd)
        h = str(size // 2).encode()
        for cmd in ([b"OBJECT", b"ENCODING", key], [b"LLEN", key], [b"LINDEX", key, b"0"], [b"LINDEX", key, h],
                    [b"LINDEX", key, b"-1"], [b"LRANGE", key, b"0", b"9"], [b"LRANGE", key, b"-10", b"-1"],
                    [b"LRANGE", key, h, str(size // 2 + 5).encode()], [b"LSET", key, h, b"mid"], [b"LINDEX", key, h],
                    [b"LINSERT", key, b"AFTER", b"mid", b"ins"], [b"LPOS", key, b"ins"], [b"LPOS", key, b"e1"],
                    [b"LPOS", key, b"e1", b"RANK", b"-1"], [b"LPOS", key, b"e1", b"MAXLEN", b"10"],
                    [b"LPOS", key, b"e1", b"COUNT", b"0", b"MAXLEN", b"50"], [b"LREM", key, b"0", b"ins"],
                    [b"LTRIM", key, b"1", b"-2"], [b"LLEN", key], [b"LPOP", key, b"3"], [b"RPOP", key, b"3"],
                    [b"LMOVE", key, key + b"m", b"LEFT", b"RIGHT"], [b"LMOVE", key, key, b"RIGHT", b"LEFT"],
                    [b"LMPOP", b"2", b"nope", key, b"RIGHT", b"COUNT", b"5"], [b"LLEN", key],
                    [b"OBJECT", b"ENCODING", key], [b"MEMORY", b"USAGE", key]):
            same(b, r, cmd)
        if size <= 1000:
            same(b, r, [b"LRANGE", key, b"0", b"-1"])
    # a capped list: a push and a trim, over and over
    for i in range(2000):
        same(b, r, [b"LPUSH", b"cap", b"c%d" % i])
        same(b, r, [b"LTRIM", b"cap", b"0", b"99"])
    same(b, r, [b"LRANGE", b"cap", b"0", b"-1"])
    # a queue: pushes at one end, pops at the other
    for i in range(3000):
        same(b, r, [b"RPUSH", b"que", b"q%d" % i, b"w%d" % i])
        same(b, r, [b"LPOP", b"que"])
    same(b, r, [b"LLEN", b"que"])
    same(b, r, [b"LRANGE", b"que", b"0", b"20"])


# BendKV's DUMP of key, restored in Redis, gives Redis the list BendKV
# holds
def dumped(b, r, key):
    global n
    n += 1
    payload = run(b, [b"DUMP", key])[1]
    run(r, [b"RESTORE", key + b".b", b"0", payload, b"REPLACE"])
    x, y = run(b, [b"LRANGE", key, b"0", b"-1"]), run(r, [b"LRANGE", key + b".b", b"0", b"-1"])
    if x != y:
        fail([b"DUMP", key], x, y)
    run(r, [b"DEL", key + b".b"])


# lists past one piece (2,048 bytes in BendKV): grown an element at a
# time at either end, read across the pieces, set to longer and shorter
# elements (a piece past a buffer is dealt again), trimmed inside pieces,
# and emptied from the end it was not made from; elements longer than a
# piece among short ones
def pieces(b, r):
    look = lambda key: ([b"LLEN", key], [b"LRANGE", key, b"0", b"-1"], [b"LINDEX", key, b"0"], [b"LINDEX", key, b"-1"])
    el = lambda i, w: (b"%d:" % i).ljust(w, b"x")
    for i in range(80):
        same(b, r, [b"LPUSH" if i % 3 else b"RPUSH", b"pc", el(i, 300 if i % 2 else 7)])
        if i % 10 == 9:
            for cmd in look(b"pc"):
                same(b, r, cmd)
    for i in range(0, 80, 7):
        same(b, r, [b"LINDEX", b"pc", b"%d" % i])
        same(b, r, [b"LRANGE", b"pc", b"%d" % i, b"%d" % (i + 13)])
    for i in range(0, 80, 9):
        same(b, r, [b"LSET", b"pc", b"%d" % i, el(1000 + i, 1900)])
    for i in range(3, 80, 9):
        same(b, r, [b"LSET", b"pc", b"%d" % i, b""])
    for cmd in look(b"pc"):
        same(b, r, cmd)
    dumped(b, r, b"pc")
    for cmd in ([b"LTRIM", b"pc", b"3", b"-4"], [b"LTRIM", b"pc", b"11", b"-12"], [b"LRANGE", b"pc", b"0", b"-1"]):
        same(b, r, cmd)
    for i in range(30):
        same(b, r, [b"LPOP" if i % 4 else b"RPOP", b"pc"])
    same(b, r, [b"LPOP", b"pc", b"100"])
    same(b, r, [b"EXISTS", b"pc"])
    # made at one end, emptied from the other
    for key, push, pop in ((b"pr", b"RPUSH", b"LPOP"), (b"pl", b"LPUSH", b"RPOP")):
        for i in range(0, 600, 20):
            same(b, r, [push, key] + [el(j, 40 + j % 90) for j in range(i, i + 20)])
        for cmd in look(key):
            same(b, r, cmd)
        dumped(b, r, key)
        for i in range(0, 600, 7):
            same(b, r, [pop, key, b"7"])
            if i % 140 == 0:
                for cmd in look(key):
                    same(b, r, cmd)
        same(b, r, [b"EXISTS", key])
    # elements longer than a piece among short ones
    for i in range(12):
        same(b, r, [b"RPUSH" if i % 2 else b"LPUSH", b"pb", el(i, 5000 if i % 3 == 0 else 50)])
    for cmd in look(b"pb") + ([b"LINDEX", b"pb", b"5"], [b"LRANGE", b"pb", b"2", b"8"], [b"LSET", b"pb", b"4", el(99, 3000)],
                              [b"LSET", b"pb", b"6", b"s"], [b"LTRIM", b"pb", b"1", b"-2"]) + look(b"pb"):
        same(b, r, cmd)
    dumped(b, r, b"pb")
    for i in range(12):
        same(b, r, [b"RPOP" if i % 2 else b"LPOP", b"pb"])
    # a list of two pieces, popped from each end in turn
    for i in range(16):
        same(b, r, [b"RPUSH", b"pt", el(i, 250)])
    for i in range(16):
        same(b, r, [b"LPOP" if i % 2 else b"RPOP", b"pt"])
        same(b, r, [b"LRANGE", b"pt", b"0", b"-1"])


# LPOS, LINSERT and LREM through lists of many pieces in both stacks, of
# values that repeat: from either end, past pieces, with a piece pushed
# past a buffer by LINSERT and pieces emptied by LREM
def searches(b, r):
    el = lambda i, w: (b"%d:" % i).ljust(w, b"x")
    vals = [b"a", b"b", b"", b"c" * 300, b"d" * 2500]
    for i in range(900):
        x = vals[i % 5] if i % 3 == 0 else el(i, 20 + i % 60)
        same(b, r, [b"LPUSH" if i % 2 else b"RPUSH", b"sr", x])
    look = ([b"LLEN", b"sr"], [b"LINDEX", b"sr", b"0"], [b"LINDEX", b"sr", b"450"], [b"LINDEX", b"sr", b"-1"])
    for x in vals + [el(4, 24), el(895, 75), b"none"]:
        for opts in ([], [b"RANK", b"2"], [b"RANK", b"-1"], [b"RANK", b"-3"], [b"COUNT", b"0"], [b"COUNT", b"5"],
                     [b"RANK", b"-2", b"COUNT", b"0"], [b"MAXLEN", b"300"], [b"RANK", b"-1", b"MAXLEN", b"200", b"COUNT", b"0"],
                     [b"RANK", b"40", b"COUNT", b"3"], [b"RANK", b"1000"]):
            same(b, r, [b"LPOS", b"sr", x] + opts)
    for x, v in ((b"a", b"ia"), (b"b", el(1, 1900)), (el(4, 24), b"i4"), (el(895, 75), el(2, 2100)), (b"c" * 300, b"")):
        for where in (b"BEFORE", b"AFTER"):
            same(b, r, [b"LINSERT", b"sr", where, x, v])
            same(b, r, [b"LPOS", b"sr", v, b"COUNT", b"0"])
    same(b, r, [b"LINSERT", b"sr", b"BEFORE", b"none", b"x"])
    for cmd in look:
        same(b, r, cmd)
    dumped(b, r, b"sr")
    for x, c in ((b"a", b"3"), (b"a", b"-2"), (b"", b"0"), (b"b", b"-100"), (el(1, 1900), b"1"), (b"none", b"0"),
                 (b"c" * 300, b"2"), (b"d" * 2500, b"0"), (b"ia", b"0")):
        same(b, r, [b"LREM", b"sr", c, x])
        for cmd in look:
            same(b, r, cmd)
    same(b, r, [b"LRANGE", b"sr", b"0", b"-1"])
    dumped(b, r, b"sr")
    # pieces of one value, taken whole, then the list emptied
    for i in range(300):
        same(b, r, [b"RPUSH" if i % 2 else b"LPUSH", b"so", b"z" * 100 if i % 50 else b"y"])
    for cmd in ([b"LREM", b"so", b"-7", b"z" * 100], [b"LRANGE", b"so", b"0", b"20"], [b"LREM", b"so", b"0", b"z" * 100],
                [b"LRANGE", b"so", b"0", b"-1"], [b"LINSERT", b"so", b"AFTER", b"y", b"w"], [b"LRANGE", b"so", b"0", b"-1"],
                [b"LREM", b"so", b"0", b"y"], [b"LREM", b"so", b"0", b"w"], [b"EXISTS", b"so"]):
        same(b, r, cmd)


# A list's encoding, and the nodes of a quicklist, as Redis 7.2 makes
# them: OBJECT ENCODING and the DUMP of each key compared after each step
def encodings(b, r):
    el = lambda i, w: (b"%d:" % i).ljust(w, b"x")
    look = lambda key: ([b"OBJECT", b"ENCODING", key], [b"LLEN", key], [b"DUMP", key])

    def steps(key, cmds, every=1, keys=()):
        for i, cmd in enumerate(cmds):
            same(b, r, cmd)
            if i % every == 0 or i == len(cmds) - 1:
                for k in (key,) + keys:
                    for c in look(k):
                        same(b, r, c)

    # grown an element at a time at either end, past 8 KB and on into
    # more nodes, then emptied from the other end: a quicklist until one
    # node of 4 KB at most is left
    for key, push, pop in ((b"eg1", b"RPUSH", b"LPOP"), (b"eg2", b"LPUSH", b"RPOP"), (b"eg3", b"RPUSH", b"RPOP")):
        steps(key, [[push, key, el(i, 40 + i % 70)] for i in range(400)], 3)
        steps(key, [[pop, key] for _ in range(400)], 3)
    # many elements in one push, past 8 KB at once (the listpack made a
    # quicklist before them), and integers of every width
    steps(b"eg4", [[b"RPUSH", b"eg4"] + [el(i, 50) for i in range(300)], [b"LPUSH", b"eg4"] + [el(i, 9) for i in range(500)]])
    ints = [b"%d" % v for v in (0, 1, 127, 128, -1, -4096, 4095, 4096, -32768, 32767, 32768, -8388608, 8388607,
                                8388608, -2147483648, 2147483647, 2147483648, -9223372036854775808, 9223372036854775807)]
    steps(b"eg5", [[b"RPUSH", b"eg5"] + ints * 40, [b"LPUSH", b"eg5"] + [b"%d" % (i * 7919) for i in range(1500)],
                   [b"RPUSH", b"eg5", b"01", b"-0", b"+1", b"1e3", b"9223372036854775808"]])
    steps(b"eg5", [[b"LPOP", b"eg5", b"700"], [b"RPOP", b"eg5", b"900"], [b"LMPOP", b"1", b"eg5", b"LEFT", b"COUNT", b"500"],
                   [b"LMPOP", b"1", b"eg5", b"RIGHT", b"COUNT", b"300"]])
    # at the edge: a listpack of 8 KB and a byte, and of 8 KB
    for key, w in ((b"eg6", 8183), (b"eg7", 8184), (b"eg8", 8185), (b"eg9", 8186)):
        steps(key, [[b"RPUSH", key, b"x" * w], [b"RPUSH", key, b"y"], [b"RPOP", key], [b"LPUSH", key, b"z"]])
    # LTRIM to a node or less, LREM of many and of none, LSET of an element
    # that takes a listpack past 8 KB and back
    steps(b"et", [[b"RPUSH", b"et"] + [el(i, 30 + i % 50) for i in range(600)], [b"LTRIM", b"et", b"0", b"-1"],
                  [b"LTRIM", b"et", b"5", b"-6"], [b"LTRIM", b"et", b"100", b"300"], [b"LTRIM", b"et", b"10", b"150"],
                  [b"LTRIM", b"et", b"0", b"60"], [b"RPUSH", b"et"] + [b"r"] * 50 + [el(9, 3000)] * 3,
                  [b"LREM", b"et", b"0", b"nothing"], [b"LREM", b"et", b"-20", b"r"], [b"LREM", b"et", b"0", el(9, 3000)],
                  [b"LREM", b"et", b"0", b"r"]])
    steps(b"es", [[b"RPUSH", b"es", b"a", b"b", b"c"], [b"LSET", b"es", b"1", b"x" * 9000], [b"LSET", b"es", b"1", b"b"],
                  [b"RPUSH", b"es"] + [el(i, 100) for i in range(120)],
                  [b"LSET", b"es", b"60", b"y" * 7000], [b"LSET", b"es", b"0", b"z" * 9000], [b"LSET", b"es", b"-1", b""],
                  [b"LPOP", b"es", b"100"], [b"LSET", b"es", b"0", b"s"], [b"LPOP", b"es", b"3"]])
    # LINSERT: into a node with room, at a full node's end into the next
    # node or the one before, into a node of its own, or splitting the
    # node, whose parts then merge with their neighbours
    base = [el(i, 60) for i in range(300)]
    cmds = [[b"RPUSH", b"ei"] + base]
    for i in (0, 1, 60, 61, 120, 121, 122, 199, 250, 298, 299):
        for where in (b"BEFORE", b"AFTER"):
            cmds.append([b"LINSERT", b"ei", where, base[i], el(1000 + i, 30 + i % 200)])
    cmds += [[b"LPOP", b"ei", b"200"], [b"LINSERT", b"ei", b"BEFORE", base[250], b"q" * 5000],
             [b"LINSERT", b"ei", b"AFTER", base[251], b"q" * 3000], [b"RPOP", b"ei", b"40"]]
    steps(b"ei", cmds)
    steps(b"ej", [[b"RPUSH", b"ej", b"a", b"b", b"c"], [b"LINSERT", b"ej", b"AFTER", b"b", b"w" * 8190],
                  [b"LINSERT", b"ej", b"BEFORE", b"a", b"v" * 100], [b"LINSERT", b"ej", b"AFTER", b"c", b"u"],
                  [b"LREM", b"ej", b"0", b"w" * 8190]])
    # moves between a listpack and a quicklist, either way
    steps(b"em1", [[b"RPUSH", b"em1"] + [el(i, 70) for i in range(200)], [b"RPUSH", b"em2"] + [el(i, 70) for i in range(110)]])
    steps(b"em2", [[b"LMOVE", b"em1", b"em2", b"LEFT", b"RIGHT"] for _ in range(30)] +
          [[b"RPOPLPUSH", b"em2", b"em1"] for _ in range(80)], 4, (b"em1",))
    # payloads: Redis's DUMP restored in BendKV and BendKV's in Redis, each
    # read as Redis reads it (a quicklist of one node of 8 KB at most is a
    # listpack)
    for key in (b"eg4", b"eg5", b"et", b"es", b"ei", b"em1", b"em2"):
        pb, pr = run(b, [b"DUMP", key]), run(r, [b"DUMP", key])
        if pb[1] is None or pr[1] is None:
            continue
        for c, p in ((b, pr[1]), (r, pb[1])):
            run(c, [b"RESTORE", key + b".r", b"0", p, b"REPLACE"])
        for c in look(key + b".r"):
            same(b, r, c)
        # a node of its own for the elements past one node, then popped to one node
        steps(key + b".r", [[b"LTRIM", key + b".r", b"0", b"40"], [b"RPOP", key + b".r"]])
    for c in (b, r):
        run(c, [b"DEL", b"eg1", b"eg2", b"eg3", b"eg4", b"eg5", b"eg6", b"eg7", b"eg8", b"eg9", b"et", b"es", b"ei", b"ej",
                b"em1", b"em2"] + [k + b".r" for k in (b"eg4", b"eg5", b"et", b"es", b"ei", b"em1", b"em2")])


# a list whose time passed: a read finds nothing, a write makes it anew,
# a move takes it as not there, as a source or a destination
def expired(b, r):
    for c in (b, r):
        for cmd in ([b"RPUSH", b"x1", b"a", b"b", b"c"], [b"PEXPIRE", b"x1", b"50"], [b"SET", b"x2", b"str", b"PX", b"50"],
                    [b"RPUSH", b"x3", b"a"], [b"PEXPIRE", b"x3", b"50"], [b"RPUSH", b"x4", b"a", b"b"],
                    [b"PEXPIRE", b"x4", b"50"], [b"RPUSH", b"x5", b"q"], [b"PEXPIRE", b"x5", b"50"],
                    [b"HSET", b"x6", b"f", b"v"], [b"PEXPIRE", b"x6", b"50"], [b"RPUSH", b"x7", b"a"],
                    [b"PEXPIRE", b"x7", b"50"], [b"RPUSH", b"em", b"a", b"b", b"c", b"d"]):
            run(c, cmd)
    time.sleep(0.2)
    for cmd in ([b"LLEN", b"x1"], [b"LRANGE", b"x1", b"0", b"-1"], [b"LPUSHX", b"x1", b"a"], [b"LPUSH", b"x1", b"n"],
                [b"LRANGE", b"x1", b"0", b"-1"], [b"TTL", b"x1"], [b"LPUSH", b"x2", b"a"], [b"TYPE", b"x2"],
                [b"LRANGE", b"x2", b"0", b"-1"], [b"LMOVE", b"em", b"x3", b"LEFT", b"LEFT"], [b"LRANGE", b"x3", b"0", b"-1"],
                [b"TTL", b"x3"], [b"LMOVE", b"x4", b"em", b"LEFT", b"LEFT"], [b"LMPOP", b"2", b"x5", b"em", b"LEFT"],
                [b"RPOPLPUSH", b"em", b"x6"], [b"LRANGE", b"x6", b"0", b"-1"], [b"TYPE", b"x6"], [b"LSET", b"x7", b"0", b"v"],
                [b"LINSERT", b"x7", b"BEFORE", b"a", b"v"], [b"LREM", b"x7", b"0", b"a"], [b"LTRIM", b"x7", b"0", b"0"],
                [b"LPOS", b"x7", b"a"], [b"LPOP", b"x7", b"2"], [b"EXISTS", b"x7"], [b"LRANGE", b"em", b"0", b"-1"]):
        same(b, r, cmd)


KEYS = [b"r1", b"r2", b"r3", b"rs"]


def rand_cmd(r):
    key = r.choice(KEYS)
    v = lambda: r.choice([b"a", b"b", b"c", b"", b"1", b"-5"]) if r.random() < 0.9 else b"x" * r.randint(1, 80)
    num = lambda: r.choice([b"0", b"1", b"2", b"-1", b"-2", b"3", b"10", b"-10", b"100", b"-100", b"x"])
    end = lambda: r.choice([b"LEFT", b"RIGHT", b"left", b"right"])
    k = r.random()
    if k < 0.2:
        return [r.choice([b"LPUSH", b"RPUSH", b"LPUSHX", b"RPUSHX"]), key] + [v() for _ in range(r.randint(1, 4))]
    if k < 0.3:
        return [r.choice([b"LPOP", b"RPOP"]), key] + ([num()] if r.random() < 0.4 else [])
    if k < 0.35:
        return [b"LSET", key, num(), v()]
    if k < 0.4:
        return [b"LINSERT", key, r.choice([b"BEFORE", b"AFTER"]), v(), v()]
    if k < 0.45:
        return [b"LREM", key, num(), v()]
    if k < 0.5:
        return [b"LTRIM", key, num(), num()]
    if k < 0.58:
        return [b"LMOVE", key, r.choice(KEYS), end(), end()]
    if k < 0.62:
        return [b"RPOPLPUSH", key, r.choice(KEYS)]
    if k < 0.68:
        ks = [r.choice(KEYS) for _ in range(r.randint(1, 3))]
        return [b"LMPOP", str(len(ks)).encode()] + ks + [end()] + ([b"COUNT", num()] if r.random() < 0.5 else [])
    if k < 0.72:
        return [b"LPOS", key, v()] + r.choice([[], [b"RANK", r.choice([b"1", b"2", b"-1", b"-2"])],
                                              [b"COUNT", r.choice([b"0", b"1", b"2"])], [b"MAXLEN", r.choice([b"0", b"2", b"5"])]])
    if k < 0.75:
        return [r.choice([b"SET", b"DEL", b"EXPIRE"]), key] + ([b"str"] if r.random() < 0.5 else [b"1000"])
    if k < 0.78:
        return [b"RPUSH", key] + [v() for _ in range(r.randint(5, 30))]
    return r.choice([[b"LLEN", key], [b"LINDEX", key, num()], [b"LRANGE", key, num(), num()],
                     [b"LRANGE", key, b"0", b"-1"], [b"TYPE", key], [b"EXISTS", key], [b"TTL", key],
                     [b"OBJECT", b"ENCODING", key], [b"DUMP", key]])


# random commands on two lists of elements of up to 400 bytes, a few
# pieces each, sometimes one longer than a piece
def rand_wide(r):
    key = r.choice([b"w1", b"w2"])
    pool = [b"a", b"", b"v" * 300, b"w" * 2500]
    v = lambda: (r.choice(pool) if r.random() < 0.25 else
                 b"v" * (r.randint(0, 400) if r.random() < 0.98 else r.randint(2000, 6000)))
    idx = lambda: b"%d" % r.randint(-40, 40)
    k = r.random()
    if k < 0.3:
        return [r.choice([b"LPUSH", b"RPUSH"]), key] + [v() for _ in range(r.randint(1, 3))]
    if k < 0.45:
        return [r.choice([b"LPOP", b"RPOP"]), key] + ([b"%d" % r.randint(1, 4)] if r.random() < 0.3 else [])
    if k < 0.55:
        return [b"LSET", key, idx(), v()]
    if k < 0.6:
        return [b"LTRIM", key, b"%d" % r.randint(0, 2), b"%d" % r.randint(-3, -1)]
    if k < 0.65:
        return [b"LMOVE", key, r.choice([b"w1", b"w2"]), r.choice([b"LEFT", b"RIGHT"]), r.choice([b"LEFT", b"RIGHT"])]
    if k < 0.75:
        return [b"LRANGE", key, idx(), idx()]
    if k < 0.8:
        return [b"LRANGE", key, b"0", b"-1"]
    if k < 0.85:
        return [b"LPOS", key, v()] + r.choice([[], [b"RANK", r.choice([b"2", b"-1", b"-3"])], [b"COUNT", b"0"],
                                               [b"RANK", b"-1", b"COUNT", b"3", b"MAXLEN", b"50"]])
    if k < 0.9:
        return [b"LREM", key, r.choice([b"0", b"1", b"2", b"-1", b"-2"]), v()]
    return r.choice([[b"LINDEX", key, idx()], [b"LLEN", key], [b"LINSERT", key, r.choice([b"BEFORE", b"AFTER"]), v(), v()],
                     [b"OBJECT", b"ENCODING", key], [b"DUMP", key]])


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
    comp = run(rd, [b"CONFIG", b"GET", b"rdbcompression"])[1][1][1]
    run(rd, [b"CONFIG", b"SET", b"rdbcompression", b"no"])
    try:
        script(b, rd, a)
    finally:
        run(rd, [b"CONFIG", b"SET", b"rdbcompression", comp])
    if bad:
        sys.exit("FAIL: %d of %d" % (bad, n))
    print("OK: %d list commands, each answered as Redis answers it (%d lists parted for a while, as README says)" % (n, parted))


def script(b, rd, a):
    for cmd in SCRIPT:
        same(b, rd, cmd)
    sizes(b, rd)
    pieces(b, rd)
    searches(b, rd)
    encodings(b, rd)
    expired(b, rd)
    r = random.Random(a.seed)
    for _ in range(a.rounds):
        same(b, rd, rand_cmd(r))
    for key in KEYS:
        same(b, rd, [b"LRANGE", key, b"0", b"-1"])
    for i in range(a.rounds):
        same(b, rd, rand_wide(r))
        if i % 500 == 499:
            for key in (b"w1", b"w2"):
                dumped(b, rd, key)
    for c in (b, rd):
        run(c, [b"FLUSHALL"])


if __name__ == "__main__":
    main()
