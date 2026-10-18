#!/usr/bin/env python3
"""The append-only file of the writes of a stream's groups: the same
XGROUP, XREADGROUP, XACK, XCLAIM and XAUTOCLAIM (and the XADD, XDEL and
SET they need) against BendKV and a redis-server, each writing its own
file, with the same replies and the same streams (times within 2 s, as
in stream_group_test.py); then

- BendKV started from its own file holds each stream as it did, byte
  for byte (DUMP): the file keeps XGROUP CREATE, DESTROY and XACK as
  they came, and the writes that read the clock resolved, as BendKV's
  scripts: XWSet's (a group's last ID and entries read, a consumer's
  seen and active times, the pending entries it got or lost, at their
  times and with their counts; an XREADGROUP that waited, its consumer
  made as it began to wait) and XWDelCon's (a consumer deleted);
- Redis started from BendKV's file holds the same streams, but for the
  consumers' seen and active times, which its XGROUP CREATECONSUMER and
  XCLAIM set to its own now;
- BendKV started from Redis's file holds the streams Redis holds
  started from its own file (in which a consumer's history read again
  counts no delivery, as Redis logs none), but for the same times.

    python3 tests/stream_group_aof_test.py --bin build/bendkv --bendkv 6380 --redis 6391 [--dir build/xgaof]
"""
import argparse
import os
import shutil
import sys
import time

from aof_redis_test import start, stop
from aof_test import keyspace
from stream_aof_test import redis, redis_file
from stream_group_test import alike

BASE = 10 ** 15
KEYS = [(0, "s1"), (0, "s2"), (0, "s3"), (0, "s4"), (0, "s5"), (3, "t")]


def cmd(*a):
    return [x if isinstance(x, bytes) else str(x).encode() for x in a]


def i(n):
    return "%d-%d" % (BASE, n)


def cmds():
    out = [cmd("XADD", "s1", i(n), "f", str(n)) for n in range(1, 7)]
    out += [cmd("XGROUP", "CREATE", "s1", "g1", "0"),
            cmd("XGROUP", "CREATE", "s1", "g2", "$", "ENTRIESREAD", "6"),
            cmd("XGROUP", "CREATE", "s1", "g3", i(2)),
            cmd("XGROUP", "CREATE", "s1", "g4", "0", "ENTRIESREAD", "-1"),
            # XREADGROUP that waits until its time is up: its consumer made
            # as it began to wait (with NOACK, Redis logs its creation)
            cmd("XREADGROUP", "GROUP", "g2", "cw", "BLOCK", "10", "STREAMS", "s1", ">"),
            cmd("XREADGROUP", "GROUP", "g2", "cn", "BLOCK", "10", "NOACK", "STREAMS", "s1", ">"),
            cmd("XREADGROUP", "GROUP", "g1", "c1", "COUNT", "2", "STREAMS", "s1", ">"),
            cmd("XREADGROUP", "GROUP", "g1", "c2", "COUNT", "2", "STREAMS", "s1", ">"),
            cmd("XREADGROUP", "GROUP", "g1", "c1", "STREAMS", "s1", "0"),
            cmd("XREADGROUP", "GROUP", "g3", "c1", "NOACK", "STREAMS", "s1", ">"),
            cmd("XREADGROUP", "GROUP", "g4", "c1", "COUNT", "1", "STREAMS", "s1", ">"),
            cmd("XACK", "s1", "g1", i(1), i(9)),
            cmd("XCLAIM", "s1", "g1", "c3", "0", i(2), i(3)),
            cmd("XCLAIM", "s1", "g1", "c3", "0", i(4), "JUSTID", "RETRYCOUNT", "9", "IDLE", "100000000"),
            cmd("XCLAIM", "s1", "g1", "c3", "0", i(3), "TIME", "1"),
            cmd("XCLAIM", "s1", "g1", "c4", "0", i(9), "FORCE"),
            cmd("XCLAIM", "s1", "g1", "c4", "0", i(5), "FORCE", "JUSTID", "LASTID", i(8)),
            cmd("XCLAIM", "s1", "g1", "c4", "3600000", i(2)),
            cmd("XCLAIM", "s1", "g1", "c6", "0", "JUSTID", "LASTID", i(9)),
            cmd("XDEL", "s1", i(2)),
            cmd("XREADGROUP", "GROUP", "g1", "c3", "STREAMS", "s1", "0"),
            cmd("XAUTOCLAIM", "s1", "g1", "c5", "0", "0", "COUNT", "2"),
            cmd("XAUTOCLAIM", "s1", "g1", "c5", "0", "0", "JUSTID"),
            cmd("XAUTOCLAIM", "s1", "g1", "c7", "3600000", "0"),
            cmd("XGROUP", "CREATECONSUMER", "s1", "g2", "c9"),
            cmd("XGROUP", "CREATECONSUMER", "s1", "g2", "c9"),
            cmd("XGROUP", "DELCONSUMER", "s1", "g1", "c2"),
            cmd("XGROUP", "DELCONSUMER", "s1", "g1", "c5"),
            cmd("XGROUP", "SETID", "s1", "g2", i(1), "ENTRIESREAD", "1"),
            cmd("XGROUP", "SETID", "s1", "g3", "$"),
            cmd("XGROUP", "CREATE", "s2", "g1", "$", "MKSTREAM"),
            cmd("XADD", "s2", i(1), "a", "b"),
            cmd("XREADGROUP", "GROUP", "g1", "c1", "STREAMS", "s1", "s2", ">", ">"),
            cmd("XGROUP", "DESTROY", "s1", "g4"),
            cmd("XGROUP", "CREATE", "s3", "g1", "0", "MKSTREAM", "ENTRIESREAD", "0"),
            cmd("XGROUP", "CREATE", "s3", "g2", "0"),
            cmd("XGROUP", "DESTROY", "s3", "g1"),
            # a stream's group made where a key whose time had passed lay
            cmd("SET", "s4", "x", "PX", "1"), ["SLEEP"],
            cmd("XGROUP", "CREATE", "s4", "g1", "$", "MKSTREAM"),
            cmd("XADD", "s4", i(1), "f", "v"),
            cmd("XREADGROUP", "GROUP", "g1", "c1", "STREAMS", "s4", ">"),
            cmd("SELECT", "3"), cmd("XGROUP", "CREATE", "t", "g", "$", "MKSTREAM"),
            cmd("XADD", "t", i(1), "a", "b"), cmd("XREADGROUP", "GROUP", "g", "c", "STREAMS", "t", ">"),
            cmd("SELECT", "0"),
            cmd("MULTI"), cmd("XGROUP", "CREATE", "s5", "g1", "$", "MKSTREAM"),
            cmd("XADD", "s5", i(1), "a", "1"), cmd("XADD", "s5", i(2), "a", "2"),
            cmd("XREADGROUP", "GROUP", "g1", "c1", "STREAMS", "s5", ">"),
            cmd("XACK", "s5", "g1", i(1)), cmd("XCLAIM", "s5", "g1", "c2", "0", i(2)),
            cmd("XGROUP", "CREATECONSUMER", "s5", "g1", "c3"), cmd("EXEC")]
    return out


# each stream's XINFO STREAM FULL; mask: the consumers' times left out
def streams(c, mask=False):
    out = {}
    for db, k in KEYS:
        c.send([cmd("SELECT", db), cmd("XINFO", "STREAM", k, "FULL", "COUNT", 0)])
        c.reply()
        r = c.reply()
        out[(db, k)] = masked(r) if mask else r
    c.send([cmd("SELECT", 0)])
    c.reply()
    return out


def masked(r):
    kind, v = r
    if not isinstance(v, list):
        return r
    out = []
    j = 0
    while j < len(v):
        if v[j] in ((b"$", b"seen-time"), (b"$", b"active-time")) and j + 1 < len(v):
            out += [v[j], (b":", b"*")]
            j += 2
            continue
        out.append(masked(v[j]))
        j += 1
    return (kind, out)


def same(what, x, y, loose=False):
    for k in x:
        if not (alike(x[k], y[k]) if loose else x[k] == y[k]):
            print("FAIL: %s: %s" % (what, k))
            print("  first:  %s" % (str(x[k])[:1500],))
            print("  second: %s" % (str(y[k])[:1500],))
            sys.exit(1)
    print("OK: %s (%d streams)" % (what, len(x)))


def same_keys(what, x, y):
    if x != y:
        print("FAIL: %s" % what)
        print("  only in the first:", sorted(set(x) - set(y))[:5])
        print("  only in the second:", sorted(set(y) - set(x))[:5])
        sys.exit(1)
    print("OK: %s (%d keys)" % (what, len(x)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", default="build/bendkv")
    ap.add_argument("--bendkv", type=int, default=6380)
    ap.add_argument("--redis", type=int, default=6391)
    ap.add_argument("--dir", default="build/xgaof")
    a = ap.parse_args()
    d = os.path.abspath(a.dir)
    shutil.rmtree(d, ignore_errors=True)
    for sub in ["redis", "bendkv"]:
        os.makedirs(os.path.join(d, sub))
    rdir, bfile = os.path.join(d, "redis"), os.path.join(d, "bendkv", "bendkv.aof")
    pr, cr = start(redis(a.redis, rdir, "--aof-use-rdb-preamble", "no"), a.redis, os.path.join(d, "redis.log"))
    pb, cb = start([a.bin, str(a.bendkv), "send", bfile, "always"], a.bendkv, os.path.join(d, "bendkv.log"))
    n = 0
    try:
        for x in cmds():
            if x == ["SLEEP"]:
                time.sleep(0.01)
                continue
            cr.send([x])
            cb.send([x])
            r, b = cr.reply(), cb.reply()
            n += 1
            if not alike(b, r):
                sys.exit("FAIL: %r answered %r by Redis, %r by BendKV" % (x, r, b))
        print("OK: %d commands, the same replies" % n)
        sr, sb = streams(cr), streams(cb)
        kb = keyspace(cb)
    finally:
        stop(pr)
        stop(pb)
    same("the same streams on both", sb, sr, loose=True)
    p, c = start([a.bin, str(a.bendkv), "send", bfile, "always"], a.bendkv, os.path.join(d, "restart.log"))
    try:
        k = keyspace(c)
    finally:
        stop(p)
    same_keys("BendKV restores its streams from its own file, byte for byte", k, kb)
    ldir = os.path.join(d, "rload")
    os.makedirs(ldir)
    shutil.copy(bfile, os.path.join(ldir, "appendonly.aof"))
    p, c = start(redis(a.redis, ldir, "--appendfilename", "appendonly.aof"), a.redis, os.path.join(d, "rload.log"))
    try:
        s = streams(c, True)
    finally:
        stop(p)
    same("Redis restores the streams from BendKV's file", s, {k: masked(v) for k, v in sb.items()})
    p, c = start(redis(a.redis, rdir, "--aof-use-rdb-preamble", "no"), a.redis, os.path.join(d, "rself.log"))
    try:
        s2 = streams(c, True)
    finally:
        stop(p)
    rfile = os.path.join(d, "bload", "redis.aof")
    os.makedirs(os.path.dirname(rfile))
    redis_file(os.path.join(rdir, "appendonlydir"), rfile)
    p, c = start([a.bin, str(a.bendkv), "send", rfile, "always"], a.bendkv, os.path.join(d, "bload.log"))
    try:
        s = streams(c, True)
    finally:
        stop(p)
    same("BendKV restores the streams from Redis's file as Redis does", s, s2)
    print("ALL OK")


if __name__ == "__main__":
    main()
