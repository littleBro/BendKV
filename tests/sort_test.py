#!/usr/bin/env python3
"""SORT and SORT_RO against Redis: a script of the cases Redis's own
tests and sort.c make (BY with and without a '*', hash fields, GET with
"#" and with patterns that name nothing, LIMIT at its edges, STORE that
makes, replaces and deletes its destination, the errors and their
order), lists, sets and sorted sets of many sizes sorted every way, and
then random SORTs of random keys, replies compared one by one, and a
STORE's destination read back after it.

Where Redis's order is not its own to keep, the replies are compared as
multisets: a set kept as a hashtable left in its order (BY a constant,
no STORE), ALPHA by a pattern's values among elements whose values tie
(or are not there) where the elements come in the order of a hashtable
(a set's, a sorted set's: Redis sorts a sorted set's dict, BendKV its
order), and a sort BY a pattern under a LIMIT that does not take all,
which Redis sorts with its own pqsort, not stable, where values tie;
where such a sort or a set left in its order takes a LIMIT, the elements
it takes differ too, and only the replies' sizes are compared.

Redis reads a score's range error from errno without clearing it first,
so a SORT after one that met a range error (an overflow, a tiny number)
fails on scores that are numbers too, until a command clears errno:
each SORT here runs after an INCRBYFLOAT, which clears it (string2ld).

    python3 tests/sort_test.py --bendkv 6380 --redis 6390 [--rounds 2000] [--seed 1]
"""
import argparse
import random
import sys

from diff_test import Conn

bad = 0
n = 0


def run(c, cmd):
    c.send([cmd])
    return c.reply()


ctx = None


def fail(cmd, x, y):
    global bad
    bad += 1
    if bad <= 20:
        after = " (after %r)" % b" ".join(ctx)[:200] if ctx else ""
        print("FAIL: %r%s: BendKV %r, Redis %r" % (b" ".join(cmd)[:200], after, str(x)[:300], str(y)[:300]))


def bag(rep):
    if rep[0] in (b"*", b"~") and rep[1] is not None:
        return sorted(repr(x) for x in rep[1])
    return rep


def size(rep):
    if rep[0] in (b"*", b"~") and rep[1] is not None:
        return (rep[0], len(rep[1]))
    return rep


# how two replies are compared: as they are, as multisets, or by size
def alike(x, y, mode):
    if mode == "bag":
        return bag(x) == bag(y)
    if mode == "size":
        return size(x) == size(y)
    return x == y


def same(b, r, cmd, mode="exact"):
    global n
    n += 1
    x, y = run(b, cmd), run(r, cmd)
    if not alike(x, y, mode):
        fail(cmd, x, y)


# how far Redis's order is its own to keep in a SORT's reply (the
# docstring): kind and enc are the type and the encoding of its key
def mode_of(cmd, kind, enc):
    up = [x.upper().split(b"\x00")[0] for x in cmd]
    pats, i = [], 2
    while i < len(cmd):
        if up[i] == b"LIMIT":
            i += 3
        elif up[i] in (b"BY", b"GET", b"STORE"):
            if up[i] == b"BY" and i + 1 < len(cmd):
                pats.append(cmd[i + 1])
            i += 2
        else:
            i += 1
    lim = b"LIMIT" in up
    store = b"STORE" in up and up[0] == b"SORT"
    nostar = any(b"*" not in p.split(b"\x00")[0] for p in pats)
    star = bool(pats) and not nostar
    alpha = b"ALPHA" in up
    hashed = (kind == b"set" and enc != b"intset") or kind == b"zset"
    loose = "size" if lim else "bag"
    if nostar:
        return loose if kind == b"set" and enc != b"intset" and not store else "exact"
    if alpha and hashed:
        return loose
    if alpha and star and lim:
        return "size"
    return "exact"


# a SORT on both servers, errno cleared on each first; with STORE, its
# destination read back
def sort_same(b, r, cmd, mode=None):
    for c in (b, r):
        run(c, [b"INCRBYFLOAT", b"errno_reset", b"0"])
    if mode is None:
        kind = run(r, [b"TYPE", cmd[1]])[1] if len(cmd) > 1 else b""
        enc = run(r, [b"OBJECT", b"ENCODING", cmd[1]])[1] if len(cmd) > 1 else b""
        mode = mode_of(cmd, kind, enc)
    same(b, r, cmd, mode)
    up = [x.upper() for x in cmd]
    if up[:1] == [b"SORT"] and b"STORE" in up:
        dst = cmd[len(up) - 1 - up[::-1].index(b"STORE") + 1] if up[-1] != b"STORE" else None
        if dst is not None:
            global ctx
            ctx = cmd
            same(b, r, [b"TYPE", dst])
            same(b, r, [b"LRANGE", dst, b"0", b"-1"], mode)
            ctx = None
            got = run(r, [b"LRANGE", dst, b"0", b"-1"])
            if mode != "exact" and got[0] == b"*":
                # the destination as Redis left it, for the commands after
                run(b, [b"DEL", dst])
                vs = got[1] or []
                for i in range(0, len(vs), 100):
                    run(b, [b"RPUSH", dst] + [v for _, v in vs[i:i + 100]])


def both(b, r, cmd):
    run(b, cmd)
    run(r, cmd)


def words(text):
    return [[w.encode() for w in line.split()] for line in text.strip().split("\n")]


# the cases of Redis's tests (tests/unit/sort.tcl) and of sort.c, on keys
# made the same on both servers
SCRIPT = words("""
del tosort l s z
rpush tosort 3 1 2 10 5
set weight_1 50
set weight_2 40
set weight_3 30
set weight_10 20
hset wobj_1 weight 15
hset wobj_2 weight 25
hset wobj_3 weight 35
hset wobj_5 weight 5
sort tosort
sort tosort desc
sort tosort alpha
sort tosort alpha desc
sort tosort by weight_*
sort tosort by weight_* desc
sort tosort by wobj_*->weight
sort tosort by wobj_*->weight desc
sort tosort by weight_* limit 1 2
sort tosort by weight_* limit 0 0
sort tosort by weight_* limit -5 2
sort tosort by weight_* limit 2 -1
sort tosort by weight_* limit 4 10
sort tosort by weight_* limit 5 10
sort tosort by weight_* limit 100 1
sort tosort limit 2 2
sort tosort get #
sort tosort get # get weight_*
sort tosort get weight_* get wobj_*->weight get #
sort tosort get nokey
sort tosort get nokey*
sort tosort get wobj_*->
sort tosort get wobj_*->nofield
sort tosort by nosort
sort tosort by nosort desc
sort tosort by nosort limit 1 2
sort tosort by nosort desc limit 1 2
sort tosort by nosort limit 10 2
sort tosort by nosort limit -10 100
sort tosort by nosort by weight_*
sort tosort by weight_* by nosort
sort tosort by weight_* get # store dst
lrange dst 0 -1
type dst
sort tosort by nosort store dst
lrange dst 0 -1
sort tosort by weight_* limit 0 2 get weight_* get nokey store dst
lrange dst 0 -1
sort tosort limit 10 10 store dst
exists dst
sort nokey store dst
exists dst
set dst x
sort tosort store dst
type dst
lrange dst 0 -1
expire dst 100
sort tosort desc store dst
ttl dst
sort tosort store dst store dst2
exists dst
lrange dst2 0 -1
sort tosort store
sort tosort limit
sort tosort limit 1
sort tosort limit a 1
sort tosort limit 1 b
sort tosort limit 1 9223372036854775807
sort tosort limit 1 9223372036854775808
sort tosort limit -9223372036854775808 1
sort tosort by
sort tosort get
sort tosort foo
sort tosort asc desc asc
sort tosort alpha alpha
sort_ro tosort
sort_ro tosort desc limit 1 2
sort_ro tosort store dst
sort_ro tosort by weight_* get #
sort_ro
sort
set str x
sort str
sort str store dst
sort_ro str
sort str by nosort
sort str foo
sort str limit a b
hset h f v
sort h
sadd s 5 3 1 4 2
sort s
sort s desc
sort s alpha
sort s by nosort
sort s by nosort desc
sort s by nosort store dst
lrange dst 0 -1
sort s by nosort store dst desc
lrange dst 0 -1
sort s by nosort store dst limit 1 2
lrange dst 0 -1
sort s by weight_* get #
zadd z 1 a 5 b 2 c 10 d 3 e
sort z alpha
sort z alpha desc
sort z by nosort
sort z by nosort desc
sort z by nosort asc limit 0 1
sort z by nosort desc limit 0 1
sort z by nosort asc limit 0 2
sort z by nosort desc limit 0 2
sort z by nosort limit 5 10
sort z by nosort limit -10 100
sort z by nosort desc limit 1 3
sort z by nosort store dst
lrange dst 0 -1
sort z
rpush nums 1.1 5.10 3.10 7.44 2.1 5.75 6.12 0.25 1.15
sort nums
sort nums desc
rpush mixed 10 2 1 3
sort mixed alpha
sadd bad 1 2 3 4 not-a-double
sort bad
sort bad store dst
sort bad alpha
sort bad by nosort
sadd sc 1 2 3 4
mset score:1 10 score:2 20 score:3 30 score:4 not-a-double
sort sc by score:*
sort sc by score:* get #
sort sc by score:* alpha
rpush lp a
set x:a-> 100
sort lp by num get x:*->
sort_ro lp by nosort get x:*->
rpush testa 2 1 4 3 5
sort testa by nosort
sort testa by nosort store testb
lrange testb 0 -1
sort testa by nosort limit 0 3 store testb
lrange testb 0 -1
rpush L 0 1 2
sort_ro L by a limit 2 9223372036854775807
sort_ro L by a limit 2 2147483647
rpush ties b a c
mset t_a 1 t_b 1 t_c 1
sort ties by t_*
sort ties by t_* desc
sort ties by t_* alpha
sort ties by t_* alpha desc
sort ties by nothere_* alpha
sort ties by nothere_*
command getkeys sort abc store def
command getkeys sort_ro abc
command getkeys sort abc store invalid store stillbad store def
command getkeys sort abc limit store x store
command getkeys sort abc by store get store store y
command getkeysandflags sort abc store def
command getkeysandflags sort_ro abc by x
command getkeys sort
command info sort sort_ro
command docs sort_ro
""") + [
    # the bytes of elements and of patterns: a NUL ends what strtod, strchr,
    # strstr and strcoll read, a pattern's '*' and "->" count before it
    [b"DEL", b"nb"], [b"RPUSH", b"nb", b"b\x00z", b"a", b"b\x00a", b"", b"\xff", b"A"],
    [b"SORT", b"nb", b"ALPHA"], [b"SORT", b"nb", b"ALPHA", b"STORE", b"nbs"], [b"LRANGE", b"nbs", b"0", b"-1"],
    [b"SORT", b"nb", b"ALPHA", b"DESC"],
    [b"SET", b"n_\x00x", b"1"], [b"SET", b"n_a", b"2"],
    [b"SORT", b"nb", b"BY", b"n_*", b"GET", b"#", b"GET", b"n_*"],
    [b"SORT", b"nb", b"BY", b"n_\x00*"], [b"SORT", b"nb", b"BY", b"n_\x00*", b"DESC"],
    [b"SORT", b"nb", b"GET", b"#\x00junk"], [b"SORT", b"nb", b"GET", b"\x00*"],
    [b"HSET", b"hb_a", b"f\x00g", b"1", b"f", b"2"], [b"SORT", b"nb", b"ALPHA", b"GET", b"hb_*->f\x00g", b"GET", b"hb_*->f"],
    [b"SORT", b"nb", b"ALPHA", b"GET", b"hb_*-\x00>f"], [b"SORT", b"nb", b"ALPHA", b"GET", b"hb_*->\x00f"],
    [b"RPUSH", b"sn", b"1\x002", b"3", b"0x1p2"], [b"SORT", b"sn"], [b"SORT", b"sn", b"DESC"],
    [b"SORT", b"nb", b"ASC\x00X"], [b"SORT", b"nb", b"LIMIT\x00", b"0", b"1"],
    [b"SORT_RO", b"nb", b"STORE\x00", b"x"],
    # scores as strtod reads them: blanks first, then to the end or a NUL;
    # no NaN, no range error; a value strtod reads nothing of, if empty
    [b"RPUSH", b"ws", b"1", b"2", b"3", b"4", b"5", b"6"],
    [b"MSET", b"w_1", b" 3", b"w_2", b"3 ", b"w_3", b"\t-1e2", b"w_4", b"0x10", b"w_5", b"inf", b"w_6", b"-inf"],
    [b"SORT", b"ws", b"BY", b"w_*"], [b"SORT", b"ws", b"BY", b"w_*", b"DESC"],
    [b"MSET", b"w_2", b"3", b"w_1", b"nan"], [b"SORT", b"ws", b"BY", b"w_*"],
    [b"SET", b"w_1", b"1e400"], [b"SORT", b"ws", b"BY", b"w_*"],
    [b"SET", b"w_1", b"-1e400"], [b"SORT", b"ws", b"BY", b"w_*"],
    [b"SET", b"w_1", b"1e-400"], [b"SORT", b"ws", b"BY", b"w_*"],
    [b"SET", b"w_1", b"4.9e-324"], [b"SORT", b"ws", b"BY", b"w_*"],
    [b"SET", b"w_1", b"2.2250738585072014e-308"], [b"SORT", b"ws", b"BY", b"w_*"],
    [b"SET", b"w_1", b""], [b"SORT", b"ws", b"BY", b"w_*"],
    [b"SET", b"w_1", b"   "], [b"SORT", b"ws", b"BY", b"w_*"],
    [b"SET", b"w_1", b"1\x00x"], [b"SORT", b"ws", b"BY", b"w_*"],
    [b"SET", b"w_1", b"infinity"], [b"SORT", b"ws", b"BY", b"w_*"],
    [b"SET", b"w_1", b"nan(123)"], [b"SORT", b"ws", b"BY", b"w_*"],
    [b"MSET", b"w_1", b"-0", b"w_2", b"0", b"w_3", b"+0", b"w_4", b"0.0", b"w_5", b"-0.0", b"w_6", b"0e9"],
    [b"SORT", b"ws", b"BY", b"w_*"], [b"SORT", b"ws", b"BY", b"w_*", b"DESC"],
    [b"SORT", b"ws", b"BY", b"w_*", b"STORE", b"wd"], [b"LRANGE", b"wd", b"0", b"-1"],
]


def script(b, r):
    for c in (b, r):
        run(c, [b"FLUSHALL"])
    for cmd in SCRIPT:
        if cmd[:1] and cmd[0].upper() in (b"SORT", b"SORT_RO"):
            sort_same(b, r, cmd)
        else:
            same(b, r, cmd)


# lists, sets and sorted sets of many sizes (an intset and a listpack, a
# hashtable and a skiplist past their limits), sorted every way, with
# weights all different, as Redis's own tests make them
def sizes(b, r):
    for c in (b, r):
        run(c, [b"FLUSHALL"])
    for size in (0, 1, 16, 100, 1000, 10000):
        rng = random.Random(size)
        seen = set()
        ws = []
        for i in range(size):
            while True:
                w = b"%d" % rng.randint(0, 10**6) if rng.random() < 0.5 else (b"%r" % rng.random())
                if w not in seen:
                    break
            seen.add(w)
            ws.append(w)
        for i in range(0, size, 500):
            chunk = range(i, min(size, i + 500))
            both(b, r, [b"RPUSH", b"l%d" % size] + [b"%d" % j for j in chunk])
            both(b, r, [b"SADD", b"s%d" % size] + [b"%d" % j for j in chunk])
            both(b, r, [b"ZADD", b"z%d" % size] + [x for j in chunk for x in (ws[j], b"%d" % j)])
            both(b, r, [b"MSET"] + [x for j in chunk for x in (b"w%d_%d" % (size, j), ws[j])])
            for j in chunk:
                if j % 7 == 0:
                    both(b, r, [b"HSET", b"o%d_%d" % (size, j), b"w", ws[j]])
        for key in (b"l%d" % size, b"s%d" % size, b"z%d" % size):
            for opts in ([], [b"DESC"], [b"ALPHA"], [b"ALPHA", b"DESC"], [b"BY", b"w%d_*" % size],
                         [b"BY", b"w%d_*" % size, b"DESC"], [b"BY", b"w%d_*" % size, b"LIMIT", b"5", b"5"],
                         [b"BY", b"w%d_*" % size, b"ALPHA"], [b"BY", b"o%d_*->w" % size],
                         [b"BY", b"o%d_*->w" % size, b"LIMIT", b"0", b"10", b"GET", b"#", b"GET", b"o%d_*->w" % size],
                         [b"LIMIT", b"0", b"10"], [b"LIMIT", b"%d" % (size // 2), b"-1", b"DESC"],
                         [b"BY", b"nosort", b"LIMIT", b"0", b"10"], [b"BY", b"nosort"],
                         [b"GET", b"#", b"GET", b"w%d_*" % size, b"LIMIT", b"3", b"4"]):
                sort_same(b, r, [b"SORT", key] + opts)
                if size <= 1000:
                    sort_same(b, r, [b"SORT", key] + opts + [b"STORE", b"dst"])


KEYS = [b"rl", b"rs", b"rz", b"rstr", b"rh", b"none"]
ELEMS = [b"1", b"2", b"3", b"10", b"-1", b"1.5", b"a", b"b", b"B", b"", b"x\x00y", b"x\x00z", b" 7", b"inf",
         b"nan", b"0x10", b"1e5"]


def rnd_pat(rng):
    return rng.choice([b"w_*", b"h_*->f", b"h_*->g", b"nosort", b"#", b"w_*_x", b"*", b"h_*->", b"w_\x00*",
                       b"missing_*", b"*->f"])


def rnd_lim(rng):
    return rng.choice([b"0", b"1", b"2", b"-1", b"-5", b"3", b"100", b"9223372036854775807", b"x"])


def rand_sort(rng):
    ro = rng.random() < 0.2
    cmd = [b"SORT_RO" if ro else b"SORT", rng.choice(KEYS)]
    for _ in range(rng.randint(0, 5)):
        k = rng.random()
        if k < 0.15:
            cmd += [rng.choice([b"ASC", b"desc", b"DeSc"])]
        elif k < 0.3:
            cmd += [rng.choice([b"ALPHA", b"alpha"])]
        elif k < 0.45:
            cmd += [b"LIMIT", rnd_lim(rng), rnd_lim(rng)]
        elif k < 0.6:
            cmd += [b"BY", rnd_pat(rng)]
        elif k < 0.8:
            cmd += [b"GET", rnd_pat(rng)]
        elif k < 0.95:
            cmd += [b"STORE", rng.choice([b"dst", b"rl", b"rstr"])]
        else:
            cmd += [rng.choice([b"LIMIT", b"BY", b"GET", b"STORE", b"FOO"])]
    return cmd


def fill(c, rng):
    run(c, [b"DEL"] + KEYS + [b"dst"])
    run(c, [b"RPUSH", b"rl"] + [rng.choice(ELEMS) for _ in range(rng.randint(1, 12))])
    run(c, [b"SADD", b"rs"] + [rng.choice(ELEMS) for _ in range(rng.randint(1, 12))])
    run(c, [b"ZADD", b"rz"] + [x for _ in range(rng.randint(1, 12)) for x in (b"%d" % rng.randint(0, 5), rng.choice(ELEMS))])
    run(c, [b"SET", b"rstr", b"v"])
    run(c, [b"HSET", b"rh", b"f", b"v"])
    for e in ELEMS:
        if rng.random() < 0.7:
            run(c, [b"SET", b"w_" + e, rng.choice(ELEMS)])
        else:
            run(c, [b"DEL", b"w_" + e])
        if rng.random() < 0.5:
            run(c, [b"HSET", b"h_" + e, b"f", rng.choice(ELEMS)])
        else:
            run(c, [b"DEL", b"h_" + e])


def rounds(b, r, count, seed):
    for i in range(count):
        if i % 50 == 0:
            st = random.Random(seed * 1000003 + i)
            fill(b, random.Random(seed * 1000003 + i))
            fill(r, st)
        rng = random.Random(seed * 7919 + i)
        sort_same(b, r, rand_sort(rng))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bendkv", type=int, default=6380)
    ap.add_argument("--redis", type=int, default=6390)
    ap.add_argument("--rounds", type=int, default=2000)
    ap.add_argument("--seed", type=int, default=1)
    a = ap.parse_args()
    b, r = Conn(a.bendkv), Conn(a.redis)
    script(b, r)
    sizes(b, r)
    rounds(b, r, a.rounds, a.seed)
    for c in (b, r):
        run(c, [b"FLUSHALL"])
    if bad:
        sys.exit("FAIL: %d of %d" % (bad, n))
    print("OK: %d SORT and SORT_RO commands, each answered as Redis answers it" % n)


if __name__ == "__main__":
    main()
