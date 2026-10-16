#!/usr/bin/env python3
"""The append-only file of the writes of a stream: the same XADD, XTRIM,
XDEL and XSETID against BendKV and a redis-server, each writing its own
file, with the same replies and the same DUMP of every stream; then
BendKV started from its own file, and Redis from BendKV's, each stream
as BendKV held it, byte for byte; and BendKV started from Redis's file,
each stream as Redis held it. BendKV logs each write resolved: XADD
with the ID it added (for * and <ms>-*), a trim by ~ as the exact trim
it made, without NOMKSTREAM; a stream made where a key whose time had
passed still lay as the script that deletes the key and runs the XADD.
Redis logs * and ~ alike, but keeps LIMIT after the = it writes for ~,
which its load ignores: BendKV's start does not read it yet (FINDINGS
3zzzza), so the test takes LIMIT out of Redis's file first. The IDs of *
are past the clock (a stream's last one is), so that both servers add
the same ones.

    python3 tests/stream_aof_test.py --bin build/bendkv --bendkv 6380 --redis 6391 [--dir build/xaof]
"""
import argparse
import os
import shutil
import sys
import time

from aof_redis_test import start, stop
from aof_test import keyspace

BASE = 10 ** 15


def cmd(*a):
    return [x if isinstance(x, bytes) else str(x).encode() for x in a]


def cmds():
    out = [cmd("XADD", "s1", "%d-1" % BASE, "f", "v"), cmd("XADD", "s1", "*", "f", "v2"),
           cmd("XADD", "s1", "%d-*" % BASE, "g", "w"), cmd("XADD", "s1", "%d-*" % (BASE + 5), "f", "1")]
    # a stream of three nodes and more, its fields the master's or not
    out.append(cmd("XADD", "s2", "%d-0" % BASE, "f", "0", "g", "x"))
    for i in range(1, 260):
        fv = ["f", str(i), "g", "y" * (i % 7)] if i % 3 else ["h", str(-i), "f", "z" * 40]
        out.append(cmd("XADD", "s2", "*", *fv))
    out += [cmd("XADD", "s2", "MAXLEN", "~", "200", "*", "f", "a"),
            cmd("XTRIM", "s2", "MAXLEN", "~", "150"),
            cmd("XTRIM", "s2", "MAXLEN", "~", "120", "LIMIT", "40"),
            cmd("XTRIM", "s2", "MINID", "~", "%d-150" % BASE),
            cmd("XDEL", "s2", "%d-160" % BASE, "%d-161" % BASE, "%d-161" % BASE, "1-1"),
            cmd("XTRIM", "s2", "MAXLEN", "=", "90"),
            cmd("XADD", "s2", "MINID", "%d-200" % BASE, "*", "f", "b"),
            cmd("XADD", "s2", "MAXLEN", "~", "10", "LIMIT", "30", "*", "f", "c"),
            cmd("XSETID", "s2", "%d-9000" % BASE, "ENTRIESADDED", "5000", "MAXDELETEDID", "%d-8000" % BASE),
            cmd("XADD", "s2", "*", "f", "d"),
            cmd("XDEL", "s2", "%d-9001" % BASE),
            cmd("XADD", "s3", "NOMKSTREAM", "*", "f", "v"),
            cmd("XADD", "s3", "%d-1" % BASE, "f", "v"),
            cmd("XADD", "s3", "NOMKSTREAM", "MAXLEN", "0", "*", "f", "v"),
            cmd("XTRIM", "none", "MAXLEN", "0"), cmd("XDEL", "none", "1-1"),
            # a stream where a key whose time had passed lay
            cmd("SET", "s4", "x", "PX", "1"), ["SLEEP"], cmd("XADD", "s4", "%d-1" % BASE, "f", "v"),
            cmd("SELECT", "3"), cmd("XADD", "t", "%d-1" % BASE, "a", "b"), cmd("XADD", "t", "*", "a", "c"),
            cmd("SELECT", "0")]
    return out


def redis(port, d, *more):
    return ["redis-server", "--port", str(port), "--bind", "127.0.0.1", "--save", "",
            "--appendonly", "yes", "--appendfsync", "always", "--rdbcompression", "no", "--dir", d] + list(more)


# Redis's file, its base then its increments, as one file, each XADD's
# and XTRIM's LIMIT taken out (Redis's load sets it to 0: mustObeyClient)
def redis_file(parts, out):
    data = b""
    for n in sorted(os.listdir(parts), key=lambda n: (".incr." in n, n)):
        if n.endswith(".aof"):
            with open(os.path.join(parts, n), "rb") as f:
                data += f.read()
    i, cmds = 0, []
    while i < len(data):
        j = data.index(b"\r\n", i)
        n, i = int(data[i + 1:j]), j + 2
        a = []
        for _ in range(n):
            j = data.index(b"\r\n", i)
            m, i = int(data[i + 1:j]), j + 2
            a.append(data[i:i + m])
            i += m + 2
        up = [x.upper() for x in a]
        if up[0] in (b"XADD", b"XTRIM") and b"LIMIT" in up:
            k = up.index(b"LIMIT")
            if k > 3 and a[k - 2] == b"=":
                a = a[:k] + a[k + 2:]
        cmds.append(a)
    with open(out, "wb") as o:
        for a in cmds:
            o.write(b"*%d\r\n" % len(a) + b"".join(b"$%d\r\n%s\r\n" % (len(x), x) for x in a))
    return sum(1 for a in cmds if a[0].upper() in (b"XADD", b"XTRIM", b"XDEL", b"XSETID"))


def same(what, x, y):
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
    ap.add_argument("--dir", default="build/xaof")
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
            if r != b:
                sys.exit("FAIL: %r answered %r by Redis, %r by BendKV" % (x, r, b))
        print("OK: %d commands, the same replies" % n)
        kr, kb = keyspace(cr), keyspace(cb)
    finally:
        stop(pr)
        stop(pb)
    same("the same streams on both", kr, kb)
    p, c = start([a.bin, str(a.bendkv), "send", bfile, "always"], a.bendkv, os.path.join(d, "restart.log"))
    try:
        k = keyspace(c)
    finally:
        stop(p)
    same("BendKV restores its streams from its own file", k, kb)
    ldir = os.path.join(d, "rload")
    os.makedirs(ldir)
    shutil.copy(bfile, os.path.join(ldir, "appendonly.aof"))
    p, c = start(redis(a.redis, ldir, "--appendfilename", "appendonly.aof"), a.redis, os.path.join(d, "rload.log"))
    try:
        k = keyspace(c)
    finally:
        stop(p)
    same("Redis restores the streams from BendKV's file", k, kb)
    rfile = os.path.join(d, "bload", "redis.aof")
    os.makedirs(os.path.dirname(rfile))
    w = redis_file(os.path.join(rdir, "appendonlydir"), rfile)
    p, c = start([a.bin, str(a.bendkv), "send", rfile, "always"], a.bendkv, os.path.join(d, "bload.log"))
    try:
        k = keyspace(c)
    finally:
        stop(p)
    same("BendKV restores the streams from Redis's file (%d writes of streams)" % w, k, kr)
    print("ALL OK")


if __name__ == "__main__":
    main()
