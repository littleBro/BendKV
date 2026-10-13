#!/usr/bin/env python3
"""Sorted sets against Redis: a script of sorted-set commands at their
edges, sorted sets of many sizes on both sides of the listpack limits
(128 elements, members of 64 bytes), sorted sets whose key's time has
passed, then random commands on a few keys (the operations of several
sorted sets, STOREs and ZMPOP among them), replies compared one by one.

Elements are in order of score, then member, on both servers, and those
replies are compared as they are. ZSCAN of a skiplist answers in the
order of each server's own table, so its whole walk is compared by the
pairs it answers. ZRANDMEMBER picks at random: its replies are compared
by kind and size, each member checked against the sorted set it was
picked from (with its score, under WITHSCORES; distinct where they must
be). A range by member is read only of elements of one score: Redis
answers one of a skiplist of other scores by the levels of its nodes,
which are random. MEMORY USAGE, an estimate on each server, is compared
by kind.

    python3 tests/zset_test.py --bendkv 6380 --redis 6390 [--rounds 3000] [--seed 1]
"""
import argparse
import random
import sys
import time

from diff_test import Conn, flat_values, rnd_zbound, rnd_zlex, rnd_lnum, rnd_zrange_opts, rnd_zop, rnd_zmpop

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


# a sorted set's elements, each member with its score
def elements(c, key):
    rep = run(c, [b"ZRANGE", key, b"0", b"-1", b"WITHSCORES"])
    if rep[0] != b"*":
        return {}
    vs = flat_values(rep)
    return dict(zip(vs[0::2], vs[1::2]))


def count_of(cmd):
    if len(cmd) < 3:
        return None
    try:
        return int(cmd[2])
    except ValueError:
        return None


# ZRANDMEMBER: the same kind and size; the members from the sorted set
# (with their scores), distinct for a count that is not negative
def zrand(b, r, cmd):
    key = cmd[1] if len(cmd) > 1 else b""
    x, y = run(b, cmd), run(r, cmd)
    if x[0] != y[0] or x[0] in (b"-", b":", b"+"):
        if x != y:
            fail(cmd, x, y)
        return
    have = elements(b, key)
    if x[0] in (b"$", b"_"):
        if (x[1] is None) != (y[1] is None) or (x[1] is not None and x[1] not in have):
            fail(cmd, x, y)
        return
    if x[1] is None or y[1] is None or len(x[1]) != len(y[1]):
        fail(cmd, x, y)
        return
    vs = flat_values(x)
    ws = any(a.upper() == b"WITHSCORES" for a in cmd[3:])
    got = vs[0::2] if ws else vs
    if any(m not in have for m in got) or (ws and any(have.get(m) != s for m, s in zip(vs[0::2], vs[1::2]))):
        fail(cmd, x, "elements of %r" % sorted(have.items())[:20])
    elif (count_of(cmd) or 0) > 0 and len(set(got)) != len(got):
        fail(cmd, x, "distinct members")


# ZSCAN from cursor 0 to its end, on each server: the pairs it answered
def walk(c, cmd):
    cur, seen = b"0", set()
    for _ in range(100000):
        rep = run(c, cmd[:2] + [cur] + cmd[3:])
        if rep[0] != b"*":
            return rep
        cur = rep[1][0][1]
        vs = [v for _, v in rep[1][1][1]]
        seen |= set(zip(vs[0::2], vs[1::2]))
        if cur == b"0":
            break
    return (b"*", sorted(seen))


def same(b, r, cmd):
    global n
    n += 1
    name = cmd[0].upper()
    if name == b"ZRANDMEMBER":
        return zrand(b, r, cmd)
    if name == b"ZSCAN" and len(cmd) > 2 and cmd[2] == b"0":
        x, y = walk(b, cmd), walk(r, cmd)
        if x != y:
            fail(cmd, x, y)
        return
    x, y = run(b, cmd), run(r, cmd)
    if name == b"MEMORY":
        if x[0] != y[0] or (x[0] != b":" and x != y):
            fail(cmd, x, y)
        return
    if name == b"SCAN" and x[0] == y[0] == b"*":
        x, y = sorted(x[1][1][1]), sorted(y[1][1][1])
    if x != y:
        fail(cmd, x, y)


def w(line):
    return line.encode().split()


SCRIPT = [w(x) for x in """
zadd z 1 a 2 b 3 c
zadd z 1 a
zadd z ch 5 a
zrange z 0 -1 withscores
zscore z a
zscore z nope
zcard z
zcard nokey
zrank z a
zrevrank z a
zrank z nope
zincrby z 2.5 b
zincrby z inf b
zincrby z -inf b
zscore z b
zadd z incr 1 b
zadd z xx 1 newmember
zadd z nx 10 a
zadd z gt 1 c
zadd z lt 100 c
zadd z gt lt 1 c
zadd z nx xx 1 c
zadd z nx gt 1 c
zadd z incr 1 a 2 b
zadd z 1
zadd z abc a
zadd z 1 a abc b
zadd z incr xx 1 nonexist
zadd z incr nx 1 c
zadd z
zadd z 1 a 2
zadd z nx
zadd z xx ch 7 c
zadd z ch ch ch 8 c
zadd z gt ch 1 c 9 d
zadd z lt incr 1 d
zadd z gt incr -1 d
zadd z 0x10 a
zadd z nan a
zadd z 1e400 a
zadd z incr inf e
zadd z incr -inf e
zincrby z x a
zincrby z 1
zincrby z nx a
zincrby z 1 a b
zrange z 0 -1
zrevrange z 0 -1 withscores
zrange z 0 -1 rev
zrange z 1 2
zrange z -2 -1 withscores
zrange z 5 10
zrange z 0 -1 limit 0 1
zrange z 0 -1 limit 0 -1
zrange z (1 5 byscore
zrange z -inf +inf byscore withscores
zrange z +inf -inf byscore rev withscores
zrange z +inf -inf byscore rev limit 1 1
zrangebyscore z -inf +inf
zrangebyscore z (1 (100 withscores limit 0 2
zrangebyscore z 1 2 limit 1 -5
zrangebyscore z 1 2 limit -1 5
zrangebyscore z abc 2
zrangebyscore z 1 2 rev
zrevrangebyscore z +inf -inf withscores
zrevrangebyscore z 5 1 limit 1 1
zcount z -inf +inf
zcount z (1 2
zcount z abc 1
zcount nokey 1 2
zrem z a nope
zrem z nope
zrem nokey a
zrem z
zadd lex 0 a 0 b 0 c 0 d 0 e 0 f 0 g
zrangebylex lex - +
zrangebylex lex [b (e
zrangebylex lex (b [e limit 1 2
zrevrangebylex lex + -
zrevrangebylex lex [e (b
zrangebylex lex [c +
zrangebylex lex - [c
zrangebylex lex a b
zrangebylex lex [b [a
zlexcount lex - +
zlexcount lex [b (e
zlexcount lex x y
zrangebylex lex - + withscores
zrange lex - + bylex
zrange lex + - bylex rev limit 0 3
zrange lex - + bylex limit 2 2
zremrangebylex lex [b [c
zrange lex 0 -1
zremrangebyrank lex 0 0
zrange lex 0 -1
zremrangebyrank lex -2 -1
zrange lex 0 -1
zremrangebyscore z -inf (3
zrange z 0 -1 withscores
zremrangebyscore z abc 1
zremrangebyrank z x 1
zremrangebylex z x y
zremrangebyrank nokey 0 -1
zremrangebyscore nokey 0 1
zremrangebyscore nokey x 1
zremrangebylex nokey - +
zremrangebylex nokey x +
zpopmin z
zpopmax z
zadd p 1 a 2 b 3 c 4 d
zpopmin p 2
zpopmax p 0
zpopmax p 5
exists p
zpopmin p -1
zpopmin p 1 2
zpopmin nokey
zpopmin nokey 3
zpopmax nokey -1
zpopmin nokey x
set s x
zadd s 1 a
zrange s 0 -1
zscore s a
zcard s
zpopmin s
zrem s a
zremrangebyrank s 0 1
zrank s a
type lex
zmscore lex a e nope
zmscore nokey a
zmscore lex
zscan lex 0
zscan lex 0 match e*
zadd neg -0 a
zscore neg a
zadd big 1 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa -0 b
zscore big b
object encoding big
object encoding lex
zadd f 1.5 a 0.1 b 1e300 c -1e-300 d
zrange f 0 -1 withscores
zincrby f 0.2 b
zadd i 100000000000000000 a 4611686018427387904 b 4611686018427387905 c 1e19 d
zscan i 0
zrange i 0 -1 withscores
zrange z 0 1 limit 1 1
zrange z 0 1 bylex withscores
zrange z 0 1 rev rev
zrange z 0 1 byscore byscore
zrange z 0 1 byscore bylex
zrange z 0 1 withscores withscores
zrange z 0 1 limit
zrange z 0 1 limit 1
zrange z 0 1 limit a b
zrange z 0 1 foo
zrangebyscore z 0 1 bylex
zrevrange z 0 1 limit 1 1
zrangebylex z - + byscore
zrangebyscore z 0 10 withscores limit 0 1 withscores
zadd a 1 x 2 y 3 z
zadd b 10 y 20 z 30 w
sadd s2 y w q
zunion 2 a b
zunion 2 a b withscores
zunion 2 a b weights 2 3 withscores
zunion 2 a b aggregate min withscores
zunion 2 a b aggregate max withscores
zunion 3 a b s2 withscores
zinter 2 a b withscores
zinter 3 a b s2 withscores
zinter 2 a b weights 1 -1 aggregate sum withscores
zdiff 2 a b withscores
zdiff 2 b s2 withscores
zdiff 1 a
zintercard 2 a b
zintercard 3 a b s2
zintercard 2 a b limit 1
zintercard 2 a b limit -1
zintercard 2 a b limit x
zunion 0 a
zunion -1 a
zunion x a
zunion 3 a b
zunion 2 a b weights 1
zunion 2 a b weights 1 x
zunion 2 a b aggregate foo
zunion 2 a b aggregate
zunion 2 a b withscores foo
zdiff 2 a b weights 1 2
zinter 2 a b limit 1
zintercard 2 a b withscores
set str v
zunion 2 a str
zunion 2 a str weights x
zunionstore d 2 a b
zrange d 0 -1 withscores
zinterstore d 2 a b weights 2 2
zrange d 0 -1 withscores
zdiffstore d 2 a b
zrange d 0 -1 withscores
zdiffstore d 2 a a
exists d
zunionstore d 2 a str
zunionstore d 2 a b withscores
zunionstore str 1 a
type str
zrange str 0 -1 withscores
zadd inf 1 x
zadd ninf 1 x
zunion 2 inf ninf weights inf -inf withscores
zinter 2 inf ninf weights inf -inf withscores
zinter 2 inf ninf weights inf -inf aggregate min withscores
zinter 2 inf ninf weights inf -inf aggregate max withscores
zadd big2 1e16 x
zadd one 1 x
zadd mbig -1e16 x
zunion 3 big2 one mbig withscores
zunion 3 one big2 mbig withscores
zunion 3 mbig one big2 withscores
zunion 3 mbig big2 one withscores
zinter 3 big2 one mbig withscores
zinter 3 one big2 mbig withscores
zinter 3 mbig one big2 withscores
zrangestore dst a 0 -1
zrange dst 0 -1 withscores
zrangestore dst a 0 1 rev
zrange dst 0 -1 withscores
zrangestore dst a (1 +inf byscore limit 0 1
zrange dst 0 -1 withscores
zrangestore dst a 0 -1 withscores
zrangestore dst nokey 0 -1
exists dst
zrangestore dst str 0 -1
zrangestore dst a [x [z bylex
zrange dst 0 -1 withscores
zmpop 1 a min
zmpop 2 nokey a max count 5
exists a
zmpop 2 nokey nokey2 min
zmpop 1 str min
zmpop 0 a min
zmpop 1 a foo
zmpop 1 b min count 0
zmpop 1 b min count 1 count 1
zmpop 2 b
zmpop 1 b min count
zrandmember nokey
zrandmember nokey 5
zrandmember str
zrandmember b 0
zrandmember b
zrandmember b 2
zrandmember b -5
zrandmember b 5 withscores
zrandmember b -5 withscores
zrandmember b -9223372036854775808
zrandmember b 9223372036854775807 withscores
zrandmember b 1 withscores foo
zrandmember b x
type z
scan 0 type zset count 1000
scan 0 type ZSET count 1000
object encoding z
object refcount z
object freq z
command getkeys zunionstore dst 2 a b
command getkeysandflags zunionstore dst 2 a b
command getkeysandflags zunionstore dst 2a a b
command getkeysandflags zunion 2 a b
command getkeysandflags zmpop 2 a b min
command getkeysandflags zrangestore d s 0 1
command getkeys zinter 0 a
zrange z
zrandmember
zinter
zrangestore a b c
zadd k 1 x 2 y
type k
get k
append k x
incr k
strlen k
hset k f v
lpush k a
sadd k a
smembers k
getdel k
setnx k x
expire k 100
zadd k 3 z
ttl k
zincrby k 1 x
ttl k
zrem k z
ttl k
zunionstore k9 1 k
ttl k9
persist k
ttl k
rename k k2
zrange k2 0 -1 withscores
copy k2 k3
zadd k3 9 q
zrange k2 0 -1 withscores
move k3 1
select 1
zrange k3 0 -1 withscores
zpopmin k3
select 0
set k2 x
type k2
zadd k2 1 a
del k2
zadd k2 1 a
type k2
memory usage k2
memory usage lex samples 0
""".strip().split("\n")] + [
    # the bytes of members
    [b"ZADD", b"\x00k", b"1", b"\x00", b"2", b"\r\n", b"0", b"", b"3", b"\xff\xfe", b"4", b"\x00"],
    [b"ZRANGE", b"\x00k", b"0", b"-1", b"WITHSCORES"], [b"ZSCORE", b"\x00k", b""], [b"ZRANK", b"\x00k", b"\x00"],
    [b"ZMSCORE", b"\x00k", b"\r\n", b"\r"], [b"ZREM", b"\x00k", b"\r\n"], [b"ZRANGE", b"\x00k", b"0", b"-1"],
    [b"ZCARD", b"\x00k"],
]


def adds(key, pairs):
    return [[b"ZADD", key] + [x for p in pairs[i:i + 100] for x in p] for i in range(0, len(pairs), 100)]


# sorted sets of many sizes, of integer scores and of fractional ones,
# made in calls of a hundred pairs, then read and written
def sizes(b, r):
    for size in (1, 100, 127, 128, 129, 1000, 20000):
        rng = random.Random(size)
        ints = [(b"%d" % rng.randint(-10**6, 10**6), b"m%d" % i) for i in range(size)]
        fracs = [(b"%.3f" % rng.uniform(-100, 100), b"f%d" % i) for i in range(size)]
        ki, kf = b"zi%d" % size, b"zf%d" % size
        for key, pairs in ((ki, ints), (kf, fracs)):
            for cmd in adds(key, pairs):
                same(b, r, cmd)
        s, m = ints[size // 2]
        q = b"%d" % (size // 3)
        for cmd in ([b"OBJECT", b"ENCODING", ki], [b"OBJECT", b"ENCODING", kf], [b"ZCARD", ki], [b"ZCARD", kf],
                    [b"ZSCORE", ki, m], [b"ZSCORE", ki, b"x"], [b"ZMSCORE", kf, b"f0", b"x", b"f1"], [b"ZRANK", ki, m],
                    [b"ZREVRANK", kf, b"f0"], [b"ZRANGE", ki, b"0", b"9", b"WITHSCORES"], [b"ZRANGE", kf, b"-10", b"-1"],
                    [b"ZRANGE", ki, q, b"-" + q, b"REV"], [b"ZRANGE", ki, b"(-1000", b"1000", b"BYSCORE", b"LIMIT", b"2", b"5"],
                    [b"ZRANGE", kf, b"+inf", b"(0", b"BYSCORE", b"REV", b"LIMIT", b"0", b"7", b"WITHSCORES"],
                    [b"ZRANGEBYSCORE", ki, s, b"+inf", b"LIMIT", b"0", b"3"], [b"ZCOUNT", ki, b"-1000", b"(1000"],
                    [b"ZCOUNT", kf, b"(-50.5", b"50"], [b"ZREVRANGEBYSCORE", kf, b"0", b"-inf", b"LIMIT", b"1", b"2"],
                    [b"ZSCAN", ki, b"0", b"COUNT", b"10"], [b"ZSCAN", kf, b"0", b"MATCH", b"f1*"],
                    [b"ZRANDMEMBER", ki], [b"ZRANDMEMBER", kf, b"5", b"WITHSCORES"], [b"ZRANDMEMBER", ki, b"-7"],
                    [b"ZRANDMEMBER", kf, b"%d" % size], [b"ZRANDMEMBER", ki, b"%d" % (size + 5), b"WITHSCORES"],
                    [b"ZRANDMEMBER", kf, b"-%d" % (size + 5)],
                    [b"ZUNIONSTORE", ki + b"u", b"2", ki, kf, b"WEIGHTS", b"1", b"2"], [b"ZCARD", ki + b"u"],
                    [b"OBJECT", b"ENCODING", ki + b"u"], [b"ZINTERSTORE", ki + b"n", b"2", ki, ki, b"AGGREGATE", b"MAX"],
                    [b"OBJECT", b"ENCODING", ki + b"n"], [b"ZDIFFSTORE", kf + b"d", b"2", kf, ki], [b"ZCARD", kf + b"d"],
                    [b"ZINTERCARD", b"2", ki, ki + b"n", b"LIMIT", b"3"], [b"ZRANGESTORE", ki + b"r", ki, b"0", q],
                    [b"OBJECT", b"ENCODING", ki + b"r"], [b"ZRANGESTORE", kf + b"r", kf, b"-inf", b"(0", b"BYSCORE"],
                    [b"ZCARD", kf + b"r"], [b"ZINCRBY", ki, b"0.5", m], [b"ZADD", ki, b"GT", b"CH", b"0", m, b"9", b"m0"],
                    [b"ZREMRANGEBYRANK", ki, b"0", b"2"], [b"ZREMRANGEBYSCORE", kf, b"(-1", b"1"],
                    [b"ZPOPMIN", ki], [b"ZPOPMAX", kf, b"3"], [b"ZMPOP", b"2", b"nope", ki, b"MAX", b"COUNT", b"4"],
                    [b"ZREM", kf] + [p[1] for p in fracs[:size // 2]], [b"ZCARD", kf], [b"OBJECT", b"ENCODING", kf],
                    [b"MEMORY", b"USAGE", ki], [b"MEMORY", b"USAGE", kf]):
            same(b, r, cmd)
        if size <= 1000:
            for key in (ki, kf, ki + b"u", ki + b"n", kf + b"d", ki + b"r", kf + b"r"):
                same(b, r, [b"ZRANGE", key, b"0", b"-1", b"WITHSCORES"])
                same(b, r, [b"ZSCAN", key, b"0"])
            same(b, r, [b"ZUNION", b"3", ki, kf, ki + b"u", b"WITHSCORES"])
            same(b, r, [b"ZINTER", b"2", ki, ki + b"n", b"WITHSCORES"])
            same(b, r, [b"ZDIFF", b"2", ki + b"u", kf, b"WITHSCORES"])
    # a listpack grown past 128 elements by one at a time, and taken back;
    # a member longer than 64 bytes
    for i in range(132):
        same(b, r, [b"ZADD", b"grow", b"%d" % (i % 7), b"g%d" % i])
        if i in (126, 127, 128, 129):
            same(b, r, [b"OBJECT", b"ENCODING", b"grow"])
    for i in range(130):
        same(b, r, [b"ZREM", b"grow", b"g%d" % i])
    for cmd in ([b"OBJECT", b"ENCODING", b"grow"], [b"ZRANGE", b"grow", b"0", b"-1", b"WITHSCORES"],
                [b"ZADD", b"long", b"1", b"x" * 64], [b"OBJECT", b"ENCODING", b"long"],
                [b"ZADD", b"long", b"2", b"y" * 65], [b"OBJECT", b"ENCODING", b"long"],
                [b"ZRANGE", b"long", b"0", b"-1", b"WITHSCORES"], [b"ZRANGESTORE", b"short", b"long", b"0", b"0"],
                [b"OBJECT", b"ENCODING", b"short"], [b"ZUNIONSTORE", b"short2", b"1", b"long"],
                [b"OBJECT", b"ENCODING", b"short2"]):
        same(b, r, cmd)


# a sorted set whose time passed: a read finds nothing, a write makes it
# anew, a STORE or ZMPOP takes it as not there, as a source or a
# destination
def expired(b, r):
    for c in (b, r):
        for cmd in ([b"ZADD", b"x1", b"1", b"a", b"2", b"b"], [b"PEXPIRE", b"x1", b"50"],
                    [b"SET", b"x2", b"str", b"PX", b"50"], [b"ZADD", b"x3", b"1", b"q"], [b"PEXPIRE", b"x3", b"50"],
                    [b"ZADD", b"x4", b"1", b"a"], [b"PEXPIRE", b"x4", b"50"], [b"HSET", b"x5", b"f", b"v"],
                    [b"PEXPIRE", b"x5", b"50"], [b"ZADD", b"x6", b"5", b"a", b"6", b"z"], [b"PEXPIRE", b"x6", b"50"],
                    [b"ZADD", b"x7", b"1", b"p"], [b"PEXPIRE", b"x7", b"50"], [b"SADD", b"x8", b"a"],
                    [b"PEXPIRE", b"x8", b"50"], [b"ZADD", b"em", b"1", b"a", b"2", b"b", b"3", b"c"]):
            run(c, cmd)
    time.sleep(0.2)
    for cmd in ([b"ZCARD", b"x1"], [b"ZRANGE", b"x1", b"0", b"-1"], [b"ZSCORE", b"x1", b"a"], [b"ZADD", b"x1", b"XX", b"1", b"a"],
                [b"EXISTS", b"x1"], [b"ZINCRBY", b"x1", b"2", b"n"], [b"ZRANGE", b"x1", b"0", b"-1", b"WITHSCORES"],
                [b"TTL", b"x1"], [b"ZADD", b"x2", b"1", b"a"], [b"TYPE", b"x2"], [b"ZUNIONSTORE", b"x3", b"1", b"em"],
                [b"ZRANGE", b"x3", b"0", b"-1", b"WITHSCORES"], [b"TTL", b"x3"], [b"ZRANGESTORE", b"x4", b"x6", b"0", b"-1"],
                [b"EXISTS", b"x4"], [b"ZRANGESTORE", b"x5", b"em", b"0", b"1"], [b"TYPE", b"x5"],
                [b"ZRANGE", b"x5", b"0", b"-1", b"WITHSCORES"], [b"ZUNION", b"2", b"em", b"x6", b"WITHSCORES"],
                [b"ZINTER", b"2", b"em", b"x6"], [b"ZDIFF", b"2", b"x6", b"em"], [b"ZINTERCARD", b"2", b"em", b"x6"],
                [b"ZMPOP", b"3", b"x7", b"x6", b"em", b"MIN"], [b"ZPOPMIN", b"x7"], [b"ZREM", b"x7", b"p"],
                [b"ZREMRANGEBYRANK", b"x7", b"0", b"-1"], [b"ZRANDMEMBER", b"x7", b"2"], [b"ZADD", b"x8", b"1", b"a"],
                [b"TYPE", b"x8"], [b"ZINTERSTORE", b"x6", b"2", b"em", b"x8"], [b"EXISTS", b"x6"],
                [b"ZRANGE", b"em", b"0", b"-1", b"WITHSCORES"]):
        same(b, r, cmd)


KEYS = [b"r1", b"r2", b"r3", b"rs"]
LEX = [b"lx1", b"lx2"]
MEMS = [b"a", b"b", b"c", b"d", b"1", b"2", b"", b"\x00\r\n"]
SCORES = [b"0", b"1", b"2", b"-1", b"-3", b"1.5", b"-2.25", b"inf", b"-inf", b"+inf", b"1e300", b"0.1",
          b"100000000000000000", b"4611686018427387904", b"x", b"nan"]


def rand_cmd(r):
    key = r.choice(KEYS)
    lk = r.choice(LEX)
    ks = lambda: [r.choice(KEYS) for _ in range(r.randint(1, 3))]
    m = lambda: r.choice(MEMS) if r.random() < 0.95 else b"x" * r.randint(1, 80)
    sc = lambda: r.choice(SCORES)
    num = lambda: r.choice([b"0", b"1", b"2", b"3", b"-1", b"-2", b"5", b"-5", b"100", b"-100", b"x"])
    opts = lambda: r.sample([b"NX", b"XX", b"GT", b"LT", b"CH", b"INCR"], r.choice([0, 0, 0, 1, 1, 2]))
    k = r.random()
    if k < 0.16:
        return [b"ZADD", key] + opts() + [x for _ in range(r.randint(1, 4)) for x in (sc(), m())]
    if k < 0.18:
        return [b"ZADD", key] + [x for i in range(r.randint(60, 150)) for x in (b"%d" % r.randint(-50, 50), b"n%d" % i)]
    if k < 0.22:
        return [b"ZADD", lk] + r.choice([[], [b"NX"], [b"CH"]]) + [x for _ in range(r.randint(1, 3)) for x in (b"0", m())]
    if k < 0.26:
        return [b"ZINCRBY", key, sc(), m()]
    if k < 0.32:
        return [b"ZREM", r.choice([key, lk])] + [m() for _ in range(r.randint(1, 4))]
    if k < 0.37:
        return [r.choice([b"ZPOPMIN", b"ZPOPMAX"]), key] + ([num()] if r.random() < 0.6 else [])
    if k < 0.41:
        return [b"ZRANDMEMBER", key] + ([num()] + ([b"WITHSCORES"] if r.random() < 0.5 else []) if r.random() < 0.7 else [])
    if k < 0.47:
        return [b"ZRANGE", key, rnd_lnum(r), rnd_lnum(r)] + rnd_zrange_opts(r, b"REV")
    if k < 0.53:
        return [b"ZRANGE", key, rnd_zbound(r), rnd_zbound(r), b"BYSCORE"] + rnd_zrange_opts(r, b"BYSCORE")
    if k < 0.57:
        return [b"ZRANGE", lk, rnd_zlex(r), rnd_zlex(r), b"BYLEX"] + rnd_zrange_opts(r, b"BYLEX")
    if k < 0.6:
        return [r.choice([b"ZREMRANGEBYRANK", b"ZREMRANGEBYSCORE"]), key] + \
            ([rnd_lnum(r), rnd_lnum(r)] if r.random() < 0.5 else [rnd_zbound(r), rnd_zbound(r)])
    if k < 0.62:
        return [b"ZREMRANGEBYLEX", lk, rnd_zlex(r), rnd_zlex(r)]
    if k < 0.68:
        return rnd_zop(r, ks(), False)
    if k < 0.74:
        return [r.choice([b"ZUNIONSTORE", b"ZINTERSTORE", b"ZDIFFSTORE"]), r.choice(KEYS)] + rnd_zop(r, ks(), False)[1:]
    if k < 0.77:
        return [b"ZRANGESTORE", r.choice(KEYS), key, rnd_lnum(r), rnd_lnum(r)] + r.choice([[], [b"REV"]])
    if k < 0.8:
        return rnd_zmpop(r, ks())
    if k < 0.83:
        return [r.choice([b"SET", b"DEL", b"EXPIRE", b"SADD"]), key] + ([b"str"] if r.random() < 0.5 else [b"1000"])
    if k < 0.86:
        return [b"ZSCAN", key, b"0"] + r.choice([[], [b"COUNT", b"2"], [b"MATCH", b"*1*"], [b"MATCH", b"[ab]"]])
    return r.choice([[b"ZCARD", key], [b"ZSCORE", key, m()], [b"ZMSCORE", key, m(), m()], [b"ZRANK", key, m()],
                     [b"ZREVRANK", key, m()], [b"ZCOUNT", key, rnd_zbound(r), rnd_zbound(r)],
                     [b"ZLEXCOUNT", lk, rnd_zlex(r), rnd_zlex(r)], [b"TYPE", key], [b"EXISTS", key], [b"TTL", key],
                     [b"OBJECT", b"ENCODING", key], [b"ZRANGE", key, b"0", b"-1", b"WITHSCORES"]])


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
    for key in KEYS + LEX:
        same(b, rd, [b"ZRANGE", key, b"0", b"-1", b"WITHSCORES"])
    for c in (b, rd):
        run(c, [b"FLUSHALL"])
    if bad:
        sys.exit("FAIL: %d of %d" % (bad, n))
    print("OK: %d sorted-set commands, each answered as Redis answers it" % n)


if __name__ == "__main__":
    main()
