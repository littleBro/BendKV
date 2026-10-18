#!/usr/bin/env python3
"""The groups of a stream against Redis 7.2.16: XGROUP (CREATE, SETID,
DESTROY, CREATECONSUMER, DELCONSUMER, HELP), XREADGROUP, XACK, XCLAIM
and XAUTOCLAIM. Both servers run the same commands, in RESP2 and in
RESP3, each reply compared whole; after each command the streams it
names are compared (XINFO STREAM FULL, XINFO GROUPS, and each group's
XPENDING and XINFO CONSUMERS), and so is the count of changes INFO
reports (rdb_changes_since_last_save) that the command made.

- Random runs on a few keys: XADD of IDs past the clock (so that both
  servers add the same ones), XDEL and trims of entries that groups
  still have pending, DEL; groups made at "$", 0, an ID there or not,
  with MKSTREAM and ENTRIESREAD; SETID; DESTROY; consumers made and
  deleted; XREADGROUP of one key or two (or one named twice), at ">",
  at 0 or an ID (a consumer's history), with COUNT and NOACK; XACK of
  IDs pending or not; XCLAIM with IDLE, TIME, RETRYCOUNT, FORCE, JUSTID
  and LASTID; XAUTOCLAIM from 0, an ID or after one, with COUNT and
  JUSTID.
- The errors, in the order Redis meets them.
- The keyspace events, WATCH (of the groups' writes only XGROUP CREATE
  with MKSTREAM touches its key), MULTI, and XREADGROUP with BLOCK.

A time (a consumer's seen-time and active-time, a pending entry's
delivery time) is read by each server at its own now: two that differ
by less than 2 s count as the same; so do two idle times (XPENDING's,
XINFO CONSUMERS' idle and inactive). The idle times the commands give
(XCLAIM's and XAUTOCLAIM's min-idle-time, IDLE) are 0, a few ms or
past an hour, so that both servers pick the same entries.

XREADGROUP with BLOCK is served when it has entries to serve, or reads
a consumer's history; BendKV blocks on no stream yet, so where Redis
would wait it answers an error, which the test checks on BendKV alone.
In MULTI both answer a null array. A syntax error XGROUP finds once
its key and group are read (CREATE or SETID with too many words)
names the subcommand as BendKV knows it (CREATE, SETID), so the test
sends those in upper case.

    python3 tests/stream_group_test.py --bendkv 6380 --redis 6390 [--seed 1] [--rounds 3000]
"""
import argparse
import random
import sys

from diff_test import Conn
from dump_test import cmd, run
from stream_dump_test import pipe

bad = 0
n = 0
U64 = 2 ** 64 - 1
# a time past the clock, so that * gives both servers one ID
BASE = 10 ** 15
# two times or idle times this close count as the same
LOOSE = 2000
# a time read at a server's now is past this (an ID is a bulk, not this)
NOW = 10 ** 12
GROUPS = ["g1", "g2", "g3"]
CONS = ["c1", "c2", "c3", "c4"]


def fail(what, x, y):
    global bad
    bad += 1
    if bad <= 40:
        print("FAIL: %s: BendKV %s, Redis %s" % (str(what)[:300], str(x)[:600], str(y)[:600]))


def near(a, b):
    return abs(int(a) - int(b)) <= LOOSE


def is_id(v):
    return v[0] == b"$" and v[1] is not None and b"-" in v[1]


# whether two replies are the same, times within LOOSE: an integer past
# NOW (a time), the integer after a bulk "idle" or "inactive" (an idle
# time, -1 only as -1), and the third of a pending entry's four (an ID,
# a consumer, the idle or delivery time, the count)
def alike(x, y):
    if x == y:
        return True
    kx, vx = x
    ky, vy = y
    if kx != ky:
        return False
    if kx == b":":
        return int(vx) > NOW and int(vy) > NOW and near(vx, vy)
    if not isinstance(vx, list) or not isinstance(vy, list) or len(vx) != len(vy):
        return False
    if len(vx) == 4 and is_id(vx[0]) and vx[2][0] == b":" == vy[2][0]:
        return vx[0] == vy[0] and vx[1] == vy[1] and vx[3] == vy[3] and near(vx[2][1], vy[2][1])
    i = 0
    while i < len(vx):
        if vx[i] == vy[i] and vx[i] in ((b"$", b"idle"), (b"$", b"inactive")) and i + 1 < len(vx):
            a, b = vx[i + 1], vy[i + 1]
            if a != b and (a[0] != b":" or b[0] != b":" or b"-1" in (a[1], b[1]) or not near(a[1], b[1])):
                return False
            i += 2
            continue
        if not alike(vx[i], vy[i]):
            return False
        i += 1
    return True


# each command to both servers, pipelined, the replies compared
def batch(b, r, cmds):
    global n
    xs, ys = pipe(b, cmds), pipe(r, cmds)
    for c, x, y in zip(cmds, xs, ys):
        n += 1
        if not alike(x, y):
            fail(b" ".join(c)[:200], x, y)
    return ys


# The count of changes
# --------------------

def changes(c):
    rep = run(c, cmd("INFO", "persistence"))
    for line in rep[1].split(b"\r\n"):
        if line.startswith(b"rdb_changes_since_last_save:"):
            return int(line.split(b":")[1])
    return None


class Dirty:
    def __init__(self, b, r):
        self.b, self.r = b, r
        self.x, self.y = changes(b), changes(r)

    # the changes since the last check, the same on both
    def check(self, what):
        global n
        n += 1
        x, y = changes(self.b), changes(self.r)
        if x - self.x != y - self.y:
            fail("the changes of %s" % what, x - self.x, y - self.y)
        self.x, self.y = x, y


# The streams as Redis holds them
# -------------------------------

def live_ids(r, k):
    rep = run(r, cmd("XRANGE", k, "-", "+"))
    if rep[0] != b"*" or not rep[1]:
        return []
    return [e[1][0][1].decode() for e in rep[1]]


def last_id(r, k):
    rep = run(r, cmd("XINFO", "STREAM", k))
    if rep[0] not in (b"*", b"%") or not rep[1]:
        return None
    kv = rep[1]
    for i in range(0, len(kv) - 1, 2):
        if kv[i][1] == b"last-generated-id":
            return kv[i + 1][1].decode()
    return None


def groups_of(r, k):
    rep = run(r, cmd("XINFO", "GROUPS", k))
    if rep[0] != b"*" or not rep[1]:
        return []
    out = []
    for g in rep[1]:
        kv = g[1]
        for i in range(0, len(kv) - 1, 2):
            if kv[i][1] == b"name":
                out.append(kv[i + 1][1].decode())
    return out


def pending_ids(r, k, g):
    rep = run(r, cmd("XPENDING", k, g, "-", "+", 1000))
    if rep[0] != b"*" or not rep[1]:
        return []
    return [e[1][0][1].decode() for e in rep[1]]


def parts(i):
    ms, sq = i.split("-")
    return int(ms), int(sq)


# the streams compared after a command on them
def same_state(b, r, ks, why):
    global n
    cs = []
    for k in ks:
        cs += [cmd("XINFO", "STREAM", k, "FULL", "COUNT", 0), cmd("XINFO", "GROUPS", k)]
        for g in GROUPS:
            cs += [cmd("XPENDING", k, g), cmd("XINFO", "CONSUMERS", k, g)]
    xs, ys = pipe(b, cs), pipe(r, cs)
    for c, x, y in zip(cs, xs, ys):
        n += 1
        if not alike(x, y):
            fail("%s after %s" % (b" ".join(c).decode(), why), x, y)


# Random commands
# ---------------

def rnd_group(rnd, r, k):
    gs = groups_of(r, k)
    if gs and rnd.random() < 0.85:
        return rnd.choice(gs)
    return rnd.choice(GROUPS + ["nog"])


# an ID some pending entry has, some entry has, or another
def rnd_some_id(rnd, r, k, g):
    x = rnd.random()
    ps = pending_ids(r, k, g)
    if ps and x < 0.5:
        return rnd.choice(ps)
    ids = live_ids(r, k)
    if ids and x < 0.8:
        return rnd.choice(ids)
    return "%d-%d" % (BASE + rnd.randint(0, 30), rnd.randint(0, 3))


# a group's ID: CREATE's and SETID's
def rnd_gid(rnd, r, k):
    ids = live_ids(r, k)
    x = rnd.random()
    if x < 0.3:
        return "$"
    if x < 0.5:
        return "0"
    if x < 0.75 and ids:
        return rnd.choice(ids)
    if x < 0.88:
        return "%d-%d" % (BASE + rnd.randint(0, 30), rnd.randint(0, 3))
    if x < 0.93:
        return str(BASE + rnd.randint(0, 30))
    return rnd.choice(["0-0", "%d-%d" % (U64, U64), "-", "+", "bad"])


def rnd_entries_read(rnd):
    return rnd.choice(["0", "1", "2", "3", "-1", str(rnd.randint(0, 60)), "100"])


def rnd_xadd(rnd, r, k):
    last = last_id(r, k)
    out = []
    for _ in range(rnd.randint(1, 4)):
        if last is None or parts(last)[0] < BASE:
            i = "%d-%d" % (BASE + rnd.randint(0, 2), rnd.randint(1, 3))
        elif rnd.random() < 0.6:
            i = "*"
        else:
            ms, sq = parts(last)
            i = "%d-%d" % (ms + rnd.randint(0, 2), sq + rnd.randint(1, 3))
        trim = []
        if rnd.random() < 0.1:
            trim = ["MAXLEN", str(rnd.randint(0, 8))]
        out.append(cmd("XADD", k, *(trim + [i, "f", str(rnd.randint(0, 99))])))
        last = None if i == "*" else i
        if i == "*":
            break
    return out


def rnd_xdel(rnd, r, k):
    g = rnd.choice(GROUPS)
    return [cmd("XDEL", k, *[rnd_some_id(rnd, r, k, g) for _ in range(rnd.randint(1, 3))])]


def rnd_create(rnd, r, k):
    opts = []
    if rnd.random() < 0.35:
        opts.append(["MKSTREAM"])
    if rnd.random() < 0.3:
        opts.append(["ENTRIESREAD", rnd_entries_read(rnd)])
    rnd.shuffle(opts)
    return [cmd("XGROUP", "CREATE", k, rnd.choice(GROUPS), rnd_gid(rnd, r, k), *[w for o in opts for w in o])]


def rnd_setid(rnd, r, k):
    opts = ["ENTRIESREAD", rnd_entries_read(rnd)] if rnd.random() < 0.5 else []
    return [cmd("XGROUP", "SETID", k, rnd_group(rnd, r, k), rnd_gid(rnd, r, k), *opts)]


def rnd_xreadgroup(rnd, r, keys):
    g = rnd.choice(GROUPS)
    opts = [["GROUP", g, rnd.choice(CONS)]]
    if rnd.random() < 0.5:
        opts.append(["COUNT", rnd.choice(["1", "2", "3", "5", "0", "-1", "100"])])
    if rnd.random() < 0.2:
        opts.append(["NOACK"])
    rnd.shuffle(opts)
    x = rnd.random()
    ks = [rnd.choice(keys)] if x < 0.7 else rnd.sample(keys, 2) if x < 0.9 else [rnd.choice(keys)] * 2
    ids = []
    for k in ks:
        x = rnd.random()
        if x < 0.65:
            ids.append(">")
        elif x < 0.8:
            ids.append("0")
        else:
            ids.append(rnd_some_id(rnd, r, k, g))
    return [cmd("XREADGROUP", *[w for o in opts for w in o], "STREAMS", *(ks + ids))], ks


def rnd_xack(rnd, r, k):
    g = rnd_group(rnd, r, k)
    return [cmd("XACK", k, g, *[rnd_some_id(rnd, r, k, g) for _ in range(rnd.randint(1, 4))])]


def rnd_claim_ids(rnd, r, k, g):
    return [rnd_some_id(rnd, r, k, g) for _ in range(rnd.randint(0 if rnd.random() < 0.05 else 1, 4))]


def rnd_xclaim(rnd, r, k):
    g = rnd_group(rnd, r, k)
    opts = []
    for o in ("IDLE", "TIME", "RETRYCOUNT", "FORCE", "JUSTID", "LASTID"):
        if rnd.random() < 0.25:
            if o == "IDLE":
                opts.append([o, rnd.choice(["0", "5", "100000000", "-5"])])
            elif o == "TIME":
                opts.append([o, rnd.choice(["0", "1", "99999999999999"])])
            elif o == "RETRYCOUNT":
                opts.append([o, rnd.choice(["0", "1", "5", "-1"])])
            elif o == "LASTID":
                opts.append([o, rnd_some_id(rnd, r, k, g)])
            else:
                opts.append([o])
    rnd.shuffle(opts)
    minidle = rnd.choice(["0", "0", "0", "3600000", "-1"])
    return [cmd("XCLAIM", k, g, rnd.choice(CONS), minidle, *rnd_claim_ids(rnd, r, k, g),
                *[w for o in opts for w in o])]


def rnd_xautoclaim(rnd, r, k):
    g = rnd_group(rnd, r, k)
    x = rnd.random()
    if x < 0.4:
        start = rnd.choice(["0", "0-0", "-"])
    elif x < 0.85:
        start = rnd_some_id(rnd, r, k, g)
    else:
        start = "(" + rnd_some_id(rnd, r, k, g)
    opts = []
    if rnd.random() < 0.5:
        opts.append(["COUNT", rnd.choice(["1", "2", "3", "10", "100"])])
    if rnd.random() < 0.3:
        opts.append(["JUSTID"])
    rnd.shuffle(opts)
    minidle = rnd.choice(["0", "0", "3600000", "-1"])
    return [cmd("XAUTOCLAIM", k, g, rnd.choice(CONS), minidle, start, *[w for o in opts for w in o])]


def rnd_round(rnd, b, r, keys, dirty):
    k = rnd.choice(keys)
    ks = [k]
    x = rnd.random()
    if x < 0.2:
        cs = rnd_xadd(rnd, r, k)
    elif x < 0.26:
        cs = rnd_xdel(rnd, r, k)
    elif x < 0.28:
        cs = [cmd("XTRIM", k, "MAXLEN", str(rnd.randint(0, 6)))]
    elif x < 0.295:
        cs = [cmd("DEL", k)]
    elif x < 0.37:
        cs = rnd_create(rnd, r, k)
    elif x < 0.39:
        cs = [cmd("XGROUP", "DESTROY", k, rnd_group(rnd, r, k))]
    elif x < 0.43:
        cs = rnd_setid(rnd, r, k)
    elif x < 0.46:
        cs = [cmd("XGROUP", "CREATECONSUMER", k, rnd_group(rnd, r, k), rnd.choice(CONS))]
    elif x < 0.49:
        cs = [cmd("XGROUP", "DELCONSUMER", k, rnd_group(rnd, r, k), rnd.choice(CONS))]
    elif x < 0.69:
        cs, ks = rnd_xreadgroup(rnd, r, keys)
    elif x < 0.77:
        cs = rnd_xack(rnd, r, k)
    elif x < 0.89:
        cs = rnd_xclaim(rnd, r, k)
    else:
        cs = rnd_xautoclaim(rnd, r, k)
    batch(b, r, cs)
    why = b" | ".join(b" ".join(c) for c in cs)[:200].decode(errors="replace")
    dirty.check(why)
    same_state(b, r, ks, why)


# Errors
# ------

def errors(b, r, dirty):
    e1, e2 = "%d-1" % BASE, "%d-2" % BASE
    batch(b, r, [cmd("DEL", "e", "es", "missing"), cmd("SET", "es", "x"),
                 cmd("XADD", "e", e1, "f", "v"), cmd("XADD", "e", e2, "f", "w"),
                 cmd("XGROUP", "CREATE", "e", "g", "0")])
    dirty.check("the errors' streams")
    cs = [
        # XGROUP: the container's words, then CREATE's options, the key,
        # the group, the ID, the count of words
        cmd("XGROUP"), cmd("XGROUP", "FOO"), cmd("XGROUP", "HELP", "x"), cmd("XGROUP", "help"),
        cmd("XGROUP", "CREATE", "e"), cmd("XGROUP", "CREATE", "e", "g"),
        cmd("XGROUP", "CREATE", "e", "g", "bad"), cmd("XGROUP", "CREATE", "e", "g", "-"),
        cmd("XGROUP", "CREATE", "e", "g", "+"), cmd("XGROUP", "CREATE", "e", "g", "1-x"),
        cmd("XGROUP", "CREATE", "e", "g2", "$", "FOO"), cmd("XGROUP", "CREATE", "e", "g2", "$", "ENTRIESREAD"),
        cmd("XGROUP", "CREATE", "e", "g2", "$", "ENTRIESREAD", "x"),
        cmd("XGROUP", "CREATE", "e", "g2", "$", "ENTRIESREAD", "-2"),
        cmd("XGROUP", "create", "e", "g2", "$", "foo"),
        cmd("XGROUP", "CREATE", "e", "g", "$"), cmd("XGROUP", "CREATE", "e", "g", "bad"),
        cmd("XGROUP", "CREATE", "e", "g2", "$", "MKSTREAM", "MKSTREAM", "MKSTREAM", "MKSTREAM"),
        cmd("XGROUP", "CREATE", "e", "g2", "$", "ENTRIESREAD", "1", "ENTRIESREAD", "2"),
        cmd("XGROUP", "CREATE", "missing", "g", "$"), cmd("XGROUP", "CREATE", "missing", "g", "bad", "MKSTREAM"),
        cmd("XGROUP", "CREATE", "missing", "g", "$", "ENTRIESREAD", "x", "MKSTREAM"),
        cmd("EXISTS", "missing"),
        cmd("XGROUP", "CREATE", "es", "g", "$"), cmd("XGROUP", "CREATE", "es", "g", "$", "FOO"),
        cmd("XGROUP", "CREATE", "es", "g", "$", "MKSTREAM"),
        cmd("XGROUP", "SETID", "e", "g"), cmd("XGROUP", "SETID", "e", "g", "0", "ENTRIESREAD"),
        cmd("XGROUP", "SETID", "e", "g", "0", "MKSTREAM"), cmd("XGROUP", "SETID", "e", "g", "0", "FOO", "1"),
        cmd("XGROUP", "SETID", "e", "nog", "0"), cmd("XGROUP", "SETID", "e", "nog", "bad"),
        cmd("XGROUP", "SETID", "e", "g", "bad"), cmd("XGROUP", "SETID", "missing", "g", "0"),
        cmd("XGROUP", "SETID", "es", "g", "0"), cmd("XGROUP", "SETID", "e", "g", "0", "ENTRIESREAD", "x"),
        cmd("XGROUP", "SETID", "e", "g", "0", "ENTRIESREAD", "1", "ENTRIESREAD", "2"),
        cmd("XGROUP", "SETID", "e", "g", "0", "ENTRIESREAD", "-1"),
        cmd("XGROUP", "SETID", "e", "g", "+"), cmd("XGROUP", "SETID", "e", "g", "-"),
        cmd("XGROUP", "SETID", "e", "g", str(BASE)), cmd("XGROUP", "setid", "e", "g", "$"),
        cmd("XGROUP", "DESTROY", "e"), cmd("XGROUP", "DESTROY", "e", "g", "x"),
        cmd("XGROUP", "DESTROY", "missing", "g"), cmd("XGROUP", "DESTROY", "es", "g"),
        cmd("XGROUP", "DESTROY", "e", "nog"),
        cmd("XGROUP", "CREATECONSUMER", "e", "g"), cmd("XGROUP", "CREATECONSUMER", "e", "nog", "c"),
        cmd("XGROUP", "CREATECONSUMER", "missing", "g", "c"), cmd("XGROUP", "CREATECONSUMER", "es", "g", "c"),
        cmd("XGROUP", "DELCONSUMER", "e", "g"), cmd("XGROUP", "DELCONSUMER", "e", "nog", "c"),
        cmd("XGROUP", "DELCONSUMER", "missing", "g", "c"), cmd("XGROUP", "DELCONSUMER", "e", "g", "nobody"),
        # XREADGROUP: its words, then each key in turn
        cmd("XREADGROUP"), cmd("XREADGROUP", "GROUP", "g", "c", "STREAMS", "e"),
        cmd("XREADGROUP", "GROUP", "g", "c", "STREAMS", "e", ">", "x"),
        cmd("XREADGROUP", "GROUP", "g", "STREAMS", "e", ">"),
        cmd("XREADGROUP", "COUNT", "1", "STREAMS", "e", ">"),
        cmd("XREADGROUP", "COUNT", "1", "NOACK", "e", ">", "x"),
        cmd("XREADGROUP", "GROUP", "g", "c", "COUNT", "x", "STREAMS", "e", ">"),
        cmd("XREADGROUP", "GROUP", "g", "c", "BLOCK", "-1", "STREAMS", "e", ">"),
        cmd("XREADGROUP", "GROUP", "g", "c", "BLOCK", "x", "STREAMS", "e", ">"),
        cmd("XREADGROUP", "GROUP", "g", "c", "FOO", "STREAMS", "e", ">"),
        cmd("XREADGROUP", "GROUP", "g", "c", "COUNT", "1", "COUNT"),
        cmd("XREADGROUP", "GROUP", "g", "c", "STREAMS", "es", ">"),
        cmd("XREADGROUP", "GROUP", "g", "c", "STREAMS", "missing", ">"),
        cmd("XREADGROUP", "GROUP", "nog", "c", "STREAMS", "e", ">"),
        cmd("XREADGROUP", "GROUP", "g", "c", "STREAMS", "e", "$"),
        cmd("XREADGROUP", "GROUP", "g", "c", "STREAMS", "e", "bad"),
        cmd("XREADGROUP", "GROUP", "g", "c", "STREAMS", "e", "-"),
        cmd("XREADGROUP", "GROUP", "g", "c", "STREAMS", "e", "+"),
        cmd("XREADGROUP", "GROUP", "g", "c", "STREAMS", "e", "missing", ">", ">"),
        cmd("XREADGROUP", "GROUP", "g", "c", "STREAMS", "missing", "e", ">", ">"),
        cmd("XREADGROUP", "GROUP", "g", "c", "STREAMS", "e", "es", ">", ">"),
        cmd("XREADGROUP", "GROUP", "g", "c", "STREAMS", "e", "e", ">", "bad"),
        cmd("XREAD", "GROUP", "g", "c", "STREAMS", "e", ">"), cmd("XREAD", "NOACK", "STREAMS", "e", "0"),
        cmd("XINFO", "CONSUMERS", "e", "g"),
        cmd("XREADGROUP", "GROUP", "g", "c", "COUNT", "1", "STREAMS", "e", "%d-%d" % (U64, U64)),
        cmd("XREADGROUP", "GROUP", "g", "c", "NOACK", "NOACK", "COUNT", "0", "STREAMS", "e", "0"),
        cmd("XREADGROUP", "GROUP", "g", "c", "STREAMS", "e", "e", ">", "0"),
        # XACK: no key or group first, then the IDs
        cmd("XACK", "e", "g"), cmd("XACK", "missing", "g", "bad"), cmd("XACK", "e", "nog", "bad"),
        cmd("XACK", "es", "g", "1-1"), cmd("XACK", "e", "g", "bad"), cmd("XACK", "e", "g", e1, "bad"),
        cmd("XACK", "e", "g", "-"), cmd("XACK", "e", "g", e1, e1, "0"),
        # XCLAIM: the key and group, min-idle-time, the IDs, the options
        cmd("XCLAIM", "e", "g", "c"), cmd("XCLAIM", "e", "g", "c", "0"),
        cmd("XCLAIM", "missing", "g", "c", "x", "1-1"), cmd("XCLAIM", "e", "nog", "c", "x", "1-1"),
        cmd("XCLAIM", "es", "g", "c", "0", "1-1"), cmd("XCLAIM", "e", "g", "c", "x", "1-1"),
        cmd("XCLAIM", "e", "g", "c", "0", "bad"), cmd("XCLAIM", "e", "g", "c", "0", e2, "FOO"),
        cmd("XCLAIM", "e", "g", "c", "0", e2, "IDLE"), cmd("XCLAIM", "e", "g", "c", "0", e2, "IDLE", "x"),
        cmd("XCLAIM", "e", "g", "c", "0", e2, "TIME", "x"), cmd("XCLAIM", "e", "g", "c", "0", e2, "RETRYCOUNT", "x"),
        cmd("XCLAIM", "e", "g", "c", "0", e2, "LASTID", "bad"), cmd("XCLAIM", "e", "g", "c", "0", e2, "JUSTID", e1),
        cmd("XCLAIM", "e", "g", "c", "0", e2, "LASTID"), cmd("XCLAIM", "e", "g", "c", "0", "JUSTID"),
        cmd("XCLAIM", "e", "g", "c", "0", e2, "force", "justid", "idle", "5", "time", "1", "retrycount", "2"),
        cmd("XCLAIM", "e", "g", "c", "-7", e2, "JUSTID", "LASTID", "%d-9" % BASE),
        # XAUTOCLAIM: its words first, then the key and group
        cmd("XAUTOCLAIM", "e", "g", "c", "0"), cmd("XAUTOCLAIM", "missing", "g", "c", "x", "0"),
        cmd("XAUTOCLAIM", "missing", "g", "c", "0", "0"), cmd("XAUTOCLAIM", "e", "nog", "c", "0", "0"),
        cmd("XAUTOCLAIM", "es", "g", "c", "0", "0"), cmd("XAUTOCLAIM", "es", "g", "c", "0", "bad"),
        cmd("XAUTOCLAIM", "e", "g", "c", "x", "0"), cmd("XAUTOCLAIM", "e", "g", "c", "0", "bad"),
        cmd("XAUTOCLAIM", "e", "g", "c", "0", "+"), cmd("XAUTOCLAIM", "e", "g", "c", "0", "(%d-%d" % (U64, U64)),
        cmd("XAUTOCLAIM", "e", "g", "c", "0", "0", "COUNT"), cmd("XAUTOCLAIM", "e", "g", "c", "0", "0", "COUNT", "0"),
        cmd("XAUTOCLAIM", "e", "g", "c", "0", "0", "COUNT", "-1"),
        cmd("XAUTOCLAIM", "e", "g", "c", "0", "0", "COUNT", "x"),
        cmd("XAUTOCLAIM", "e", "g", "c", "0", "0", "COUNT", "576460752303423488"),
        cmd("XAUTOCLAIM", "e", "g", "c", "0", "0", "FOO"), cmd("XAUTOCLAIM", "e", "g", "c", "0", "0", "JUSTID", "x"),
        cmd("XAUTOCLAIM", "e", "g", "c", "0", "(" + e1, "COUNT", "1"),
        cmd("XAUTOCLAIM", "e", "g", "c2", "-1", "-", "justid", "count", "1"),
        cmd("XINFO", "CONSUMERS", "e", "g"), cmd("XPENDING", "e", "g", "-", "+", 10),
    ]
    for c in cs:
        batch(b, r, [c])
        dirty.check(b" ".join(c)[:200].decode(errors="replace"))
    same_state(b, r, ["e", "missing"], "the errors")


# Events, WATCH, MULTI and BLOCK
# ------------------------------

def events(port_b, port_r):
    b0, r0 = Conn(port_b, False), Conn(port_r, False)
    batch(b0, r0, [cmd("CONFIG", "SET", "notify-keyspace-events", "KEAn"), cmd("DEL", "v", "vs")])
    bs, rs = Conn(port_b, False), Conn(port_r, False)
    for c in (bs, rs):
        c.send([cmd("PSUBSCRIBE", "__key*__:*", "end")])
        c.reply()
        c.reply()
    v1, v2, v3 = ("%d-%d" % (BASE, i) for i in (1, 2, 3))
    batch(b0, r0, [cmd("XGROUP", "CREATE", "v", "g", "$", "MKSTREAM"), cmd("XGROUP", "CREATE", "v", "g", "$"),
                   cmd("XGROUP", "CREATE", "v", "g2", "0", "MKSTREAM"), cmd("XGROUP", "CREATE", "vs", "g", "bad", "MKSTREAM"),
                   cmd("XADD", "v", v1, "f", "1"), cmd("XADD", "v", v2, "f", "2"), cmd("XADD", "v", v3, "f", "3"),
                   cmd("XGROUP", "CREATECONSUMER", "v", "g", "c1"), cmd("XGROUP", "CREATECONSUMER", "v", "g", "c1"),
                   cmd("XREADGROUP", "GROUP", "g", "c2", "COUNT", "1", "STREAMS", "v", ">"),
                   cmd("XREADGROUP", "GROUP", "g", "c2", "STREAMS", "v", "0"),
                   cmd("XREADGROUP", "GROUP", "g", "c3", "NOACK", "STREAMS", "v", ">"),
                   cmd("XREADGROUP", "GROUP", "g", "c4", "STREAMS", "v", ">"),
                   cmd("XREADGROUP", "GROUP", "g2", "c1", "STREAMS", "v", "v", ">", "0"),
                   cmd("XACK", "v", "g", v1), cmd("XACK", "v", "g", v1),
                   cmd("XCLAIM", "v", "g2", "c5", "0", v1, v2), cmd("XCLAIM", "v", "g2", "c6", "3600000", v3),
                   cmd("XCLAIM", "v", "g2", "c6", "0", "JUSTID", "LASTID", "%d-9" % BASE),
                   cmd("XDEL", "v", v2), cmd("XAUTOCLAIM", "v", "g2", "c7", "0", "0"),
                   cmd("XAUTOCLAIM", "v", "g2", "c8", "3600000", "0"),
                   cmd("XGROUP", "SETID", "v", "g", "0"), cmd("XGROUP", "SETID", "v", "nog", "0"),
                   cmd("XGROUP", "DELCONSUMER", "v", "g", "c2"), cmd("XGROUP", "DELCONSUMER", "v", "g", "c2"),
                   cmd("XGROUP", "DESTROY", "v", "g"), cmd("XGROUP", "DESTROY", "v", "g"),
                   cmd("XGROUP", "CREATECONSUMER", "v", "g2", "c9"),
                   cmd("PUBLISH", "end", "1")])
    xs, ys = [], []
    for c, out in ((bs, xs), (rs, ys)):
        while len(out) < 80:
            m = c.reply()
            out.append(m)
            if m[1] and len(m[1]) == 4 and m[1][2][1] == b"end":
                break
    global n
    n += 1
    if xs != ys:
        fail("the keyspace events", xs, ys)
    batch(b0, r0, [cmd("CONFIG", "SET", "notify-keyspace-events", "")])


def watch(port_b, port_r):
    out = []
    w1 = "%d-1" % BASE
    others = [cmd("XGROUP", "CREATE", "w", "g2", "$"), cmd("XGROUP", "SETID", "w", "g", "0"),
              cmd("XGROUP", "CREATECONSUMER", "w", "g", "c9"),
              cmd("XREADGROUP", "GROUP", "g", "c1", "STREAMS", "w", ">"),
              cmd("XREADGROUP", "GROUP", "g", "c1", "STREAMS", "w", "0"),
              cmd("XCLAIM", "w", "g", "c2", "0", w1), cmd("XAUTOCLAIM", "w", "g", "c3", "0", "0"),
              cmd("XACK", "w", "g", w1), cmd("XGROUP", "DELCONSUMER", "w", "g", "c1"),
              cmd("XGROUP", "DESTROY", "w", "g2"), cmd("XGROUP", "CREATE", "w", "g3", "$", "MKSTREAM"),
              cmd("XADD", "w", "%d-2" % BASE, "f", "v")]
    for port in (port_b, port_r):
        a, o = Conn(port, False), Conn(port, False)
        seq = [run(a, cmd("DEL", "w", "w2")), run(a, cmd("XADD", "w", w1, "f", "v")),
               run(a, cmd("XGROUP", "CREATE", "w", "g", "0"))]
        for x in others:
            for c, y in ((a, cmd("WATCH", "w")), (o, x), (a, cmd("MULTI")), (a, cmd("XLEN", "w")), (a, cmd("EXEC"))):
                seq.append(run(c, y))
        for c, y in ((a, cmd("WATCH", "w2")), (o, cmd("XGROUP", "CREATE", "w2", "g", "$", "MKSTREAM")),
                     (a, cmd("MULTI")), (a, cmd("XLEN", "w2")), (a, cmd("EXEC")),
                     (a, cmd("WATCH", "w2")), (o, cmd("XGROUP", "CREATE", "w2", "g2", "$", "MKSTREAM")),
                     (a, cmd("MULTI")), (a, cmd("XLEN", "w2")), (a, cmd("EXEC")),
                     # the groups' writes in MULTI, and XREADGROUP with BLOCK
                     (a, cmd("MULTI")), (a, cmd("XGROUP", "CREATE", "w3", "g", "$", "MKSTREAM")),
                     (a, cmd("XADD", "w3", w1, "f", "v")), (a, cmd("XREADGROUP", "GROUP", "g", "c", "STREAMS", "w3", ">")),
                     (a, cmd("XREADGROUP", "BLOCK", "0", "GROUP", "g", "c", "STREAMS", "w3", ">")),
                     (a, cmd("XREADGROUP", "BLOCK", "0", "GROUP", "g", "c", "STREAMS", "w3", "0")),
                     (a, cmd("XADD", "w3", "%d-2" % BASE, "f", "v")),
                     (a, cmd("XREADGROUP", "BLOCK", "100", "GROUP", "g", "c", "STREAMS", "w3", ">")),
                     (a, cmd("XREADGROUP", "BLOCK", "100", "GROUP", "nog", "c", "STREAMS", "w3", ">")),
                     (a, cmd("XACK", "w3", "g", w1)), (a, cmd("XCLAIM", "w3", "g", "c2", "0", "%d-2" % BASE, "JUSTID")),
                     (a, cmd("XAUTOCLAIM", "w3", "g", "c3", "0", "0", "JUSTID")),
                     (a, cmd("XGROUP", "CREATECONSUMER", "w3", "g", "c4")), (a, cmd("XGROUP", "DELCONSUMER", "w3", "g", "c")),
                     (a, cmd("XGROUP", "SETID", "w3", "g", "0", "ENTRIESREAD", "0")), (a, cmd("XGROUP", "DESTROY", "w3", "g")),
                     (a, cmd("EXEC")), (a, cmd("XINFO", "STREAM", "w3", "FULL")), (a, cmd("DEL", "w3")),
                     # BLOCK out of MULTI, served at once
                     (a, cmd("XGROUP", "CREATE", "w3", "g", "0", "MKSTREAM")), (a, cmd("XADD", "w3", w1, "f", "v")),
                     (a, cmd("XREADGROUP", "BLOCK", "100", "GROUP", "g", "c", "STREAMS", "w3", ">")),
                     (a, cmd("XREADGROUP", "BLOCK", "0", "GROUP", "g", "c", "STREAMS", "w3", "0")),
                     (a, cmd("XREADGROUP", "BLOCK", "0", "GROUP", "g", "c", "STREAMS", "w3", "w", "0", ">")),
                     (a, cmd("XINFO", "STREAM", "w3", "FULL"))):
            seq.append(run(c, y))
        out.append(seq)
    global n
    n += 1
    if not alike((b"*", out[0]), (b"*", out[1])):
        for i, (x, y) in enumerate(zip(out[0], out[1])):
            if not alike(x, y):
                fail("WATCH and MULTI, reply %d" % i, x, y)
                break


# where Redis would wait, BendKV answers an error (and changes nothing)
def block(port_b):
    global n
    a = Conn(port_b, False)
    for x in (cmd("DEL", "w4"), cmd("XGROUP", "CREATE", "w4", "g", "$", "MKSTREAM"),
              cmd("XADD", "w4", "%d-1" % BASE, "f", "v"),
              cmd("XREADGROUP", "GROUP", "g", "c", "STREAMS", "w4", ">")):
        run(a, x)
    for x in (cmd("XREADGROUP", "BLOCK", "0", "GROUP", "g", "c", "STREAMS", "w4", ">"),
              cmd("XREADGROUP", "BLOCK", "10", "GROUP", "g", "c2", "STREAMS", "w4", ">")):
        n += 1
        y = run(a, x)
        if y != (b"-", b"ERR BendKV does not block on streams yet"):
            fail(b" ".join(x).decode(), y, "an error")
    n += 1
    y = run(a, cmd("XINFO", "CONSUMERS", "w4", "g"))
    if y[0] != b"*" or len(y[1]) != 1:
        fail("the consumers after a BLOCK that would wait", y, "c alone")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bendkv", type=int, default=6380)
    ap.add_argument("--redis", type=int, default=6390)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--rounds", type=int, default=3000)
    a = ap.parse_args()
    rnd = random.Random(a.seed)
    for resp3 in (False, True):
        b, r = Conn(a.bendkv, resp3), Conn(a.redis, resp3)
        keys = ["s1", "s2", "s3"]
        batch(b, r, [cmd("DEL", *keys)])
        dirty = Dirty(b, r)
        for _ in range(a.rounds // 2):
            rnd_round(rnd, b, r, keys, dirty)
        errors(b, r, dirty)
    events(a.bendkv, a.redis)
    watch(a.bendkv, a.redis)
    block(a.bendkv)
    print("stream groups: %d checks, %d differ" % (n, bad))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
